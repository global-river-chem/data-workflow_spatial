### Setup

annual_glc_script_path <- function() {
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

source(file.path(
  dirname(annual_glc_script_path()),
  "glc_consolidation_helpers.R"
))

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
  "glc_simplification_area_error_pct",
  glc_alias_columns
)
glc_sample_closure_tolerance <- 1e-6
glc_exact_boundary_tolerance <- 0.01

### Annual output checks

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
    stop(
      plan$asset_id,
      " has ",
      length(rows),
      " rows; expected ",
      expected_count
    )
  }
  keys <- vapply(
    rows,
    function(row) paste(row$Year, row$LC_ID, sep = ":"),
    character(1)
  )
  expected_keys <- as.vector(
    outer(glc_years, glc_classes, paste, sep = ":")
  )
  if (anyDuplicated(keys) || !setequal(keys, expected_keys)) {
    stop("Incomplete or duplicate year and class rows in ", plan$asset_id)
  }
  site_ids <- unique(vapply(rows, `[[`, character(1), "site_id"))
  if (!identical(site_ids, plan$site$site_id)) {
    stop("Wrong site ID in ", plan$asset_id)
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
    stop("Wrong extraction method in ", plan$asset_id)
  }

  minimum_sample_n <- NULL
  maximum_fraction_error <- 0
  maximum_area_closure_error <- 0
  minimum_sample_fraction <- glc_check_sample_fraction(
    plan$minimum_sample_fraction %||% 0.99
  )
  for (year in glc_years) {
    year_rows <- Filter(function(row) row$Year == year, rows)
    area_sum <- sum(vapply(year_rows, `[[`, numeric(1), "Area_m2"))
    if (!is.finite(area_sum) || area_sum <= 0) {
      stop("Non-positive class area for ", plan$site$site_id, ", ", year)
    }
    polygon_areas <- unique(vapply(
      year_rows,
      `[[`,
      numeric(1),
      "polygon_area_m2"
    ))
    if (
      length(polygon_areas) != 1L ||
        !is.finite(polygon_areas[[1]]) ||
        polygon_areas[[1]] <= 0
    ) {
      stop("Invalid watershed area for ", plan$site$site_id, ", ", year)
    }
    polygon_area <- polygon_areas[[1]]
    area_closure_error <- abs(area_sum - polygon_area) / polygon_area
    maximum_area_closure_error <- max(
      maximum_area_closure_error,
      area_closure_error
    )
    if (plan$method == "sample") {
      sample_sizes <- unique(vapply(
        year_rows,
        `[[`,
        numeric(1),
        "sample_n"
      ))
      if (length(sample_sizes) != 1L) {
        stop("Inconsistent sample size for ", plan$site$site_id, ", ", year)
      }
      sample_n <- sample_sizes[[1]]
      minimum_sample_n <- if (is.null(minimum_sample_n)) {
        sample_n
      } else {
        min(minimum_sample_n, sample_n)
      }
      if (sample_n < minimum_sample_fraction * plan$sample_points) {
        stop("Too few classified samples for ", plan$site$site_id, ", ", year)
      }
      count_sum <- sum(vapply(
        year_rows,
        `[[`,
        numeric(1),
        "sample_count"
      ))
      if (abs(count_sum - sample_n) > 0.5) {
        stop("Class counts do not sum to the sample size")
      }
      fraction_error <- abs(
        sum(vapply(
          year_rows,
          `[[`,
          numeric(1),
          "sample_fraction"
        )) - 1
      )
      maximum_fraction_error <- max(
        maximum_fraction_error,
        fraction_error
      )
      if (fraction_error > 1e-6) {
        stop("Sample fractions do not sum to one")
      }
      if (area_closure_error > glc_sample_closure_tolerance) {
        stop("Sampled class areas do not sum to the watershed area")
      }
    } else if (area_closure_error > glc_exact_boundary_tolerance) {
      stop("Exact class areas exceed the 1% raster-boundary limit")
    }
  }
  list(
    site_id = plan$site$site_id,
    method = plan$method,
    rows = length(rows),
    minimum_sample_n = minimum_sample_n,
    maximum_fraction_sum_error = maximum_fraction_error,
    maximum_area_closure_relative_error = maximum_area_closure_error,
    area_closure_relative_error_limit = if (plan$method == "sample") {
      glc_sample_closure_tolerance
    } else {
      glc_exact_boundary_tolerance
    }
  )
}

### Annual consolidation

annual_glc_settings <- function() {
  list(
    label = "Annual GLC",
    output_stem = "glc_fcs30d_safe_combined",
    normalize = glc_normalize_row,
    validate = glc_validate_asset_rows,
    to_data_frame = function(rows) {
      glc_rows_to_data_frame(rows, glc_output_columns)
    },
    row_key = function(row) {
      paste(row$site_id, row$Year, row$LC_ID, sep = ":")
    },
    expected_rows = function(site_count) {
      site_count * length(glc_years) * length(glc_classes)
    },
    order_by = c("site_id", "Year", "LC_ID")
  )
}

annual_glc_main <- function() {
  args <- glc_parse_args(commandArgs(trailingOnly = TRUE))
  run_glc_consolidation(annual_glc_settings(), args)
}

if (sys.nframe() == 0L) {
  tryCatch(
    annual_glc_main(),
    error = function(error) {
      message("Annual GLC consolidation failed: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
