### Setup

major_glc_script_path <- function() {
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
    "workflow/gee/land_cover/consolidate_safe_glc_major_land_exports.R"
  )
}

source(file.path(
  dirname(major_glc_script_path()),
  "glc_consolidation_helpers.R"
))

major_land_classes <- c(
  "Bare",
  "Cropland",
  "Forest",
  "Grassland_Shrubland",
  "Ice_Snow",
  "Impervious",
  "Open_water",
  "Tidal_Wetland",
  "Wetland_Marsh"
)
major_output_columns <- c(
  glc_metadata,
  "source",
  "major_land",
  "major_land_definition",
  "major_land_mean_fraction",
  "major_land_tie_count",
  "major_land_tie_flag",
  "source_year_weights",
  "total_temporal_weight",
  "valid_temporal_weight",
  "extraction_method",
  "requested_sample_n",
  "sampling_seed",
  "polygon_area_m2",
  "native_pixel_estimate",
  "effective_pixel_band_time",
  "glc_geometry_simplified_m",
  "glc_simplification_area_error_pct",
  "local_point_file_sha256",
  "local_point_source_geometry_sha256",
  "local_point_sampling_crs",
  "sampled_reducer_version",
  glc_alias_columns
)

### Major-land output checks

normalize_major_row <- function(properties) {
  row <- properties
  row$site_id <- as.character(row$site_id %||% "")
  row$major_land <- as.character(row$major_land %||% "")
  integer_fields <- c(
    "major_land_tie_count",
    "total_temporal_weight",
    "valid_temporal_weight"
  )
  numeric_fields <- c(
    "major_land_mean_fraction",
    "requested_sample_n",
    "sampling_seed",
    "polygon_area_m2",
    "native_pixel_estimate",
    "effective_pixel_band_time",
    "glc_geometry_simplified_m",
    "glc_simplification_area_error_pct"
  )
  for (name in integer_fields) {
    row[[name]] <- as.integer(row[[name]] %||% NA_integer_)
  }
  for (name in numeric_fields) {
    row[[name]] <- as.numeric(row[[name]] %||% NA_real_)
  }
  row
}

validate_major_rows <- function(rows, plan) {
  if (!length(rows)) {
    stop("The major-land asset has no rows: ", plan$asset_id)
  }
  data <- glc_rows_to_data_frame(rows, major_output_columns)
  if (!identical(unique(data$site_id), plan$site$site_id)) {
    stop("The major-land asset has the wrong site ID: ", plan$asset_id)
  }
  invalid_classes <- !all(data$major_land %in% major_land_classes)
  if (anyDuplicated(data$major_land) || invalid_classes) {
    stop(
      "The major-land asset has invalid or duplicate classes: ",
      plan$asset_id
    )
  }

  expected_tie <- nrow(data)
  expected_flag <- if (expected_tie > 1L) "yes" else "no"
  correct_tie_count <- isTRUE(all(
    data$major_land_tie_count == expected_tie
  ))
  correct_tie_flag <- identical(
    unique(data$major_land_tie_flag),
    expected_flag
  )
  if (!correct_tie_count || !correct_tie_flag) {
    stop("The major-land tie fields do not agree: ", plan$asset_id)
  }

  fractions <- data$major_land_mean_fraction
  invalid_fraction <- any(!is.finite(fractions)) ||
    any(fractions < 0 | fractions > 1)
  unequal_tie <- diff(range(fractions)) > 1e-12
  if (invalid_fraction || unequal_tie) {
    stop("The major-land fractions are invalid: ", plan$asset_id)
  }

  total_weights <- unique(data$total_temporal_weight)
  valid_weights <- unique(data$valid_temporal_weight)
  invalid_weight <- length(valid_weights) != 1L ||
    !is.finite(valid_weights) ||
    valid_weights < 1L ||
    valid_weights > 123L
  if (!identical(total_weights, 123L) || invalid_weight) {
    stop("The major-land temporal weights are invalid: ", plan$asset_id)
  }

  expected_method <- if (plan$method == "exact") {
    "native_30m_exact"
  } else {
    "deterministic_local_equal_area_points_v1"
  }
  if (!identical(unique(data$extraction_method), expected_method)) {
    stop("The major-land extraction method is wrong: ", plan$asset_id)
  }
  list(
    site_id = plan$site$site_id,
    method = plan$method,
    rows = nrow(data),
    major_land = data$major_land,
    major_land_mean_fraction = fractions[[1]],
    valid_temporal_weight = valid_weights[[1]]
  )
}

### Major-land consolidation

major_land_settings <- function() {
  list(
    label = "Major-land GLC",
    output_stem = "glc_major_land_safe_combined",
    normalize = normalize_major_row,
    validate = validate_major_rows,
    to_data_frame = function(rows) {
      glc_rows_to_data_frame(rows, major_output_columns)
    },
    row_key = function(row) {
      paste(row$site_id, row$major_land, sep = ":")
    },
    expected_rows = function(site_count) NULL,
    order_by = c("site_id", "major_land")
  )
}

major_glc_main <- function() {
  args <- glc_parse_args(commandArgs(trailingOnly = TRUE))
  run_glc_consolidation(major_land_settings(), args)
}

if (sys.nframe() == 0L) {
  tryCatch(
    major_glc_main(),
    error = function(error) {
      message("Major-land GLC consolidation failed: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
