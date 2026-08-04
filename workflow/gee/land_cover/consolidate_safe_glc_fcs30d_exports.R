### Setup

consolidation_script_path <- function() {
  source_files <- vapply(sys.frames(), function(frame) {
    if (is.null(frame$ofile)) "" else as.character(frame$ofile)
  }, character(1))
  source_files <- source_files[nzchar(source_files)]
  if (length(source_files)) {
    return(normalizePath(tail(source_files, 1)))
  }
  file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(file_arg)) {
    return(normalizePath(sub("^--file=", "", file_arg[[1]])))
  }
  normalizePath(
    "workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.R"
  )
}

source(file.path(dirname(dirname(consolidation_script_path())), "gee_api.R"))

glc_years <- c(1985L, 1990L, 1995L, 2000:2022)
glc_classes <- c(
  0L, 10L, 11L, 12L, 20L, 50L, 51L, 52L, 61L, 62L,
  71L, 72L, 81L, 82L, 91L, 92L, 120L, 121L, 122L,
  130L, 140L, 150L, 152L, 153L, 181L, 182L, 183L,
  184L, 185L, 186L, 187L, 190L, 200L, 201L, 202L,
  210L, 220L
)
glc_metadata <- c("site_id", "LTER", "Stream_Name", "Shapefile_Name")
glc_scale_m <- 30
glc_default_sample_points <- 100000L
glc_default_run_root <- "generated_outputs/gee/glc-fcs30d-safe"
glc_output_columns <- c(
  glc_metadata,
  "Year",
  "source",
  "LC_ID",
  "Area_m2",
  "extraction_method",
  "sample_count",
  "sample_n",
  "sample_fraction",
  "sample_standard_error",
  "requested_sample_n",
  "sampling_seed",
  "polygon_area_m2",
  "native_pixel_estimate",
  "effective_pixel_band_time",
  "glc_geometry_simplified_m",
  "glc_simplification_area_error_pct"
)

### Local planning

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
        stop("GeoJSON feature lacks metadata: ", paste(missing, collapse = ", "))
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

