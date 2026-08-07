### Setup

glc_helper_path <- function() {
  source_files <- vapply(sys.frames(), function(frame) {
    if (is.null(frame$ofile)) "" else as.character(frame$ofile)
  }, character(1))
  source_files <- source_files[nzchar(source_files)]
  if (length(source_files)) {
    return(normalizePath(tail(source_files, 1)))
  }
  normalizePath(
    "workflow/gee/land_cover/glc_consolidation_helpers.R"
  )
}

glc_land_cover_dir <- dirname(glc_helper_path())
source(file.path(dirname(glc_land_cover_dir), "gee_api.R"))
source(file.path(glc_land_cover_dir, "shared_watershed_aliases.R"))

glc_default_alias_file <- file.path(
  glc_land_cover_dir,
  "shared_watershed_aliases.csv"
)
glc_years <- c(1985L, 1990L, 1995L, 2000:2022)
glc_classes <- c(
  0L, 10L, 11L, 12L, 20L, 50L, 51L, 52L, 61L, 62L,
  71L, 72L, 81L, 82L, 91L, 92L, 120L, 121L, 122L,
  130L, 140L, 150L, 152L, 153L, 181L, 182L, 183L,
  184L, 185L, 186L, 187L, 190L, 200L, 201L, 202L,
  210L, 220L
)
glc_metadata <- c("site_id", "LTER", "Stream_Name", "Shapefile_Name")
glc_alias_columns <- c(
  "watershed_alias_flag",
  "watershed_alias_source_site_id",
  "watershed_alias_source_stream_name"
)
glc_scale_m <- 30
glc_default_sample_points <- 100000L
glc_default_run_root <- "generated_outputs/gee/glc-fcs30d-safe"

### Task planning

glc_parse_args <- function(args) {
  values <- list()
  index <- 1L
  while (index <= length(args)) {
    token <- args[[index]]
    if (!startsWith(token, "--")) {
      stop("Unexpected argument: ", token)
    }
    key <- gsub("-", "_", substring(token, 3), fixed = TRUE)
    if (key == "download") {
      values[[key]] <- TRUE
      index <- index + 1L
      next
    }
    if (index == length(args) || startsWith(args[[index + 1L]], "--")) {
      stop("Missing value for ", token)
    }
    values[[key]] <- args[[index + 1L]]
    index <- index + 2L
  }
  values
}

glc_safe_asset_part <- function(value, maximum = 38L) {
  cleaned <- tolower(value)
  cleaned <- gsub("[^a-z0-9_-]+", "_", cleaned)
  cleaned <- gsub("^[_-]+|[_-]+$", "", cleaned)
  if (!nzchar(cleaned)) {
    cleaned <- "site"
  }
  cleaned <- substring(cleaned, 1L, maximum)
  gsub("[_-]+$", "", cleaned)
}

glc_method_code <- function(method, sample_points) {
  if (method == "exact") {
    return("x")
  }
  if (sample_points %% 1000000L == 0L) {
    return(paste0("mph", sample_points %/% 1000000L, "m"))
  }
  if (sample_points %% 1000L == 0L) {
    return(paste0("mph", sample_points %/% 1000L, "k"))
  }
  paste0("mph", sample_points)
}

