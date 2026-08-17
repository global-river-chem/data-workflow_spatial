### Setup

modis_script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(file_arg)) {
    return(normalizePath(sub("^--file=", "", file_arg[[1]])))
  }
  normalizePath(
    "workflow/gee/modis/consolidate_modis_parity_exports.R",
    mustWork = FALSE
  )
}

repo_root <- normalizePath(file.path(dirname(modis_script_path()), "../../.."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

modis_years <- 2001:2025
greenup_years <- 2001:2024
snow_annual_years <- 2002:2025
modis_doys <- seq(1L, 361L, by = 8L)
snow_doys_for_year <- function(year) {
  missing_doys <- switch(
    as.character(year),
    "2001" = c(169L, 177L),
    "2016" = 49L,
    "2022" = 289L,
    integer()
  )
  setdiff(modis_doys, missing_doys)
}
month_labels <- c(
  "jan", "feb", "mar", "apr", "may", "jun",
  "jul", "aug", "sep", "oct", "nov", "dec"
)
metadata_columns <- c(
  "LTER", "Shapefile_Name", "Discharge_File_Name", "Stream_Name"
)
snow_summary_method <- "legacy_mod10a2_full_composite_equivalent_v1"
snow_summary_note <- paste(
  "Monthly snow values preserve all eight bits of each MOD10A2 composite,",
  "including the final composite when its bit dates extend beyond the",
  "calendar-year boundary; they are composite-equivalent, not strict",
  "calendar-day summaries"
)
snow_calendar_rebuild_reason <- paste(
  "The complete raw final-composite rasters for the 1,040 baseline rows are",
  "not retained locally, and the aggregated columns cannot separate",
  "calendar-year days from spillover bits"
)

### Raw row checks

bind_rows_base <- function(rows) {
  columns <- unique(unlist(lapply(rows, names), use.names = FALSE))
  normalized <- lapply(rows, function(row) {
    missing <- setdiff(columns, names(row))
    row[missing] <- NA
    row[columns]
  })
  out <- do.call(rbind, normalized)
  rownames(out) <- NULL
  out
}

properties_to_row <- function(properties, asset_id) {
  row <- as.data.frame(
    lapply(properties, function(value) {
      if (is.null(value) || !length(value)) NA else value[[1]]
    }),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  row$asset_id <- asset_id
  row
}

expected_asset_ids <- function(asset_folder, run_label, payload_names) {
  descriptions <- as.vector(outer(
    as.vector(outer(
      paste0("modis4_", run_label, "_", payload_names),
      modis_years,
      paste,
      sep = "_"
    )),
    c("h1", "h2"),
    paste,
    sep = "_"
  ))
  file.path(sub("/$", "", asset_folder), descriptions)
}

validate_raw_rows <- function(raw, expected_site_ids) {
  require_columns(
    raw,
    c(
      "site_id", metadata_columns, "year", "half", "asset_id",
      "analysis_scale_m", "extraction_method", "spatial_pixel_cap",
      "extraction_version", "requested_value_count", "polygon_value_count",
      "interior_fallback_value_count", "missing_value_count",
      "value_coverage_fraction", "interior_fallback_used"
    ),
    "MODIS Earth Engine rows"
  )
  raw$site_id <- trimws(as.character(raw$site_id))
  raw$year <- suppressWarnings(as.integer(raw$year))
  raw$half <- trimws(as.character(raw$half))
  key <- paste(raw$site_id, raw$year, raw$half, sep = "::")
  if (any(!nzchar(raw$site_id)) || anyDuplicated(key)) {
    stop("MODIS Earth Engine rows have blank IDs or duplicate task rows")
  }
  expected_key <- expand.grid(
    site_id = expected_site_ids,
    year = modis_years,
    half = c("h1", "h2"),
    stringsAsFactors = FALSE
  )
  expected_key <- paste(
    expected_key$site_id,
    expected_key$year,
    expected_key$half,
    sep = "::"
  )
  missing <- setdiff(expected_key, key)
  unexpected <- setdiff(key, expected_key)
  if (length(missing) || length(unexpected)) {
    stop(
      "Incomplete MODIS task rows. Missing: ", length(missing),
      "; unexpected: ", length(unexpected)
    )
  }
  raw$analysis_scale_m <- suppressWarnings(as.numeric(raw$analysis_scale_m))
  raw$spatial_pixel_cap <- suppressWarnings(as.integer(raw$spatial_pixel_cap))
  count_columns <- c(
    "requested_value_count", "polygon_value_count",
    "interior_fallback_value_count", "missing_value_count"
  )
  raw[count_columns] <- lapply(raw[count_columns], function(value) {
    suppressWarnings(as.integer(value))
  })
  raw$value_coverage_fraction <- suppressWarnings(as.numeric(
    raw$value_coverage_fraction
  ))
  fallback_used_text <- tolower(trimws(as.character(
    raw$interior_fallback_used
  )))
  raw$interior_fallback_used <- fallback_used_text %in% c("true", "1")
  allowed_methods <- c(
    "fractional_polygon_mean_native_500m_interior_fallback_v3",
    "fractional_polygon_mean_bounded_scale_interior_fallback_v3"
  )
  if (
    any(!is.finite(raw$analysis_scale_m) | raw$analysis_scale_m < 500) ||
      any(raw$spatial_pixel_cap != 10000L) ||
      any(!raw$extraction_method %in% allowed_methods) ||
      any(raw$extraction_version != "modis_release3_field_time_bounded_scale_v3") ||
      any(!fallback_used_text %in% c("true", "false", "1", "0")) ||
      any(!is.finite(as.matrix(raw[count_columns]))) ||
      any(as.matrix(raw[count_columns]) < 0) ||
      any(raw$requested_value_count == 0L) ||
      any(
        raw$polygon_value_count + raw$interior_fallback_value_count +
          raw$missing_value_count != raw$requested_value_count
      ) ||
      any(raw$interior_fallback_used !=
        (raw$interior_fallback_value_count > 0L)) ||
      any(!is.finite(raw$value_coverage_fraction)) ||
      any(abs(
        raw$value_coverage_fraction -
          (raw$polygon_value_count + raw$interior_fallback_value_count) /
            raw$requested_value_count
      ) > 1e-10)
  ) {
    stop("MODIS rows contain an invalid spatial extraction setting")
  }
  site_settings <- split(raw, raw$site_id)
  inconsistent <- vapply(site_settings, function(site) {
    length(unique(site$analysis_scale_m)) != 1L ||
      length(unique(site$extraction_method)) != 1L
  }, logical(1))
  if (any(inconsistent)) {
    stop("MODIS spatial extraction settings change within a site")
  }
  raw
}


### Released field treatment

one_numeric_value <- function(data, column, required = TRUE) {
  if (!column %in% names(data)) {
    if (required) stop("Missing extracted property: ", column)
    return(NA_real_)
  }
  values <- suppressWarnings(as.numeric(data[[column]]))
  values <- values[is.finite(values)]
  if (!length(values)) {
    if (required) stop("No extracted value for property: ", column)
    return(NA_real_)
  }
  if (length(unique(values)) > 1L) {
    stop("Conflicting extracted values for property: ", column)
  }
  values[[1]]
}

site_metadata <- function(raw) {
  sites <- split(raw, raw$site_id)
  rows <- lapply(sites, function(site) {
    values <- lapply(metadata_columns, function(column) {
      found <- unique(as.character(site[[column]]))
      found <- found[!is.na(found) & nzchar(trimws(found))]
      if (!length(found) && column == "Discharge_File_Name") {
        return(NA_character_)
      }
      if (length(found) != 1L) {
        stop("Inconsistent metadata for site ", site$site_id[[1]], ": ", column)
      }
      found[[1]]
    })
    names(values) <- metadata_columns
    as.data.frame(values, stringsAsFactors = FALSE, check.names = FALSE)
  })
  out <- bind_rows_base(rows)
  out$site_id <- names(sites)
  out[, c("site_id", metadata_columns), drop = FALSE]
}

et_site_values <- function(site) {
  annual <- setNames(numeric(length(modis_years)), modis_years)
  monthly_by_year <- matrix(
    NA_real_,
    nrow = length(modis_years),
    ncol = 12L,
    dimnames = list(modis_years, month_labels)
  )
  for (year in modis_years) {
    year_rows <- site[site$year == year, , drop = FALSE]
    values <- vapply(modis_doys, function(doy) {
      one_numeric_value(
        year_rows,
        sprintf("et_%d_%03d", year, doy),
        required = FALSE
      )
    }, numeric(1))
    annual[[as.character(year)]] <- sum(values)

    daily_values <- numeric()
    daily_dates <- as.Date(character())
    for (index in seq_along(modis_doys)) {
      doy <- modis_doys[[index]]
      days <- if (doy == 361L) 5L else 8L
      daily_values <- c(daily_values, rep(values[[index]] / days, days))
      daily_dates <- c(
        daily_dates,
        as.Date(sprintf("%d-01-01", year)) + doy - 1L + seq_len(days) - 1L
      )
    }
    months <- as.integer(format(daily_dates, "%m"))
    monthly_by_year[as.character(year), ] <- vapply(seq_len(12L), function(month) {
      sum(daily_values[months == month])
    }, numeric(1))
  }
  c(
    setNames(annual, paste0("evapotrans_", modis_years, "_kg_m2")),
    setNames(
      colMeans(monthly_by_year),
      paste0("evapotrans_", month_labels, "_kg_m2")
    )
  )
}

npp_site_values <- function(site) {
  values <- vapply(modis_years, function(year) {
    one_numeric_value(
      site[site$year == year, , drop = FALSE],
      paste0("npp_", year),
      required = FALSE
    )
  }, numeric(1))
  setNames(values, paste0("npp_", modis_years, "_kgC_m2_year"))
}

greenup_site_values <- function(site) {
  output <- list()
  for (year in greenup_years) {
    year_rows <- site[site$year == year, , drop = FALSE]
    for (cycle in 0:1) {
      value <- one_numeric_value(
        year_rows,
        paste0("greenup", cycle, "_", year),
        required = FALSE
      )
      column <- paste0("greenup_cycle", cycle, "_", year, "MMDD")
      output[[column]] <- if (is.finite(value)) {
        format(as.Date(floor(value), origin = "1970-01-01"), "%Y-%m-%d")
      } else {
        NA_character_
      }
    }
  }
  unlist(output, use.names = TRUE)
}

snow_site_values <- function(site) {
  annual_days <- setNames(numeric(length(snow_annual_years)), snow_annual_years)
  annual_max <- setNames(numeric(length(snow_annual_years)), snow_annual_years)
  monthly_days <- matrix(
    NA_real_,
    nrow = length(modis_years),
    ncol = 12L,
    dimnames = list(modis_years, month_labels)
  )
  monthly_area <- monthly_days

  for (year in modis_years) {
    year_rows <- site[site$year == year, , drop = FALSE]
    daily_values <- numeric()
    daily_dates <- as.Date(character())
    snow_doys <- snow_doys_for_year(year)
    composite_means <- numeric(length(snow_doys))
    for (index in seq_along(snow_doys)) {
      doy <- snow_doys[[index]]
      values <- vapply(seq_len(8L), function(day_index) {
        one_numeric_value(
          year_rows,
          sprintf("snow_%d_%03d_d%d", year, doy, day_index),
          required = FALSE
        )
      }, numeric(1))
      daily_values <- c(daily_values, values)
      daily_dates <- c(
        daily_dates,
        as.Date(sprintf("%d-01-01", year)) + doy - 1L + seq_len(8L) - 1L
      )
      composite_means[[index]] <- mean(values)
    }
    if (year %in% snow_annual_years) {
      annual_days[[as.character(year)]] <- sum(daily_values)
      annual_max[[as.character(year)]] <- max(composite_means)
    }
    months <- as.integer(format(daily_dates, "%m"))
    for (month in seq_len(12L)) {
      keep <- months == month
      monthly_days[as.character(year), month] <- sum(daily_values[keep] > 0)
      monthly_area[as.character(year), month] <- mean(daily_values[keep])
    }
  }

  monthly <- unlist(lapply(seq_len(12L), function(month) {
    setNames(
      c(
        mean(monthly_area[, month]),
        mean(monthly_days[, month])
      ),
      c(
        paste0("snow_", month_labels[[month]], "_avg_prop_area"),
        paste0("snow_", month_labels[[month]], "_num_days")
      )
    )
  }))
  c(
    setNames(
      annual_days,
      paste0("snow_", snow_annual_years, "_num_days")
    ),
    setNames(
      annual_max,
      paste0("snow_", snow_annual_years, "_max_prop_area")
    ),
    monthly
  )
}

values_to_frame <- function(metadata, values_by_site) {
  value_rows <- lapply(values_by_site, function(values) {
    as.data.frame(as.list(values), stringsAsFactors = FALSE, check.names = FALSE)
  })
  values <- bind_rows_base(value_rows)
  values$site_id <- names(values_by_site)
  out <- merge(metadata, values, by = "site_id", sort = FALSE)
  out <- out[match(metadata$site_id, out$site_id), , drop = FALSE]
  out$site_id <- NULL
  rownames(out) <- NULL
  out
}

build_output_tables <- function(raw, expected_site_ids) {
  raw <- validate_raw_rows(raw, expected_site_ids)
  metadata <- site_metadata(raw)
  metadata <- metadata[match(expected_site_ids, metadata$site_id), , drop = FALSE]
  sites <- split(raw, raw$site_id)
  list(
    evapo = values_to_frame(metadata, lapply(sites, et_site_values)),
    greenup = values_to_frame(metadata, lapply(sites, greenup_site_values)),
    npp = values_to_frame(metadata, lapply(sites, npp_site_values)),
    snow = values_to_frame(metadata, lapply(sites, snow_site_values))
  )
}


### Output QA

numeric_columns <- function(data) {
  setdiff(names(data), metadata_columns)
}

check_output_tables <- function(outputs, expected_sites, expected_assets) {
  expected_counts <- c(evapo = 37L, greenup = 48L, npp = 25L, snow = 72L)
  actual_counts <- vapply(outputs, function(data) {
    length(numeric_columns(data))
  }, integer(1))
  if (!identical(actual_counts[names(expected_counts)], expected_counts)) {
    stop("MODIS output field counts do not match the released schema")
  }
  if (any(vapply(outputs, nrow, integer(1)) != expected_sites)) {
    stop("One or more MODIS outputs have the wrong site count")
  }

  evapo <- unlist(outputs$evapo[numeric_columns(outputs$evapo)], use.names = FALSE)
  npp <- unlist(outputs$npp[numeric_columns(outputs$npp)], use.names = FALSE)
  snow <- outputs$snow
  snow_prop <- unlist(
    snow[grep("(max_prop_area|avg_prop_area)$", names(snow), value = TRUE)],
    use.names = FALSE
  )
  snow_days <- unlist(
    snow[grep("_num_days$", names(snow), value = TRUE)],
    use.names = FALSE
  )
  invalid_evapo <- !is.na(evapo) & !is.finite(evapo)
  invalid_npp <- !is.na(npp) & !is.finite(npp)
  if (any(invalid_evapo) || any(invalid_npp)) {
    stop("ET or NPP contains a non-finite value")
  }
  finite_npp <- npp[is.finite(npp)]
  if (!length(finite_npp)) {
    stop("NPP contains no extracted values")
  }
  if (any(finite_npp < -3 - 1e-8 | finite_npp > 3.27 + 1e-8)) {
    stop("NPP exceeds the MOD17A3HGF physical range")
  }
  for (column in numeric_columns(outputs$greenup)) {
    year <- as.integer(sub("^greenup_cycle[01]_([0-9]{4})MMDD$", "\\1", column))
    values <- as.Date(outputs$greenup[[column]])
    present <- !is.na(values)
    if (any(
      values[present] < as.Date(sprintf("%d-01-01", year - 1L)) |
        values[present] > as.Date(sprintf("%d-12-31", year + 1L))
    )) {
      stop("Greenup date is outside the product-year window: ", column)
    }
  }
  invalid_snow_prop <- !is.na(snow_prop) & !is.finite(snow_prop)
  invalid_snow_days <- !is.na(snow_days) & !is.finite(snow_days)
  finite_snow_prop <- snow_prop[is.finite(snow_prop)]
  finite_snow_days <- snow_days[is.finite(snow_days)]
  if (
    any(invalid_snow_prop) || any(invalid_snow_days) ||
      !length(finite_snow_prop) || !length(finite_snow_days) ||
      any(finite_snow_prop < 0 | finite_snow_prop > 1) ||
      any(finite_snow_days < 0 | finite_snow_days > 368)
  ) {
    stop("Snow summaries fail their physical range checks")
  }
  value_present <- lapply(outputs, function(data) {
    values <- data[numeric_columns(data)]
    as.data.frame(lapply(values, function(value) {
      !is.na(value) & nzchar(trimws(as.character(value)))
    }), check.names = FALSE)
  })
  list(
    generated_at = Sys.time(),
    expected_sites = expected_sites,
    expected_assets = expected_assets,
    snow_summary_method = snow_summary_method,
    snow_summary_note = snow_summary_note,
    legacy_calendar_day_rebuild_locally_reproducible = FALSE,
    legacy_calendar_day_rebuild_reason = snow_calendar_rebuild_reason,
    output_rows = vapply(outputs, nrow, integer(1)),
    output_value_columns = actual_counts,
    missing_value_counts = vapply(value_present, function(present) {
      sum(!as.matrix(present))
    }, integer(1)),
    all_missing_site_counts = vapply(value_present, function(present) {
      sum(rowSums(present) == 0L)
    }, integer(1)),
    partial_missing_site_counts = vapply(value_present, function(present) {
      count <- rowSums(present)
      sum(count > 0L & count < ncol(present))
    }, integer(1)),
    checks = c(
      complete_task_grid = TRUE,
      released_field_counts = TRUE,
      et_present_values_finite = TRUE,
      greenup_dates_plausible = TRUE,
      npp_present_values_in_physical_range = TRUE,
      snow_present_values_in_physical_range = TRUE,
      snow_full_composite_parity_preserved = TRUE,
      missing_coverage_retained_as_missing = TRUE
    )
  )
}


### Local self-test

synthetic_raw_rows <- function() {
  rows <- list()
  row_index <- 0L
  origin <- as.Date("1970-01-01")
  for (year in modis_years) {
    for (half in c("h1", "h2")) {
      row_index <- row_index + 1L
      row <- data.frame(
        site_id = "test_site",
        LTER = "TEST",
        Shapefile_Name = "test_shape",
        Discharge_File_Name = "",
        Stream_Name = "Test Stream",
        year = year,
        half = half,
        asset_id = paste(year, half),
        analysis_scale_m = 500,
        extraction_method = paste0(
          "fractional_polygon_mean_native_500m_",
          "interior_fallback_v3"
        ),
        spatial_pixel_cap = 10000L,
        extraction_version = "modis_release3_field_time_bounded_scale_v3",
        stringsAsFactors = FALSE,
        check.names = FALSE
      )
      doys <- if (half == "h1") modis_doys[1:23] else modis_doys[24:46]
      for (doy in doys) {
        row[[sprintf("et_%d_%03d", year, doy)]] <- if (doy == 361L) 5 else 8
        if (doy %in% snow_doys_for_year(year)) {
          for (day_index in seq_len(8L)) {
            row[[sprintf("snow_%d_%03d_d%d", year, doy, day_index)]] <-
              as.numeric(day_index == 1L)
          }
        }
      }
      if (half == "h1") {
        row[[paste0("npp_", year)]] <- 0.5
        if (year <= 2024) {
          date_value <- as.numeric(as.Date(sprintf("%d-04-01", year)) - origin)
          row[[paste0("greenup0_", year)]] <- date_value
          row[[paste0("greenup1_", year)]] <- NA_real_
        }
      }
      value_columns <- grep(
        "^(et|snow|npp|greenup)",
        names(row),
        value = TRUE
      )
      row$requested_value_count <- length(value_columns)
      row$polygon_value_count <- length(value_columns)
      row$interior_fallback_value_count <- 0L
      row$missing_value_count <- 0L
      row$value_coverage_fraction <- 1
      row$interior_fallback_used <- FALSE
      rows[[row_index]] <- row
    }
  }
  bind_rows_base(rows)
}

run_self_test <- function() {
  raw <- synthetic_raw_rows()
  source_year_row <- raw$year == 2002L & raw$half == "h2"
  raw$snow_2002_361_d8[source_year_row] <- 1
  outputs <- build_output_tables(raw, "test_site")
  stopifnot(nrow(outputs$evapo) == 1L)
  stopifnot(ncol(outputs$evapo) == length(metadata_columns) + 37L)
  stopifnot(ncol(outputs$greenup) == length(metadata_columns) + 48L)
  stopifnot(ncol(outputs$npp) == length(metadata_columns) + 25L)
  stopifnot(ncol(outputs$snow) == length(metadata_columns) + 72L)
  stopifnot(is.na(outputs$evapo$Discharge_File_Name[[1]]))
  stopifnot(outputs$evapo$evapotrans_2002_kg_m2[[1]] == 365)
  stopifnot(outputs$snow$snow_2002_num_days[[1]] == 47)
  stopifnot(!"snow_2001_num_days" %in% names(outputs$snow))
  qa <- check_output_tables(outputs, 1L, 100L)
  stopifnot(qa$snow_summary_method == snow_summary_method)
  stopifnot(grepl("not strict calendar-day", qa$snow_summary_note, fixed = TRUE))
  stopifnot(!qa$legacy_calendar_day_rebuild_locally_reproducible)

  missing_raw <- raw
  first_half <- missing_raw$year == 2001L & missing_raw$half == "h1"
  missing_raw$et_2001_001[first_half] <- NA_real_
  missing_raw$npp_2001[first_half] <- NA_real_
  missing_raw$snow_2001_001_d1[first_half] <- NA_real_
  missing_raw$polygon_value_count[first_half] <-
    missing_raw$polygon_value_count[first_half] - 3L
  missing_raw$missing_value_count[first_half] <- 3L
  missing_raw$value_coverage_fraction[first_half] <-
    missing_raw$polygon_value_count[first_half] /
      missing_raw$requested_value_count[first_half]
  missing_outputs <- build_output_tables(missing_raw, "test_site")
  missing_qa <- check_output_tables(missing_outputs, 1L, 100L)
  stopifnot(is.na(missing_outputs$evapo$evapotrans_2001_kg_m2[[1]]))
  stopifnot(is.na(missing_outputs$npp$npp_2001_kgC_m2_year[[1]]))
  stopifnot(is.na(missing_outputs$snow$snow_jan_avg_prop_area[[1]]))
  stopifnot(all(missing_qa$missing_value_counts[c("evapo", "npp", "snow")] > 0L))
  message("MODIS parity consolidation self-test passed")
}


### Command line

consolidate_modis_main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if ("--self-test" %in% args) {
    run_self_test()
    return(invisible(TRUE))
  }

  payload_positions <- which(args == "--payload-list")
  if (!length(payload_positions) || any(payload_positions == length(args))) {
    stop("At least one --payload-list is required")
  }
  payload_list_paths <- args[payload_positions + 1L]
  asset_folder <- cli_value(args, "--asset-folder", required = TRUE)
  run_label <- cli_value(args, "--run-label", required = TRUE)
  output_root <- cli_value(args, "--output-root", required = TRUE)
  output_tag <- cli_value(args, "--output-tag", "gee_20260815_boundary_fix")
  expected_site_count <- cli_integer(
    args,
    "--expected-site-count",
    151L,
    minimum = 1L
  )
  payload_count <- cli_integer(args, "--payload-count", 2L, minimum = 1L)
  project <- cli_value(
    args,
    "--project",
    Sys.getenv("SILICA_GEE_PROJECT", "silica-synthesis")
  )
  if (!grepl("^[a-z0-9][a-z0-9_]*$", run_label)) {
    stop("--run-label may contain lowercase letters, numbers, and _")
  }

  payload_lists <- lapply(payload_list_paths, function(payload_list_path) {
    data <- read.csv(
      require_input_file(payload_list_path, "payload list"),
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
    require_columns(data, c("payload", "path", "sites"), "payload list")
    data$payload_root <- dirname(normalizePath(payload_list_path))
    data$payload_file <- vapply(data$path, function(path) {
      normalizePath(if (grepl("^/", path)) {
        path
      } else {
        file.path(data$payload_root[[1L]], path)
      })
    }, character(1L))
    data
  })
  payload_list <- bind_rows_base(payload_lists)
  if (sum(as.integer(payload_list$sites)) != expected_site_count) {
    stop("Payload lists do not contain the expected site count")
  }
  site_ids <- unlist(lapply(seq_len(nrow(payload_list)), function(index) {
    full_path <- payload_list$payload_file[[index]]
    data <- jsonlite::fromJSON(full_path, simplifyVector = FALSE)
    vapply(data$features, function(feature) {
      as.character(feature$properties$site_id)
    }, character(1))
  }), use.names = FALSE)
  if (length(site_ids) != expected_site_count || anyDuplicated(site_ids)) {
    stop("Payload GeoJSON files do not contain the expected distinct site IDs")
  }
  input_paths <- unique(c(
    normalizePath(payload_list_paths),
    payload_list$payload_file
  ))
  input_file_records <- file_records(input_paths, basename(input_paths))

  source(file.path(repo_root, "workflow", "gee", "gee_api.R"))
  token <- gee_access_token()
  expected_ids <- expected_asset_ids(
    asset_folder,
    run_label,
    sprintf("modis_%02d", seq_len(payload_count))
  )
  assets <- gee_list_assets(asset_folder, project, token)
  available_ids <- vapply(assets, function(asset) {
    as.character(asset$name %||% "")
  }, character(1))
  missing_assets <- setdiff(expected_ids, available_ids)
  if (length(missing_assets)) {
    stop(
      "MODIS assets are incomplete: ", length(missing_assets),
      " of ", length(expected_ids), " are missing"
    )
  }

  rows <- list()
  for (asset_id in expected_ids) {
    features <- gee_compute_features(asset_id, project, token)
    asset_rows <- lapply(features, function(feature) {
      properties_to_row(feature$properties %||% list(), asset_id)
    })
    rows <- c(rows, asset_rows)
  }
  raw <- bind_rows_base(rows)
  raw <- validate_raw_rows(raw, site_ids)
  outputs <- build_output_tables(raw, site_ids)
  qa <- check_output_tables(
    outputs,
    expected_site_count,
    length(expected_ids)
  )
  site_settings <- unique(raw[c(
    "site_id", "analysis_scale_m", "extraction_method", "spatial_pixel_cap"
  )])
  site_coverage <- aggregate(
    raw[c(
      "requested_value_count", "polygon_value_count",
      "interior_fallback_value_count", "missing_value_count"
    )],
    list(site_id = raw$site_id),
    sum
  )
  site_settings <- merge(site_settings, site_coverage, by = "site_id", sort = FALSE)
  site_settings <- site_settings[
    match(site_ids, site_settings$site_id),
    ,
    drop = FALSE
  ]
  site_settings$value_coverage_fraction <- (
    site_settings$polygon_value_count +
      site_settings$interior_fallback_value_count
  ) / site_settings$requested_value_count
  site_settings$interior_fallback_fraction <-
    site_settings$interior_fallback_value_count /
      site_settings$requested_value_count
  if (nrow(site_settings) != expected_site_count ||
      anyDuplicated(site_settings$site_id) ||
      any(site_settings$requested_value_count !=
        site_settings$polygon_value_count +
          site_settings$interior_fallback_value_count +
          site_settings$missing_value_count)) {
    stop("MODIS per-site method and coverage QA is incomplete")
  }
  qa$spatial_method_counts <- as.list(table(site_settings$extraction_method))
  qa$analysis_scale_m_range <- range(site_settings$analysis_scale_m)
  qa$spatial_pixel_cap <- unique(site_settings$spatial_pixel_cap)
  qa$extraction_version <- unique(raw$extraction_version)
  qa$spatial_method_by_site <- site_settings
  qa$interior_fallback_site_count <- sum(
    site_settings$interior_fallback_value_count > 0L
  )
  qa$interior_fallback_value_count <- sum(
    site_settings$interior_fallback_value_count
  )
  qa$missing_extracted_value_count <- sum(site_settings$missing_value_count)
  qa$expected_asset_ids <- expected_ids
  input_md5_after <- unname(tools::md5sum(input_file_records$path))
  if (!identical(input_file_records$md5, input_md5_after)) {
    stop("A MODIS payload input changed during consolidation")
  }
  input_file_records$md5_after <- input_md5_after
  input_file_records$unchanged_during_download <- TRUE
  qa$input_files <- input_file_records

  if (file.exists(output_root)) {
    stop("MODIS output directory already exists: ", output_root)
  }
  output_parent <- dirname(output_root)
  dir.create(output_parent, recursive = TRUE, showWarnings = FALSE)
  stage <- tempfile(".modis-parity-", tmpdir = output_parent)
  dir.create(stage)
  on.exit(if (dir.exists(stage)) unlink(stage, recursive = TRUE), add = TRUE)
  file_names <- c(
    evapo = paste0("si-extract_evapo_v061_", output_tag, ".csv"),
    greenup = paste0("si-extract_greenup_v061_", output_tag, ".csv"),
    npp = paste0("si-extract_npp_v061_", output_tag, ".csv"),
    snow = paste0("si-extract_snow_v061_", output_tag, ".csv")
  )
  output_paths <- file.path(stage, file_names)
  for (product in names(outputs)) {
    write.csv(
      outputs[[product]],
      output_paths[[product]],
      row.names = FALSE,
      na = ""
    )
    check <- read.csv(
      output_paths[[product]],
      stringsAsFactors = FALSE,
      check.names = FALSE
    )
    if (!isTRUE(all.equal(
      outputs[[product]],
      check,
      check.attributes = FALSE,
      tolerance = 1e-12
    ))) {
      stop("MODIS output failed read-back QA: ", product)
    }
  }
  qa$output_files <- file_records(output_paths, names(outputs))
  qa$output_files$path <- normalizePath(
    file.path(output_root, file_names),
    mustWork = FALSE
  )
  qa$checks <- c(qa$checks, output_csv_readback_equal = TRUE)
  qa_path <- file.path(
    stage,
    paste0("modis_parity_qa_", output_tag, ".rds")
  )
  saveRDS(qa, qa_path, compress = "xz")
  qa_check <- readRDS(qa_path)
  if (nrow(qa_check$spatial_method_by_site) != expected_site_count ||
      !identical(qa_check$snow_summary_method, snow_summary_method)) {
    stop("MODIS QA record failed read-back QA")
  }
  if (!file.rename(stage, output_root)) {
    stop("Could not install the checked MODIS outputs")
  }
  installed_paths <- file.path(output_root, file_names)
  installed_qa <- file.path(
    output_root,
    paste0("modis_parity_qa_", output_tag, ".rds")
  )
  if (!identical(
    unname(tools::md5sum(installed_paths)),
    qa$output_files$md5
  ) || !is.list(readRDS(installed_qa))) {
    stop("Installed MODIS outputs failed final hash or QA read-back")
  }
  message("Consolidated MODIS sites: ", expected_site_count)
  message("Verified Earth Engine assets: ", length(expected_ids))
}


if (sys.nframe() == 0L) {
  tryCatch(
    consolidate_modis_main(),
    error = function(error) {
      message("MODIS consolidation failed: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
