### Setup

source(file.path("workflow", "lib", "workflow_helpers.R"))
repo_root <- silica_find_repo_root()
setwd(repo_root)
source(file.path(
  "workflow", "gee", "land_cover",
  "consolidate_safe_glc_fcs30d_exports.R"
))

args <- commandArgs(trailingOnly = TRUE)
unknown_args <- setdiff(args, "--download")
if (length(unknown_args)) {
  stop("Unexpected argument: ", unknown_args[[1]], call. = FALSE)
}
download <- "--download" %in% args
project <- "silica-synthesis"
rerun_root <- file.path("generated_outputs", "spatial-rerun-20260815")

glc_groups <- list(
  list(
    label = "boundary-fix 66",
    payload_list = file.path(
      rerun_root, "glc-payloads", "payload_manifest.csv"
    ),
    site_file = file.path(rerun_root, "glc-payloads", "site_inventory.csv"),
    run_label = "release3_20260815_boundary_fix",
    asset_folder = paste0(
      "projects/silica-synthesis/assets/",
      "glc_fcs30d_safe_release3_20260815_boundary_fix"
    ),
    site_count = 66L
  ),
  list(
    label = "remaining 85",
    payload_list = file.path(
      rerun_root, "glc-remaining-85-payloads", "payload_manifest.csv"
    ),
    site_file = file.path(
      rerun_root, "glc-remaining-85-payloads", "site_inventory.csv"
    ),
    run_label = "release3_20260815_remaining_85",
    asset_folder = paste0(
      "projects/silica-synthesis/assets/",
      "glc_fcs30d_safe_release3_20260815_remaining_85"
    ),
    site_count = 85L
  )
)

era5_groups <- list(
  list(
    label = "boundary-fix 66",
    payload_list = file.path(
      rerun_root, "era5-payloads", "payload_manifest.csv"
    ),
    site_file = file.path(rerun_root, "era5-payloads", "site_inventory.csv"),
    run_label = "release3_20260815_boundary_fix",
    asset_folder = paste0(
      "projects/silica-synthesis/assets/",
      "era5_land_release3_20260815_boundary_fix"
    ),
    site_count = 66L,
    payload_rows = 1L
  ),
  list(
    label = "remaining 85",
    payload_list = file.path(
      rerun_root, "era5-remaining-85-payloads", "payload_manifest.csv"
    ),
    site_file = file.path(
      rerun_root, "era5-remaining-85-payloads", "site_inventory.csv"
    ),
    run_label = "release3_20260815_remaining_85",
    asset_folder = paste0(
      "projects/silica-synthesis/assets/",
      "era5_land_release3_20260815_remaining_85"
    ),
    site_count = 85L,
    payload_rows = 6L
  )
)

glc_output <- file.path(
  rerun_root, "glc", "glc_fcs30d_replacements_151_20260815.csv"
)
era5_output <- file.path(
  rerun_root, "era5-land", "era5_land_replacements_151_20260815.csv"
)
qa_output <- file.path(
  rerun_root,
  "gee_replacements_151_20260815_qa.rds"
)
era5_years <- 2000:2025
era5_metrics <- c(
  "precip_mm", "temp_degC", "evapotrans_mm", "potential_evap_mm",
  "snow_cover_fraction", "snow_water_equiv_mm"
)
era5_columns <- c("site_id", "year", era5_metrics)