glc_load_sites <- function(manifest_path) {
  manifest_path <- normalizePath(manifest_path)
  manifest <- read.csv(
    manifest_path,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  if (!all(c("path", "sites") %in% names(manifest))) {
    stop("Payload manifest must contain path and sites columns")
  }

  sites <- list()
  seen <- character()
  for (index in seq_len(nrow(manifest))) {
    payload_path <- manifest$path[[index]]
    if (!startsWith(payload_path, "/")) {
      payload_path <- file.path(dirname(manifest_path), payload_path)
    }
    payload_path <- normalizePath(payload_path)
    payload <- jsonlite::fromJSON(payload_path, simplifyVector = FALSE)
    features <- payload$features %||% list()
    if (length(features) != as.integer(manifest$sites[[index]])) {
      stop("Manifest and GeoJSON site counts differ: ", payload_path)
    }

    for (feature in features) {
      properties <- feature$properties %||% list()
      missing <- setdiff(glc_metadata, names(properties))
      if (length(missing)) {
        stop(
          "GeoJSON feature lacks metadata: ",
          paste(missing, collapse = ", ")
        )
      }
      site_id <- trimws(as.character(properties$site_id))
      if (!nzchar(site_id) || site_id %in% seen) {
        stop("Blank or duplicate site_id: ", site_id)
      }
      area_km2 <- as.numeric(properties$polygon_area_km2 %||% NA_real_)
      if (!is.finite(area_km2) || area_km2 <= 0) {
        stop("Invalid polygon_area_km2 for ", site_id)
      }
      if (is.null(feature$geometry)) {
        stop("Missing geometry for ", site_id)
      }

      seen <- c(seen, site_id)
      sites[[length(sites) + 1L]] <- list(
        site_id = site_id,
        area_km2 = area_km2
      )
    }
  }
  if (!length(sites)) {
    stop("Payload manifest contains no sites")
  }
  sites
}

glc_filter_sites <- function(sites, site_ids = NULL) {
  if (is.null(site_ids) || !nzchar(trimws(site_ids))) {
    return(sites)
  }
  requested <- unique(trimws(strsplit(site_ids, ",", fixed = TRUE)[[1]]))
  requested <- requested[nzchar(requested)]
  available <- vapply(sites, function(site) site$site_id, character(1))
  missing <- setdiff(requested, available)
  if (length(missing)) {
    stop(
      "Requested site_id values are absent: ",
      paste(missing, collapse = ", ")
    )
  }
  Filter(function(site) site$site_id %in% requested, sites)
}

glc_check_sample_fraction <- function(value) {
  value <- as.numeric(value)
  invalid <- length(value) != 1L ||
    !is.finite(value) ||
    value <= 0 ||
    value > 1
  if (invalid) {
    stop("Minimum sample fraction must be greater than zero and at most one")
  }
  value
}

glc_plan_tasks <- function(
  sites,
  method,
  sample_points,
  exact_max_work,
  run_label,
  output_folder,
  minimum_sample_fraction = 0.99
) {
  if (!method %in% c("auto", "exact", "sample")) {
    stop("Method must be auto, exact, or sample")
  }
  if (sample_points < 10000L) {
    stop("At least 10,000 sample points are required")
  }
  minimum_sample_fraction <- glc_check_sample_fraction(
    minimum_sample_fraction
  )

  plans <- lapply(sites, function(site) {
    native_pixels <- site$area_km2 * 1000000 / (glc_scale_m^2)
    exact_work <- native_pixels * length(glc_years)
    selected_method <- method
    if (method == "auto") {
      selected_method <- if (exact_work <= exact_max_work) {
        "exact"
      } else {
        "sample"
      }
    }
    short_method <- glc_method_code(selected_method, sample_points)
    site_hash <- substring(
      digest::digest(site$site_id, algo = "sha256", serialize = FALSE),
      1L,
      10L
    )
    description <- paste(
      "glcsafe",
      short_method,
      run_label,
      glc_safe_asset_part(site$site_id),
      site_hash,
      sep = "_"
    )
    list(
      description = description,
      asset_id = paste0(
        sub("/+$", "", output_folder),
        "/",
        description
      ),
      site = site,
      method = selected_method,
      sample_points = if (selected_method == "sample") {
        sample_points
      } else {
        0L
      },
      native_pixel_estimate = native_pixels,
      effective_pixel_band_time = if (selected_method == "exact") {
        exact_work
      } else {
        sample_points * length(glc_years)
      },
      minimum_sample_fraction = minimum_sample_fraction
    )
  })
  order_index <- order(
    vapply(plans, function(plan) plan$method != "sample", logical(1)),
    -vapply(plans, function(plan) {
      if (plan$method == "sample") {
        plan$native_pixel_estimate
      } else {
        plan$effective_pixel_band_time
      }
    }, numeric(1)),
    vapply(plans, function(plan) plan$description, character(1))
  )
  plans[order_index]
}

### Shared output handling

glc_rows_to_data_frame <- function(rows, columns) {
  frames <- lapply(rows, function(row) {
    as.data.frame(row, stringsAsFactors = FALSE, optional = TRUE)
  })
  output <- dplyr::bind_rows(frames)
  missing <- setdiff(columns, names(output))
  for (name in missing) {
    output[[name]] <- NA
  }
  output[, columns, drop = FALSE]
}

glc_output_path <- function(args, run_root, output_stem, run_label) {
  args[["output"]] %||% file.path(
    run_root,
    paste0(output_stem, "_", run_label, ".csv")
  )
}

run_glc_consolidation <- function(settings, args) {
  project <- args$project %||% "silica-synthesis"
  run_label <- args$run_label %||% stop("Missing --run-label")
  run_root <- args$run_root %||% glc_default_run_root
  manifest <- args$manifest %||% file.path(
    run_root,
    "payload_manifest.csv"
  )
  output_folder <- args$output_folder %||% sprintf(
    "projects/%s/assets/glc_fcs30d_safe_%s",
    project,
    run_label
  )
  method <- args$method %||% "auto"
  sample_points <- as.integer(
    args$sample_points %||% glc_default_sample_points
  )
  exact_max_work <- as.numeric(
    args$exact_max_work %||% (sample_points * length(glc_years))
  )
  minimum_sample_fraction <- glc_check_sample_fraction(
    args$minimum_sample_fraction %||% 0.99
  )
  expected_site_count <- if (is.null(args$expected_site_count)) {
    NULL
  } else {
    as.integer(args$expected_site_count)
  }
  output <- glc_output_path(
    args,
    run_root,
    settings$output_stem,
    run_label
  )

  sites <- glc_filter_sites(glc_load_sites(manifest), args$site_ids)
  wrong_site_count <- !is.null(expected_site_count) &&
    length(sites) != expected_site_count
  if (wrong_site_count) {
    stop("Found ", length(sites), " sites; expected ", expected_site_count)
  }
  plans <- glc_plan_tasks(
    sites,
    method,
    sample_points,
    exact_max_work,
    run_label,
    output_folder,
    minimum_sample_fraction
  )

  token <- gee_access_token()
  available_assets <- gee_list_assets(output_folder, project, token)
  available <- vapply(
    available_assets,
    function(asset) as.character(asset$name %||% ""),
    character(1)
  )
  missing <- vapply(
    Filter(function(plan) !plan$asset_id %in% available, plans),
    `[[`,
    character(1),
    "asset_id"
  )
  expected_rows <- settings$expected_rows(length(sites))
  status <- list(
    expected_assets = length(plans),
    complete_assets = length(plans) - length(missing),
    missing_assets = length(missing),
    expected_sites = length(sites)
  )
  if (!is.null(expected_rows)) {
    status$expected_rows <- expected_rows
  }
  cat(
    settings$label,
    " status: ",
    jsonlite::toJSON(status, auto_unbox = TRUE),
    "\n",
    sep = ""
  )
  if (!isTRUE(args$download)) {
    cat("Status only; use --download after every asset is complete\n")
    return(invisible(NULL))
  }
  if (length(missing)) {
    stop(
      "Cannot download an incomplete run; ",
      length(missing),
      " assets are missing"
    )
  }

  all_rows <- list()
  asset_qa <- list()
  for (index in seq_along(plans)) {
    plan <- plans[[index]]
    features <- gee_compute_features(plan$asset_id, project, token)
    rows <- lapply(features, function(feature) {
      settings$normalize(feature$properties %||% list())
    })
    asset_qa[[index]] <- settings$validate(rows, plan)
    all_rows <- c(all_rows, rows)
    cat(
      "Downloaded and checked ",
      index,
      "/",
      length(plans),
      "\n",
      sep = ""
    )
  }

  combined_keys <- vapply(all_rows, settings$row_key, character(1))
  wrong_row_count <- !is.null(expected_rows) &&
    length(all_rows) != expected_rows
  if (anyDuplicated(combined_keys) || wrong_row_count) {
    stop(settings$label, " rows are incomplete or duplicated")
  }
  output_data <- settings$to_data_frame(all_rows)
  output_data <- add_shared_watershed_aliases(
    output_data,
    args$site_alias_file %||% glc_default_alias_file
  )
  order_values <- lapply(
    settings$order_by,
    function(name) output_data[[name]]
  )
  output_data <- output_data[
    do.call(order, order_values),
    ,
    drop = FALSE
  ]

  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  write.csv(output_data, output, row.names = FALSE, na = "")
  qa_path <- if (grepl("\\.[^.]+$", output)) {
    sub("\\.[^.]+$", ".qa.json", output)
  } else {
    paste0(output, ".qa.json")
  }
  qa <- c(
    status,
    list(
      combined_rows = nrow(output_data),
      shared_watershed_alias_rows = sum(
        output_data$watershed_alias_flag
      ),
      output = output,
      assets = asset_qa
    )
  )
  writeLines(
    jsonlite::toJSON(
      qa,
      auto_unbox = TRUE,
      null = "null",
      na = "null",
      digits = NA,
      pretty = TRUE
    ),
    qa_path
  )
  cat("Combined output: ", output, "\n", sep = "")
  cat("QA summary: ", qa_path, "\n", sep = "")
}
