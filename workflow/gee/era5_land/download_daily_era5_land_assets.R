# download and check daily era5-land watershed assets one year at a time

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path("workflow", "gee", "era5_land", "download_daily_era5_land_assets.R")
}, mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
source(file.path(repo_root, "workflow", "gee", "gee_api.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- settings ----

base_value_columns <- c(
  "precip_mm",
  "temp_degC",
  "temp_min_degC",
  "temp_max_degC",
  "evapotrans_mm",
  "potential_evap_mm",
  "snow_cover_fraction",
  "snow_water_equiv_mm",
  "runoff_mm",
  "solar_energy_mj_m2",
  "soil_water_layer_1_fraction",
  "soil_water_layer_3_fraction",
  "vapor_pressure_pa"
)
statistic_suffixes <- c(
  mean = "spatial_mean",
  median = "spatial_median",
  min = "spatial_min",
  max = "spatial_max",
  sd = "spatial_sd"
)
derived_value_columns <- c(
  "relative_humidity_percent_from_spatial_means",
  "vapor_pressure_deficit_kpa_from_spatial_means"
)

# ---- helpers ----

parse_years <- function(value) {
  value <- trimws(value)
  if (grepl(":", value, fixed = TRUE)) {
    bounds <- as.integer(strsplit(value, ":", fixed = TRUE)[[1]])
    if (length(bounds) != 2L || any(is.na(bounds)) || bounds[[1]] > bounds[[2]]) {
      stop("Invalid year range.", call. = FALSE)
    }
    return(seq(bounds[[1]], bounds[[2]]))
  }
  years <- as.integer(strsplit(value, ",", fixed = TRUE)[[1]])
  if (any(is.na(years))) stop("Invalid year list.", call. = FALSE)
  sort(unique(years))
}

parse_months <- function(value) {
  months <- parse_years(value)
  if (any(months < 1L | months > 12L)) {
    stop("Months must stay between 1 and 12.", call. = FALSE)
  }
  months
}

parse_spatial_statistics <- function(value) {
  if (is.null(value)) return(character())
  statistics <- trimws(strsplit(value, ",", fixed = TRUE)[[1]])
  if (!length(statistics) || any(!nzchar(statistics))) {
    stop("At least one spatial statistic is required.", call. = FALSE)
  }
  unknown <- setdiff(statistics, names(statistic_suffixes))
  if (length(unknown)) {
    stop("Unknown spatial statistics: ", paste(unknown, collapse = ", "), call. = FALSE)
  }
  if (anyDuplicated(statistics)) {
    stop("Each spatial statistic may be listed only once.", call. = FALSE)
  }
  if (!"mean" %in% statistics) {
    stop("Spatial statistics must include mean.", call. = FALSE)
  }
  statistics
}

daily_value_columns <- function(spatial_statistics = character()) {
  if (!length(spatial_statistics)) return(base_value_columns)
  unlist(lapply(base_value_columns, function(column) {
    paste(column, statistic_suffixes[spatial_statistics], sep = "_")
  }), use.names = FALSE)
}

saturation_vapor_pressure_pa <- function(temp_degC) {
  611.2 * exp(17.67 * temp_degC / (temp_degC + 243.5))
}

mean_input_column <- function(base, spatial_statistics = character()) {
  if (length(spatial_statistics)) {
    return(paste(base, statistic_suffixes[["mean"]], sep = "_"))
  }
  base
}

add_humidity_drivers <- function(data, spatial_statistics = character()) {
  temp_min_column <- mean_input_column("temp_min_degC", spatial_statistics)
  temp_max_column <- mean_input_column("temp_max_degC", spatial_statistics)
  vapor_pressure_column <- mean_input_column(
    "vapor_pressure_pa",
    spatial_statistics
  )

  # average the saturation pressures at the daily minimum and maximum temperatures
  saturation_pressure_pa <- (
    saturation_vapor_pressure_pa(data[[temp_min_column]]) +
      saturation_vapor_pressure_pa(data[[temp_max_column]])
  ) / 2
  actual_pressure_pa <- data[[vapor_pressure_column]]

  data[, relative_humidity_percent_from_spatial_means := pmin(
    100,
    pmax(0, 100 * actual_pressure_pa / saturation_pressure_pa)
  )]
  data[, vapor_pressure_deficit_kpa_from_spatial_means := pmax(
    0,
    (saturation_pressure_pa - actual_pressure_pa) / 1000
  )]

  if (any(!is.finite(data[[derived_value_columns[[1]]]])) ||
      any(data[[derived_value_columns[[1]]]] < 0) ||
      any(data[[derived_value_columns[[1]]]] > 100) ||
      any(!is.finite(data[[derived_value_columns[[2]]]])) ||
      any(data[[derived_value_columns[[2]]]] < 0)) {
    stop("Daily ERA5-Land humidity estimates are invalid.", call. = FALSE)
  }
  data
}

feature_rows <- function(features, asset_id) {
  rows <- lapply(features, function(feature) {
    properties <- feature$properties %||% list()
    properties$source_asset <- asset_id
    as.data.frame(properties, stringsAsFactors = FALSE, optional = TRUE)
  })
  rbindlist(rows, fill = TRUE)
}

expected_dates <- function(year, months = 1:12) {
  dates <- lapply(months, function(month) {
    start <- as.IDate(sprintf("%d-%02d-01", year, month))
    next_month <- if (month == 12L) {
      as.IDate(sprintf("%d-01-01", year + 1L))
    } else {
      as.IDate(sprintf("%d-%02d-01", year, month + 1L))
    }
    seq(start, next_month - 1L, by = "day")
  })
  do.call(c, dates)
}

validate_geometry_rows <- function(
  data,
  expected_sites,
  year,
  months = 1:12,
  spatial_statistics = character()
) {
  value_columns <- daily_value_columns(spatial_statistics)
  qa_columns <- if (length(spatial_statistics)) {
    c("watershed_area_km2", "native_pixel_count", "reduction_scale_m")
  } else {
    character()
  }
  required <- c(
    "site_id", "date", "year", "month", "day", "day_of_year",
    value_columns, qa_columns, "used_fine_scale_fallback", "source_image_count"
  )
  assert_required_columns(data, required, "daily ERA5-Land output")

  data[, site_id := trimws(as.character(site_id))]
  data[, date := as.IDate(date)]
  data[, year := as.integer(year)]
  data[, month := as.integer(month)]
  data[, day := as.integer(day)]
  data[, day_of_year := as.integer(day_of_year)]
  data[, used_fine_scale_fallback := as.integer(used_fine_scale_fallback)]
  data[, source_image_count := as.integer(source_image_count)]
  if (length(spatial_statistics)) {
    data[, watershed_area_km2 := as.numeric(watershed_area_km2)]
    data[, native_pixel_count := as.numeric(native_pixel_count)]
    data[, reduction_scale_m := as.numeric(reduction_scale_m)]
  }

  if (any(!nzchar(data$site_id)) || any(is.na(data$date))) {
    stop("Daily ERA5-Land output contains a blank site ID or date.", call. = FALSE)
  }
  if (any(data$year != year)) {
    stop("Daily ERA5-Land output contains rows from the wrong year.", call. = FALSE)
  }

  for (column in value_columns) {
    set(data, j = column, value = suppressWarnings(as.numeric(data[[column]])))
    if (any(!is.finite(data[[column]]))) {
      stop("Daily ERA5-Land output has a missing value in ", column, ".", call. = FALSE)
    }
  }

  nonnegative_bases <- c(
    "precip_mm", "snow_water_equiv_mm", "runoff_mm", "solar_energy_mj_m2"
  )
  physical_columns <- function(bases) {
    if (!length(spatial_statistics)) return(bases)
    unlist(lapply(bases, function(column) {
      paste(column, statistic_suffixes[spatial_statistics], sep = "_")
    }), use.names = FALSE)
  }
  nonnegative <- physical_columns(nonnegative_bases)
  if (any(vapply(nonnegative, function(column) {
    any(data[[column]] < -1e-8)
  }, logical(1)))) {
    stop("Daily ERA5-Land output has a negative physical value.", call. = FALSE)
  }
  fraction_bases <- c(
    "snow_cover_fraction",
    "soil_water_layer_1_fraction",
    "soil_water_layer_3_fraction"
  )
  fraction_columns <- physical_columns(fraction_bases)
  if (any(vapply(fraction_columns, function(column) {
    any(data[[column]] < -1e-8 | data[[column]] > 1 + 1e-8)
  }, logical(1)))) {
    stop("Daily ERA5-Land output has a fraction outside 0 to 1.", call. = FALSE)
  }
  vapor_columns <- if (length(spatial_statistics)) {
    value_statistics <- setdiff(spatial_statistics, "sd")
    paste("vapor_pressure_pa", statistic_suffixes[value_statistics], sep = "_")
  } else {
    "vapor_pressure_pa"
  }
  if (any(vapply(vapor_columns, function(column) {
    any(data[[column]] <= 0)
  }, logical(1)))) {
    stop("Daily ERA5-Land vapor pressure must be positive.", call. = FALSE)
  }
  if (length(spatial_statistics)) {
    sd_columns <- paste(
      base_value_columns,
      statistic_suffixes[["sd"]],
      sep = "_"
    )
    if ("sd" %in% spatial_statistics && any(vapply(sd_columns, function(column) {
      any(data[[column]] < -1e-8)
    }, logical(1)))) {
      stop("Daily ERA5-Land spatial standard deviation is negative.", call. = FALSE)
    }
    if (all(c("min", "median", "max") %in% spatial_statistics)) {
      for (base in base_value_columns) {
        minimum <- data[[paste(base, statistic_suffixes[["min"]], sep = "_")]]
        median <- data[[paste(base, statistic_suffixes[["median"]], sep = "_")]]
        maximum <- data[[paste(base, statistic_suffixes[["max"]], sep = "_")]]
        if (any(minimum > median + 1e-8) || any(median > maximum + 1e-8)) {
          stop("Daily ERA5-Land spatial statistics are out of order.", call. = FALSE)
        }
      }
    }
    if (all(c("min", "mean", "max") %in% spatial_statistics)) {
      for (base in base_value_columns) {
        minimum <- data[[paste(base, statistic_suffixes[["min"]], sep = "_")]]
        mean <- data[[paste(base, statistic_suffixes[["mean"]], sep = "_")]]
        maximum <- data[[paste(base, statistic_suffixes[["max"]], sep = "_")]]
        if (any(minimum > mean + 1e-8) || any(mean > maximum + 1e-8)) {
          stop("Daily ERA5-Land spatial mean falls outside its range.", call. = FALSE)
        }
      }
    }
    ordered_statistics <- setdiff(spatial_statistics, "sd")
    if (any(vapply(ordered_statistics, function(statistic) {
      suffix <- statistic_suffixes[[statistic]]
      any(data[[paste("temp_min_degC", suffix, sep = "_")]] >
            data[[paste("temp_degC", suffix, sep = "_")]] + 1e-8) ||
        any(data[[paste("temp_degC", suffix, sep = "_")]] >
              data[[paste("temp_max_degC", suffix, sep = "_")]] + 1e-8)
    }, logical(1)))) {
      stop("Daily ERA5-Land temperatures are out of order.", call. = FALSE)
    }
    if (any(!is.finite(data$watershed_area_km2)) ||
        any(data$watershed_area_km2 <= 0) ||
        any(!is.finite(data$native_pixel_count)) ||
        any(data$native_pixel_count < 0) ||
        any(abs(data$native_pixel_count - round(data$native_pixel_count)) > 1e-8)) {
      stop("Daily ERA5-Land watershed QA values are invalid.", call. = FALSE)
    }
    expected_scale <- ifelse(data$used_fine_scale_fallback == 1L, 1110, 11100)
    if (any(abs(data$reduction_scale_m - expected_scale) > 1e-8) ||
        any(data$used_fine_scale_fallback == 0L & data$native_pixel_count < 1)) {
      stop("Daily ERA5-Land reduction scale does not match its fallback flag.", call. = FALSE)
    }
  } else if (any(data$temp_min_degC > data$temp_degC) ||
             any(data$temp_degC > data$temp_max_degC)) {
    stop("Daily ERA5-Land temperatures are out of order.", call. = FALSE)
  }
  if (any(!data$used_fine_scale_fallback %in% 0:1) ||
      any(data$source_image_count != 1L)) {
    stop("Daily ERA5-Land quality flags are invalid.", call. = FALSE)
  }

  key <- paste(data$site_id, data$date, sep = "\r")
  expected_key <- as.vector(outer(
    expected_sites,
    as.character(expected_dates(year, months)),
    paste,
    sep = "\r"
  ))
  missing <- setdiff(expected_key, key)
  unexpected <- setdiff(key, expected_key)
  if (anyDuplicated(key) || length(missing) || length(unexpected)) {
    stop(
      "Daily ERA5-Land coverage is incomplete: ", length(missing),
      " missing site-days, ", length(unexpected),
      " unexpected site-days, and ", anyDuplicated(key),
      " as the first duplicate position.",
      call. = FALSE
    )
  }
  data
}

expand_site_aliases <- function(data, aliases, spatial_statistics = character()) {
  value_columns <- daily_value_columns(spatial_statistics)
  qa_columns <- if (length(spatial_statistics)) {
    c("watershed_area_km2", "native_pixel_count", "reduction_scale_m")
  } else {
    character()
  }
  source_columns <- intersect(c("LTER", "Stream_Name", "Shapefile_Name"), names(data))
  if (length(source_columns)) {
    setnames(data, source_columns, paste0("geometry_", source_columns))
  }
  expanded <- aliases[data, on = "site_id", allow.cartesian = TRUE]
  if (nrow(expanded) < nrow(data) || any(is.na(expanded$LTER))) {
    stop("A daily ERA5-Land watershed could not be expanded to site rows.", call. = FALSE)
  }
  expanded[, geometry_site_id := site_id]
  expanded[, site_row_id := paste(LTER, Stream_Name, sep = "__")]
  output_columns <- c(
    "site_row_id", "geometry_site_id", "LTER", "Stream_Name",
    "Shapefile_Name", "Spatial_Data_Version", "date", "year", "month",
    "day", "day_of_year", qa_columns, value_columns, derived_value_columns,
    "used_fine_scale_fallback", "source_image_count"
  )
  expanded <- expanded[, ..output_columns]
  setorder(expanded, site_row_id, date)
  expanded
}

run_self_test <- function() {
  year <- 2001L
  sites <- c("ws_1", "ws_2")
  base_sample <- CJ(site_id = sites, date = expected_dates(year))
  base_sample[, year := year]
  base_sample[, month := as.integer(format(date, "%m"))]
  base_sample[, day := as.integer(format(date, "%d"))]
  base_sample[, day_of_year := as.integer(format(date, "%j"))]
  base_sample[, used_fine_scale_fallback := 0L]
  base_sample[, source_image_count := 1L]
  base_sample[, source_asset := "test_asset"]

  mean_sample <- copy(base_sample)
  for (column in base_value_columns) set(mean_sample, j = column, value = 1)
  mean_sample[, temp_min_degC := -1]
  mean_sample[, temp_degC := 0]
  mean_sample[, temp_max_degC := 1]
  mean_sample[, snow_cover_fraction := 0.5]
  mean_sample[, soil_water_layer_1_fraction := 0.4]
  mean_sample[, soil_water_layer_3_fraction := 0.3]
  mean_sample[, vapor_pressure_pa := 611.2]
  mean_checked <- validate_geometry_rows(copy(mean_sample), sites, year)
  mean_checked <- add_humidity_drivers(mean_checked)
  stopifnot(
    all(is.finite(mean_checked$relative_humidity_percent_from_spatial_means)),
    all(mean_checked$relative_humidity_percent_from_spatial_means >= 0),
    all(mean_checked$relative_humidity_percent_from_spatial_means <= 100),
    all(is.finite(mean_checked$vapor_pressure_deficit_kpa_from_spatial_means)),
    all(mean_checked$vapor_pressure_deficit_kpa_from_spatial_means >= 0)
  )
  saturated_sample <- copy(mean_sample[1])
  saturated_sample[, vapor_pressure_pa := 1000]
  saturated_sample <- add_humidity_drivers(saturated_sample)
  stopifnot(
    saturated_sample$relative_humidity_percent_from_spatial_means == 100,
    saturated_sample$vapor_pressure_deficit_kpa_from_spatial_means == 0
  )

  statistics <- names(statistic_suffixes)
  sample <- copy(base_sample)
  for (base in base_value_columns) {
    set(sample, j = paste(base, statistic_suffixes[["min"]], sep = "_"), value = 0)
    set(sample, j = paste(base, statistic_suffixes[["median"]], sep = "_"), value = 1)
    set(sample, j = paste(base, statistic_suffixes[["mean"]], sep = "_"), value = 1)
    set(sample, j = paste(base, statistic_suffixes[["max"]], sep = "_"), value = 2)
    set(sample, j = paste(base, statistic_suffixes[["sd"]], sep = "_"), value = 0.5)
  }
  for (base in c(
    "snow_cover_fraction",
    "soil_water_layer_1_fraction",
    "soil_water_layer_3_fraction"
  )) {
    set(sample, j = paste(base, statistic_suffixes[["min"]], sep = "_"), value = 0.1)
    set(sample, j = paste(base, statistic_suffixes[["median"]], sep = "_"), value = 0.4)
    set(sample, j = paste(base, statistic_suffixes[["mean"]], sep = "_"), value = 0.4)
    set(sample, j = paste(base, statistic_suffixes[["max"]], sep = "_"), value = 0.8)
    set(sample, j = paste(base, statistic_suffixes[["sd"]], sep = "_"), value = 0.2)
  }
  temperature_offsets <- c(temp_min_degC = -2, temp_degC = 0, temp_max_degC = 2)
  for (base in names(temperature_offsets)) {
    offset <- temperature_offsets[[base]]
    set(sample, j = paste(base, statistic_suffixes[["min"]], sep = "_"), value = offset - 2)
    set(sample, j = paste(base, statistic_suffixes[["median"]], sep = "_"), value = offset)
    set(sample, j = paste(base, statistic_suffixes[["mean"]], sep = "_"), value = offset)
    set(sample, j = paste(base, statistic_suffixes[["max"]], sep = "_"), value = offset + 2)
    set(sample, j = paste(base, statistic_suffixes[["sd"]], sep = "_"), value = 1)
  }
  vapor_values <- c(min = 400, median = 600, mean = 620, max = 800, sd = 100)
  for (statistic in names(vapor_values)) {
    set(
      sample,
      j = paste("vapor_pressure_pa", statistic_suffixes[[statistic]], sep = "_"),
      value = vapor_values[[statistic]]
    )
  }
  sample[, watershed_area_km2 := 100]
  sample[, native_pixel_count := 4]
  sample[, reduction_scale_m := 11100]

  checked <- validate_geometry_rows(
    copy(sample),
    sites,
    year,
    spatial_statistics = statistics
  )
  checked <- add_humidity_drivers(checked, statistics)
  expected_saturation_pressure_pa <- (
    saturation_vapor_pressure_pa(10) + saturation_vapor_pressure_pa(20)
  ) / 2
  humidity_sample <- copy(sample[1])
  humidity_sample[, temp_min_degC_spatial_mean := 10]
  humidity_sample[, temp_max_degC_spatial_mean := 20]
  humidity_sample[, vapor_pressure_pa_spatial_mean := 1000]
  humidity_sample <- add_humidity_drivers(humidity_sample, statistics)
  stopifnot(
    isTRUE(all.equal(
      humidity_sample$relative_humidity_percent_from_spatial_means,
      100 * 1000 / expected_saturation_pressure_pa,
      tolerance = 1e-10
    )),
    isTRUE(all.equal(
      humidity_sample$vapor_pressure_deficit_kpa_from_spatial_means,
      (expected_saturation_pressure_pa - 1000) / 1000,
      tolerance = 1e-10
    ))
  )
  aliases <- data.table(
    site_id = c("ws_1", "ws_1", "ws_2"),
    LTER = c("A", "A", "B"),
    Stream_Name = c("one", "two", "three"),
    Shapefile_Name = c("shape_1", "shape_1", "shape_2"),
    Spatial_Data_Version = 3L
  )
  expanded <- expand_site_aliases(checked, aliases, statistics)
  stopifnot(
    nrow(expanded) == length(expected_dates(year)) * nrow(aliases),
    uniqueN(expanded$site_row_id) == nrow(aliases),
    all(derived_value_columns %in% names(expanded))
  )

  failed <- FALSE
  tryCatch(
    validate_geometry_rows(
      sample[-1],
      sites,
      year,
      spatial_statistics = statistics
    ),
    error = function(error) failed <<- TRUE
  )
  stopifnot(failed)

  bad_sd <- copy(sample)
  bad_sd[[paste("precip_mm", statistic_suffixes[["sd"]], sep = "_")]][[1]] <- -1
  failed <- FALSE
  tryCatch(
    validate_geometry_rows(bad_sd, sites, year, spatial_statistics = statistics),
    error = function(error) failed <<- TRUE
  )
  stopifnot(failed)

  bad_scale <- copy(sample)
  bad_scale$reduction_scale_m[[1]] <- 1110
  failed <- FALSE
  tryCatch(
    validate_geometry_rows(bad_scale, sites, year, spatial_statistics = statistics),
    error = function(error) failed <<- TRUE
  )
  stopifnot(failed)
  message("Daily ERA5-Land download self-test passed")
}

# ---- run ----

if ("--self-test" %in% args) {
  run_self_test()
  quit(save = "no", status = 0)
}

project <- cli_value(args, "--project", "silica-synthesis")
folder <- cli_value(args, "--folder", required = TRUE)
asset_prefix <- cli_value(args, "--asset-prefix", required = TRUE)
site_alias_path <- cli_value(args, "--site-aliases", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
years <- parse_years(cli_value(args, "--years", "2000:2025"))
months <- parse_months(cli_value(args, "--months", "1:12"))
spatial_statistics <- parse_spatial_statistics(
  cli_value(args, "--spatial-statistics")
)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

aliases <- fread(require_input_file(site_alias_path, "site alias table"), na.strings = NULL)
assert_required_columns(
  aliases,
  c("site_id", "LTER", "Stream_Name", "Shapefile_Name"),
  "site alias table"
)
if (!"Spatial_Data_Version" %in% names(aliases)) {
  aliases[, Spatial_Data_Version := NA_integer_]
}
aliases[, site_id := trimws(as.character(site_id))]
aliases <- unique(aliases, by = c("site_id", "LTER", "Stream_Name", "Shapefile_Name"))
if (any(!nzchar(aliases$site_id))) {
  stop("The site alias table contains a blank site ID.", call. = FALSE)
}
if (!nrow(aliases) || anyDuplicated(aliases[, .(LTER, Stream_Name)])) {
  stop("Site aliases must contain one row per named site.", call. = FALSE)
}
expected_sites <- sort(unique(aliases$site_id))

token <- gee_access_token()
assets <- gee_list_assets(folder, project, token)
asset_ids <- sort(vapply(assets, function(asset) as.character(asset$name %||% ""), character(1)))
asset_ids <- asset_ids[
  nzchar(asset_ids) & startsWith(basename(asset_ids), asset_prefix)
]
if (!length(asset_ids)) {
  stop("The Earth Engine folder has no matching daily assets.", call. = FALSE)
}

prepare_output_dir(output_root)
for (year in years) {
  output_path <- file.path(
    output_root,
    if (identical(months, 1:12)) {
      sprintf(
        if (length(spatial_statistics)) {
          "era5_land_daily_watershed_spatial_stats_%d.tsv.gz"
        } else {
          "era5_land_daily_watershed_%d.tsv.gz"
        },
        year
      )
    } else {
      sprintf(
        if (length(spatial_statistics)) {
          "era5_land_daily_watershed_spatial_stats_%d_months_%s.tsv.gz"
        } else {
          "era5_land_daily_watershed_%d_months_%s.tsv.gz"
        },
        year,
        paste(sprintf("%02d", months), collapse = "-")
      )
    }
  )
  if (file.exists(output_path) && !overwrite) {
    stop("Output exists. Use --overwrite true to replace it: ", output_path, call. = FALSE)
  }
  month_pattern <- paste(sprintf("%02d", months), collapse = "|")
  year_assets <- asset_ids[grepl(
    sprintf("_%d(%s)$", year, month_pattern),
    basename(asset_ids)
  )]
  if (!length(year_assets)) {
    stop("No daily ERA5-Land assets were found for ", year, ".", call. = FALSE)
  }
  pieces <- lapply(year_assets, function(asset_id) {
    feature_rows(gee_compute_features(asset_id, project, token), asset_id)
  })
  geometry_rows <- validate_geometry_rows(
    rbindlist(pieces, fill = TRUE),
    expected_sites,
    year,
    months,
    spatial_statistics
  )
  geometry_rows <- add_humidity_drivers(geometry_rows, spatial_statistics)
  output <- expand_site_aliases(geometry_rows, aliases, spatial_statistics)
  # publish the yearly table only after compression succeeds
  temporary <- tempfile(tmpdir = output_root, fileext = ".tsv.gz")
  tryCatch({
    fwrite(output, temporary, sep = "	", compress = "gzip")
    if (!file.rename(temporary, output_path)) stop("Could not save ", output_path)
  }, finally = unlink(temporary))
  message(
    "Wrote ", nrow(output), " checked daily rows for ",
    uniqueN(output$site_row_id), " site rows in ", year, "."
  )
}