group_input_files <- function(groups) {
  unique(unlist(lapply(groups, function(group) {
    payloads <- read.csv(
      group$payload_list,
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
    assert_required_columns(payloads, "path", group$payload_list)
    c(
      group$payload_list,
      group$site_file,
      file.path(dirname(group$payload_list), payloads$path)
    )
  }), use.names = FALSE))
}


### Input checks

read_sites <- function(path, expected_count) {
  data <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  assert_required_columns(
    data,
    c("site_id", "LTER", "Stream_Name", "Shapefile_Name"),
    basename(path)
  )
  data$site_id <- trimws(data$site_id)
  if (
    nrow(data) != expected_count || any(!nzchar(data$site_id)) ||
      anyDuplicated(data$site_id)
  ) {
    stop(
      basename(path), " must contain exactly ", expected_count,
      " unique, nonblank site IDs",
      call. = FALSE
    )
  }
  data
}

attach_sites <- function(groups) {
  lapply(groups, function(group) {
    group$sites <- read_sites(group$site_file, group$site_count)
    group
  })
}

glc_groups <- attach_sites(glc_groups)
era5_groups <- attach_sites(era5_groups)

glc_ids <- unlist(lapply(glc_groups, function(group) group$sites$site_id))
era5_ids <- unlist(lapply(era5_groups, function(group) group$sites$site_id))
if (
  length(glc_ids) != 151L || anyDuplicated(glc_ids) ||
    length(era5_ids) != 151L || anyDuplicated(era5_ids) ||
    !setequal(glc_ids, era5_ids)
) {
  stop(
    "GLC and ERA5-Land inputs must contain the same 151 primary geometry IDs",
    call. = FALSE
  )
}

remaining_era5_payloads <- read.csv(
  era5_groups[[2L]]$payload_list,
  stringsAsFactors = FALSE,
  check.names = FALSE
)
expected_remaining_payloads <- sprintf(
  "era5_remaining_01_part_%02d",
  seq_len(6L)
)
if (!identical(
  as.character(remaining_era5_payloads$payload),
  expected_remaining_payloads
)) {
  stop("The retained six-part ERA5-Land payload list changed", call. = FALSE)
}
input_paths <- unique(c(
  group_input_files(glc_groups),
  group_input_files(era5_groups)
))
if (any(!file.exists(input_paths))) {
  stop("A retained GEE consolidation input is missing", call. = FALSE)
}
input_file_records <- file_records(input_paths, basename(input_paths))


### Asset status

list_assets_if_present <- function(folder, token) {
  tryCatch(
    gee_list_assets(folder, project, token),
    error = function(error) {
      message <- conditionMessage(error)
      if (grepl("404|Not Found|does not exist", message, ignore.case = TRUE)) {
        return(list())
      }
      stop(error)
    }
  )
}

asset_names <- function(folder, token) {
  assets <- list_assets_if_present(folder, token)
  vapply(
    assets,
    function(asset) as.character(asset$name %||% ""),
    character(1)
  )
}

expected_glc_assets <- function(group) {
  sites <- glc_load_sites(group$payload_list)
  plans <- glc_plan_tasks(
    sites = sites,
    method = "auto",
    sample_points = 10000L,
    exact_max_work = 260000,
    run_label = group$run_label,
    output_folder = group$asset_folder,
    minimum_sample_fraction = 0.99
  )
  if (
    length(plans) != group$site_count ||
      !setequal(
        vapply(plans, function(plan) plan$site$site_id, character(1)),
        group$sites$site_id
      )
  ) {
    stop("GLC task plan does not match ", group$label, call. = FALSE)
  }
  vapply(plans, `[[`, character(1), "asset_id")
}

safe_asset_part <- function(value) {
  value <- tolower(value)
  value <- gsub("[^a-z0-9_-]+", "_", value)
  gsub("^[_-]+|[_-]+$", "", value)
}

expected_era5_assets <- function(group) {
  payloads <- read.csv(
    group$payload_list,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  assert_required_columns(payloads, c("payload", "sites"), group$payload_list)
  if (
    nrow(payloads) != group$payload_rows ||
      sum(as.integer(payloads$sites)) != group$site_count ||
      anyDuplicated(payloads$payload)
  ) {
    stop("ERA5-Land payload count does not match ", group$label, call. = FALSE)
  }
  payload_names <- as.character(payloads$payload)
  as.vector(vapply(payload_names, function(payload) {
    paste0(
      group$asset_folder,
      "/era5a6_", group$run_label, "_", safe_asset_part(payload), "_",
      era5_years
    )
  }, character(length(era5_years))))
}

check_group_status <- function(group, expected, token, family) {
  available <- asset_names(group$asset_folder, token)
  missing <- setdiff(expected, available)
  unexpected <- setdiff(available, expected)
  cat(
    family, " ", group$label, ": ",
    length(expected) - length(missing), "/", length(expected),
    " expected assets complete",
    if (length(unexpected)) paste0("; ", length(unexpected), " unexpected") else "",
    "\n",
    sep = ""
  )
  list(
    complete = !length(missing) && !length(unexpected),
    missing = missing,
    unexpected = unexpected
  )
}

token <- gee_access_token()
glc_expected <- lapply(glc_groups, expected_glc_assets)
era5_expected <- lapply(era5_groups, expected_era5_assets)
glc_status <- Map(
  check_group_status, glc_groups, glc_expected,
  MoreArgs = list(token = token, family = "GLC")
)
era5_status <- Map(
  check_group_status, era5_groups, era5_expected,
  MoreArgs = list(token = token, family = "ERA5-Land")
)

all_complete <- all(vapply(
  c(glc_status, era5_status),
  `[[`, logical(1), "complete"
))
if (!download) {
  if (all_complete) {
    cat("All release-three replacement assets are ready; use --download.\n")
  } else {
    cat("Status only; no local output was written.\n")
  }
  quit(status = 0L)
}
if (!all_complete) {
  stop(
    "No output was written because at least one Earth Engine run is incomplete",
    call. = FALSE
  )
}


### GLC consolidation

download_glc_group <- function(group) {
  temporary_output <- tempfile(fileext = ".csv")
  temporary_qa <- sub("[.]csv$", ".qa.json", temporary_output)
  on.exit({
    unlink(temporary_output)
    unlink(temporary_qa)
  }, add = TRUE)
  run_glc_consolidation(
    annual_glc_settings(),
    list(
      project = project,
      run_label = group$run_label,
      manifest = group$payload_list,
      output_folder = group$asset_folder,
      method = "auto",
      sample_points = "10000",
      exact_max_work = "260000",
      minimum_sample_fraction = "0.99",
      expected_site_count = as.character(group$site_count),
      output = temporary_output,
      download = TRUE
    )
  )
  data <- read.csv(
    temporary_output,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  source_qa <- jsonlite::fromJSON(temporary_qa, simplifyDataFrame = TRUE)
  site_index <- match(data$site_id, group$sites$site_id)
  if (
    !identical(names(data), glc_output_columns) ||
      !setequal(unique(data$site_id), group$sites$site_id) ||
      any(is.na(site_index)) ||
      any(is.na(data$LTER) | data$LTER != group$sites$LTER[site_index]) ||
      any(
        is.na(data$Stream_Name) |
          data$Stream_Name != group$sites$Stream_Name[site_index]
      ) ||
      any(
        is.na(data$Shapefile_Name) |
          data$Shapefile_Name != group$sites$Shapefile_Name[site_index]
      ) ||
      any(is.na(data$watershed_alias_flag) | data$watershed_alias_flag)
  ) {
    stop(
      "GLC consolidation changed the expected primary geometry IDs or schema for ",
      group$label,
      call. = FALSE
    )
  }
  list(data = data, source_qa = source_qa)
}

glc_downloads <- lapply(glc_groups, download_glc_group)
glc <- do.call(rbind, lapply(glc_downloads, `[[`, "data"))
glc_key <- paste(glc$site_id, glc$Year, glc$LC_ID, sep = "\r")
expected_glc_rows <- 151L * length(glc_years) * length(glc_classes)
if (
  nrow(glc) != expected_glc_rows || anyDuplicated(glc_key) ||
    !setequal(unique(glc$site_id), glc_ids) ||
    !setequal(unique(glc$Year), glc_years) ||
    !setequal(unique(glc$LC_ID), glc_classes) ||
    any(!is.finite(glc$Area_m2) | glc$Area_m2 < 0) ||
    any(!is.finite(glc$polygon_area_m2) | glc$polygon_area_m2 <= 0)
) {
  stop("The combined GLC rows fail grid or numeric checks", call. = FALSE)
}

site_year <- paste(glc$site_id, glc$Year, sep = "\r")
area_sum <- rowsum(glc$Area_m2, site_year, reorder = FALSE)
polygon_area <- tapply(glc$polygon_area_m2, site_year, function(value) {
  value <- unique(value)
  if (length(value) == 1L) value else NA_real_
})
polygon_area <- polygon_area[rownames(area_sum)]
closure <- abs(area_sum[, 1] - polygon_area) / polygon_area
if (any(!is.finite(closure) | closure > 0.011)) {
  stop("The combined GLC rows fail watershed-area closure", call. = FALSE)
}
glc <- glc[order(glc$site_id, glc$Year, glc$LC_ID), , drop = FALSE]

sampled_glc <- glc$extraction_method ==
  "deterministic_local_equal_area_points_v1"
if (
  any(!glc$extraction_method %in% c(
    "native_30m_exact",
    "deterministic_local_equal_area_points_v1"
  )) ||
    any(sampled_glc & (
      !is.finite(glc$sample_n) | glc$sample_n <= 0 |
        !is.finite(glc$sample_standard_error) |
        glc$sample_standard_error < 0 |
        !is.finite(glc$sample_fraction) |
        glc$sample_fraction < 0 | glc$sample_fraction > 1
    ))
) {
  stop("The combined GLC sampling diagnostics are invalid", call. = FALSE)
}

glc_site_qa <- do.call(rbind, lapply(split(glc, glc$site_id), function(data) {
  years <- split(data, data$Year)
  closure_by_year <- vapply(years, function(year_data) {
    abs(sum(year_data$Area_m2) - unique(year_data$polygon_area_m2)) /
      unique(year_data$polygon_area_m2)
  }, numeric(1L))
  finite_sample_n <- data$sample_n[is.finite(data$sample_n)]
  finite_standard_error <- data$sample_standard_error[
    is.finite(data$sample_standard_error)
  ]
  data.frame(
    site_id = data$site_id[[1L]],
    extraction_method = unique(data$extraction_method),
    minimum_sample_n = if (length(finite_sample_n)) {
      min(finite_sample_n)
    } else {
      NA_real_
    },
    maximum_sample_standard_error = if (length(finite_standard_error)) {
      max(finite_standard_error)
    } else {
      NA_real_
    },
    maximum_area_closure_relative_error = max(closure_by_year),
    stringsAsFactors = FALSE
  )
}))
row.names(glc_site_qa) <- NULL
if (nrow(glc_site_qa) != 151L || anyDuplicated(glc_site_qa$site_id)) {
  stop("The GLC per-site QA table is incomplete", call. = FALSE)
}


### ERA5-Land consolidation

properties_to_row <- function(properties, columns) {
  values <- lapply(columns, function(name) properties[[name]] %||% NA)
  names(values) <- columns
  as.data.frame(values, stringsAsFactors = FALSE, optional = TRUE)
}

download_era5_group <- function(group, assets) {
  metadata_columns <- c(
    "site_id", "lter", "stream_name", "shapefile_name", "period", "year",
    era5_metrics, "used_fine_scale_fallback", "source_image_count"
  )
  rows <- vector("list", length(assets))
  for (index in seq_along(assets)) {
    features <- gee_compute_features(assets[[index]], project, token)
    rows[[index]] <- do.call(rbind, lapply(features, function(feature) {
      properties_to_row(feature$properties %||% list(), metadata_columns)
    }))
    cat(
      "Downloaded and checked ERA5-Land ", group$label, " ",
      index, "/", length(assets), "\n",
      sep = ""
    )
  }
  data <- do.call(rbind, rows)
  data$site_id <- trimws(data$site_id)
  data$year <- suppressWarnings(as.integer(data$year))
  data$source_image_count <- suppressWarnings(as.integer(data$source_image_count))
  data$used_fine_scale_fallback <- suppressWarnings(as.integer(
    data$used_fine_scale_fallback
  ))
  data[era5_metrics] <- lapply(data[era5_metrics], function(value) {
    suppressWarnings(as.numeric(value))
  })

  key <- paste(data$site_id, data$year, sep = "\r")
  expected <- expand.grid(
    site_id = group$sites$site_id,
    year = era5_years,
    stringsAsFactors = FALSE
  )
  expected_key <- paste(expected$site_id, expected$year, sep = "\r")
  expected_days <- ifelse(
    expected$year %% 400L == 0L |
      (expected$year %% 4L == 0L & expected$year %% 100L != 0L),
    366L,
    365L
  )
  data <- data[match(expected_key, key), , drop = FALSE]
  inventory_index <- match(data$site_id, group$sites$site_id)
  if (
    anyDuplicated(key) || !setequal(key, expected_key) ||
      any(is.na(inventory_index)) ||
      any(is.na(data$lter) | data$lter != group$sites$LTER[inventory_index]) ||
      any(
        is.na(data$stream_name) |
          data$stream_name != group$sites$Stream_Name[inventory_index]
      ) ||
      any(
        is.na(data$shapefile_name) |
          data$shapefile_name != group$sites$Shapefile_Name[inventory_index]
      ) ||
      any(is.na(data$period) | data$period != "annual") ||
      any(
        is.na(data$source_image_count) |
          data$source_image_count != expected_days
      ) ||
      any(
        is.na(data$used_fine_scale_fallback) |
          !data$used_fine_scale_fallback %in% c(0L, 1L)
      ) ||
      any(!is.finite(as.matrix(data[era5_metrics])))
  ) {
    stop(
      "ERA5-Land rows fail coverage, metadata, or completeness checks for ",
      group$label,
      call. = FALSE
    )
  }
  list(
    data = data[, era5_columns, drop = FALSE],
    qa = data[, c(
      "site_id", "year", "used_fine_scale_fallback", "source_image_count"
    ), drop = FALSE]
  )
}

era5_downloads <- Map(download_era5_group, era5_groups, era5_expected)
era5 <- do.call(rbind, lapply(era5_downloads, `[[`, "data"))
era5_row_qa <- do.call(rbind, lapply(era5_downloads, `[[`, "qa"))
era5_key <- paste(era5$site_id, era5$year, sep = "\r")
if (
  nrow(era5) != 151L * length(era5_years) || anyDuplicated(era5_key) ||
    !setequal(unique(era5$site_id), era5_ids) ||
    !setequal(unique(era5$year), era5_years) ||
    any(!is.finite(as.matrix(era5[era5_metrics]))) ||
    any(era5$precip_mm < 0) ||
    any(era5$evapotrans_mm < 0) ||
    any(era5$potential_evap_mm < 0) ||
    any(era5$temp_degC < -90 | era5$temp_degC > 60) ||
    any(era5$snow_cover_fraction < 0 | era5$snow_cover_fraction > 1) ||
    any(era5$snow_water_equiv_mm < 0)
) {
  stop("The combined ERA5-Land rows fail grid or physical-range checks", call. = FALSE)
}
era5 <- era5[order(era5$site_id, era5$year), , drop = FALSE]
era5_row_qa <- era5_row_qa[
  order(era5_row_qa$site_id, era5_row_qa$year),
  ,
  drop = FALSE
]
if (!identical(
  paste(era5_row_qa$site_id, era5_row_qa$year, sep = "\r"),
  paste(era5$site_id, era5$year, sep = "\r")
)) {
  stop("ERA5-Land QA rows do not align with the consolidated values")
}


### Final outputs

dir.create(dirname(glc_output), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(era5_output), recursive = TRUE, showWarnings = FALSE)
final_paths <- c(glc_output, era5_output, qa_output)
if (any(file.exists(final_paths))) {
  stop("A release-three GEE consolidation output already exists", call. = FALSE)
}
input_md5_after <- unname(tools::md5sum(input_paths))
if (!identical(input_file_records$md5, input_md5_after)) {
  stop("A retained GEE consolidation input changed during download")
}
input_file_records$md5_after <- input_md5_after
input_file_records$unchanged_during_download <- TRUE

stage <- tempfile("gee-replacements-20260815-", tmpdir = rerun_root)
dir.create(stage)
on.exit(unlink(stage, recursive = TRUE), add = TRUE)
stage_glc <- file.path(stage, basename(glc_output))
stage_era5 <- file.path(stage, basename(era5_output))
stage_qa <- file.path(stage, basename(qa_output))
write.csv(glc, stage_glc, row.names = FALSE, na = "")
write.csv(era5, stage_era5, row.names = FALSE, na = "")

glc_check <- read.csv(stage_glc, stringsAsFactors = FALSE, check.names = FALSE)
era5_check <- read.csv(stage_era5, stringsAsFactors = FALSE, check.names = FALSE)
row.names(glc) <- NULL
row.names(era5) <- NULL
if (!isTRUE(all.equal(
  glc,
  glc_check,
  check.attributes = FALSE,
  tolerance = 1e-12
)) || !isTRUE(all.equal(
  era5,
  era5_check,
  check.attributes = FALSE,
  tolerance = 1e-12
))) {
  stop("A staged GEE consolidation CSV failed exact read-back QA")
}

output_file_records <- file_records(
  c(stage_glc, stage_era5),
  c("glc", "era5_land")
)
output_file_records$path <- normalizePath(
  c(glc_output, era5_output),
  mustWork = FALSE
)
qa <- list(
  built_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  input_files = input_file_records,
  expected_assets = list(
    glc = unname(unlist(glc_expected, use.names = FALSE)),
    era5_land = unname(unlist(era5_expected, use.names = FALSE))
  ),
  asset_counts = data.frame(
    family = c("GLC", "ERA5-Land"),
    expected = c(length(unlist(glc_expected)), length(unlist(era5_expected))),
    complete = c(length(unlist(glc_expected)), length(unlist(era5_expected))),
    stringsAsFactors = FALSE
  ),
  glc = list(
    rows = nrow(glc),
    sites = length(unique(glc$site_id)),
    method_counts = as.data.frame(table(glc_site_qa$extraction_method)),
    per_site = glc_site_qa,
    source_checks = lapply(glc_downloads, `[[`, "source_qa")
  ),
  era5_land = list(
    rows = nrow(era5),
    sites = length(unique(era5$site_id)),
    fine_scale_fallback_rows = sum(
      era5_row_qa$used_fine_scale_fallback == 1L
    ),
    per_site_year = era5_row_qa
  ),
  outputs = output_file_records,
  checks = list(
    glc_grid_complete = TRUE,
    glc_area_closure_passed = TRUE,
    glc_sampling_diagnostics_valid = TRUE,
    era5_grid_complete = TRUE,
    era5_source_image_counts_valid = TRUE,
    era5_physical_ranges_valid = TRUE,
    staged_csv_readback_equal = TRUE
  )
)
saveRDS(qa, stage_qa, compress = "xz")
qa_check <- readRDS(stage_qa)
if (
  qa_check$glc$rows != nrow(glc) ||
    qa_check$era5_land$rows != nrow(era5) ||
    nrow(qa_check$glc$per_site) != 151L ||
    nrow(qa_check$era5_land$per_site_year) != 151L * length(era5_years)
) {
  stop("The staged GEE QA record failed read-back QA")
}

installed <- file.copy(
  c(stage_glc, stage_era5, stage_qa),
  final_paths,
  overwrite = FALSE
)
if (!all(installed) || !identical(
  unname(tools::md5sum(final_paths[1:2])),
  output_file_records$md5
)) {
  stop("Could not install the verified GEE consolidation outputs")
}

cat("GLC rows: ", nrow(glc), "; sites: ", length(unique(glc$site_id)), "\n", sep = "")
cat(
  "ERA5-Land rows: ", nrow(era5),
  "; sites: ", length(unique(era5$site_id)), "\n",
  sep = ""
)
cat("GLC output: ", glc_output, "\n", sep = "")
cat("ERA5-Land output: ", era5_output, "\n", sep = "")
cat("QA output: ", qa_output, "\n", sep = "")