glc_plan_tasks <- function(
  sites,
  method,
  sample_points,
  exact_max_work,
  run_label,
  output_folder
) {
  if (!method %in% c("auto", "exact", "sample")) {
    stop("Method must be auto, exact, or sample")
  }
  if (sample_points < 10000L) {
    stop("At least 10,000 sample points are required")
  }
  plans <- lapply(sites, function(site) {
    native_pixels <- site$area_km2 * 1000000 / (glc_scale_m^2)
    exact_work <- native_pixels * length(glc_years)
    selected_method <- method
    if (method == "auto") {
      selected_method <- if (exact_work <= exact_max_work) "exact" else "sample"
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
      asset_id = paste0(sub("/+$", "", output_folder), "/", description),
      site = site,
      method = selected_method,
      sample_points = if (selected_method == "sample") sample_points else 0L,
      native_pixel_estimate = native_pixels,
      effective_pixel_band_time = if (selected_method == "exact") {
        exact_work
      } else {
        sample_points * length(glc_years)
      }
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

### Output validation

glc_normalize_row <- function(properties) {
  row <- properties
  row$site_id <- as.character(row$site_id %||% "")
  row$Year <- as.integer(row$Year)
  row$LC_ID <- as.integer(row$LC_ID)
  numeric_columns <- c(
    "Area_m2",
    "sample_count",
    "sample_n",
    "sample_fraction",
    "sample_standard_error",
    "requested_sample_n",
    "sampling_seed",
    "polygon_area_m2",
    "native_pixel_estimate",
    "effective_pixel_band_time"
  )
  for (name in numeric_columns) {
    row[[name]] <- as.numeric(row[[name]] %||% NA_real_)
  }
  row
}

glc_validate_asset_rows <- function(rows, plan) {
  expected_count <- length(glc_years) * length(glc_classes)
  if (length(rows) != expected_count) {
    stop(plan$asset_id, " has ", length(rows), " rows; expected ", expected_count)
  }
  keys <- vapply(
    rows,
    function(row) paste(row$Year, row$LC_ID, sep = ":"),
    character(1)
  )
  expected_keys <- as.vector(outer(glc_years, glc_classes, paste, sep = ":"))
  if (anyDuplicated(keys) || !setequal(keys, expected_keys)) {
    stop("Incomplete or duplicate year/class keys in ", plan$asset_id)
  }
  if (!identical(unique(vapply(rows, `[[`, character(1), "site_id")), plan$site$site_id)) {
    stop("Wrong site_id in ", plan$asset_id)
  }
  expected_method <- if (plan$method == "exact") {
    "native_30m_exact"
  } else {
    "deterministic_local_equal_area_points_v1"
  }
  methods <- unique(vapply(
    rows,
    function(row) as.character(row$extraction_method %||% ""),
    character(1)
  ))
  if (!identical(methods, expected_method)) {
    stop("Wrong extraction_method in ", plan$asset_id)
  }

  minimum_sample_n <- NULL
  maximum_fraction_error <- 0
  for (year in glc_years) {
    year_rows <- Filter(function(row) row$Year == year, rows)
    area_sum <- sum(vapply(year_rows, `[[`, numeric(1), "Area_m2"))
    if (!is.finite(area_sum) || area_sum <= 0) {
      stop("Non-positive class area for ", plan$site$site_id, ", ", year)
    }
    if (plan$method == "sample") {
      sample_sizes <- unique(vapply(year_rows, `[[`, numeric(1), "sample_n"))
      if (length(sample_sizes) != 1L) {
        stop("Inconsistent sample_n for ", plan$site$site_id, ", ", year)
      }
      sample_n <- sample_sizes[[1]]
      minimum_sample_n <- if (is.null(minimum_sample_n)) {
        sample_n
      } else {
        min(minimum_sample_n, sample_n)
      }
      if (sample_n < 0.99 * plan$sample_points) {
        stop("Too few classified samples for ", plan$site$site_id, ", ", year)
      }
      count_sum <- sum(vapply(year_rows, `[[`, numeric(1), "sample_count"))
      if (abs(count_sum - sample_n) > 0.5) {
        stop("Class counts do not sum to sample_n")
      }
      fraction_error <- abs(
        sum(vapply(year_rows, `[[`, numeric(1), "sample_fraction")) - 1
      )
      maximum_fraction_error <- max(maximum_fraction_error, fraction_error)
      if (fraction_error > 1e-6) {
        stop("Sample fractions do not sum to one")
      }
      polygon_area <- year_rows[[1]]$polygon_area_m2
      if (!isTRUE(all.equal(area_sum, polygon_area, tolerance = 1e-6))) {
        stop("Sampled class areas do not sum to watershed area")
      }
    }
  }
  list(
    site_id = plan$site$site_id,
    method = plan$method,
    rows = length(rows),
    minimum_sample_n = minimum_sample_n,
    maximum_fraction_sum_error = maximum_fraction_error
  )
}

glc_rows_to_data_frame <- function(rows) {
  frames <- lapply(rows, function(row) {
    as.data.frame(row, stringsAsFactors = FALSE, optional = TRUE)
  })
  output <- dplyr::bind_rows(frames)
  missing <- setdiff(glc_output_columns, names(output))
  for (name in missing) {
    output[[name]] <- NA
  }
  output[, glc_output_columns, drop = FALSE]
}

### Command line

glc_consolidation_main <- function() {
  args <- glc_parse_args(commandArgs(trailingOnly = TRUE))
  project <- args$project %||% "silica-synthesis"
  run_label <- args$run_label %||% stop("Missing --run-label")
  run_root <- args$run_root %||% glc_default_run_root
  manifest <- args$manifest %||% file.path(run_root, "payload_manifest.csv")
  output_folder <- args$output_folder %||% sprintf(
    "projects/%s/assets/glc_fcs30d_safe_%s",
    project,
    run_label
  )
  method <- args$method %||% "auto"
  sample_points <- as.integer(args$sample_points %||% glc_default_sample_points)
  exact_max_work <- as.numeric(
    args$exact_max_work %||% (sample_points * length(glc_years))
  )
  expected_site_count <- if (is.null(args$expected_site_count)) {
    NULL
  } else {
    as.integer(args$expected_site_count)
  }
  output <- args$output %||% file.path(
    run_root,
    paste0("glc_fcs30d_safe_combined_", run_label, ".csv")
  )
  sites <- glc_load_sites(manifest)
  if (!is.null(expected_site_count) && length(sites) != expected_site_count) {
    stop("Found ", length(sites), " sites; expected ", expected_site_count)
  }
  plans <- glc_plan_tasks(
    sites,
    method,
    sample_points,
    exact_max_work,
    run_label,
    output_folder
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
  status <- list(
    expected_assets = length(plans),
    complete_assets = length(plans) - length(missing),
    missing_assets = length(missing),
    expected_sites = length(sites),
    expected_rows = length(sites) * length(glc_years) * length(glc_classes)
  )
  cat(
    "Safe GLC consolidation status: ",
    jsonlite::toJSON(status, auto_unbox = TRUE),
    "\n",
    sep = ""
  )
  if (!isTRUE(args$download)) {
    cat("Read-only status complete; use --download only when all assets exist\n")
    return(invisible(NULL))
  }
  if (length(missing)) {
    stop("Refusing a partial download; ", length(missing), " assets are missing")
  }

  all_rows <- list()
  asset_qa <- list()
  for (index in seq_along(plans)) {
    plan <- plans[[index]]
    features <- gee_compute_features(plan$asset_id, project, token)
    rows <- lapply(features, function(feature) {
      glc_normalize_row(feature$properties %||% list())
    })
    asset_qa[[index]] <- glc_validate_asset_rows(rows, plan)
    all_rows <- c(all_rows, rows)
    cat("Downloaded and validated ", index, "/", length(plans), "\n", sep = "")
  }
  combined_keys <- vapply(
    all_rows,
    function(row) paste(row$site_id, row$Year, row$LC_ID, sep = ":"),
    character(1)
  )
  if (anyDuplicated(combined_keys) || length(all_rows) != status$expected_rows) {
    stop("The combined site/year/class keys are incomplete or duplicated")
  }
  output_data <- glc_rows_to_data_frame(all_rows)
  output_data <- output_data[order(
    output_data$site_id,
    output_data$Year,
    output_data$LC_ID
  ), , drop = FALSE]
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
  cat("QA receipt: ", qa_path, "\n", sep = "")
}

if (sys.nframe() == 0L) {
  tryCatch(
    glc_consolidation_main(),
    error = function(error) {
      message("SAFE GLC CONSOLIDATION ERROR: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
