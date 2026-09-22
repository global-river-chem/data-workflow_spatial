# download and check completed annual era5-land earth engine assets

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path("workflow", "gee", "era5_land", "download_annual_era5_land_assets.R")
}, mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
source(file.path(repo_root, "workflow", "gee", "gee_api.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- helpers ----

parse_years <- function(value) {
  value <- trimws(value)
  if (grepl(":", value, fixed = TRUE)) {
    bounds <- as.integer(strsplit(value, ":", fixed = TRUE)[[1]])
    if (length(bounds) != 2L || any(is.na(bounds))) stop("Invalid year range", call. = FALSE)
    return(seq(bounds[[1]], bounds[[2]]))
  }
  years <- as.integer(strsplit(value, ",", fixed = TRUE)[[1]])
  if (any(is.na(years))) stop("Invalid year list", call. = FALSE)
  sort(unique(years))
}

feature_rows <- function(features, asset_id) {
  rows <- lapply(features, function(feature) {
    properties <- feature$properties %||% list()
    properties$source_asset <- asset_id
    as.data.frame(properties, stringsAsFactors = FALSE, optional = TRUE)
  })
  rbindlist(rows, fill = TRUE)
}

# ---- run ----

project <- cli_value(args, "--project", "silica-synthesis")
folder <- cli_value(args, "--folder", required = TRUE)
site_inventory_path <- cli_value(args, "--site-inventory", required = TRUE)
output_path <- cli_value(args, "--output", required = TRUE)
years <- parse_years(cli_value(args, "--years", "2000:2025"))
overwrite <- cli_boolean(args, "--overwrite", FALSE)

inventory <- fread(require_input_file(site_inventory_path), na.strings = NULL)
assert_required_columns(inventory, "site_id", "ERA5-Land site inventory")
inventory[, site_id := trimws(as.character(site_id))]
if (any(is.na(inventory$site_id) | !nzchar(inventory$site_id))) {
  stop("The site inventory contains a blank site ID.", call. = FALSE)
}
expected_sites <- sort(unique(inventory$site_id))
if (!length(expected_sites)) stop("The site inventory contains no site IDs.", call. = FALSE)

token <- gee_access_token()
assets <- gee_list_assets(folder, project, token)
asset_ids <- sort(vapply(assets, function(asset) as.character(asset$name %||% ""), character(1)))
asset_ids <- asset_ids[nzchar(asset_ids)]
if (!length(asset_ids)) stop("The Earth Engine folder contains no assets.", call. = FALSE)

pieces <- vector("list", length(asset_ids))
for (index in seq_along(asset_ids)) {
  features <- gee_compute_features(asset_ids[[index]], project, token)
  pieces[[index]] <- feature_rows(features, asset_ids[[index]])
  message("Downloaded ", index, "/", length(asset_ids), " ERA5-Land assets")
}
output <- rbindlist(pieces, fill = TRUE)
assert_required_columns(output, c(
  "site_id", "lter", "stream_name", "shapefile_name", "year", "precip_mm",
  "temp_degC", "evapotrans_mm", "potential_evap_mm", "snow_cover_fraction",
  "snow_water_equiv_mm"
), "annual ERA5-Land output")
output[, year := as.integer(year)]
output[, site_id := trimws(as.character(site_id))]
if (any(is.na(output$site_id) | !nzchar(output$site_id) | is.na(output$year))) {
  stop("ERA5-Land output contains a blank site ID or year.", call. = FALSE)
}

driver_columns <- c(
  "precip_mm", "temp_degC", "evapotrans_mm", "potential_evap_mm",
  "snow_cover_fraction", "snow_water_equiv_mm"
)
for (column in driver_columns) {
  values <- suppressWarnings(as.numeric(output[[column]]))
  if (any(!is.finite(values))) {
    stop("ERA5-Land output contains a missing or non-finite value in ", column, call. = FALSE)
  }
  set(output, j = column, value = values)
}
nonnegative_columns <- c(
  "precip_mm", "evapotrans_mm", "potential_evap_mm", "snow_water_equiv_mm"
)
if (any(vapply(nonnegative_columns, function(column) {
  any(output[[column]] < -1e-8)
}, logical(1L)))) {
  stop("ERA5-Land output contains a negative precipitation, evaporation, or snow value.", call. = FALSE)
}
if (any(output$snow_cover_fraction < 0 | output$snow_cover_fraction > 1)) {
  stop("ERA5-Land snow-cover fractions must be between 0 and 1.", call. = FALSE)
}

key <- paste(output$site_id, output$year, sep = "\r")
expected_key <- as.vector(outer(expected_sites, years, paste, sep = "\r"))
missing <- setdiff(expected_key, key)
unexpected <- setdiff(key, expected_key)
if (anyDuplicated(key) || length(missing) || length(unexpected)) {
  stop(
    "ERA5-Land coverage is incomplete: ", length(missing), " missing site-years, ",
    length(unexpected), " unexpected site-years, and ", anyDuplicated(key),
    " as the first duplicate position.",
    call. = FALSE
  )
}

setorder(output, site_id, year)
if (file.exists(output_path) && !overwrite) {
  stop("Output exists. Use --overwrite true to replace it: ", output_path, call. = FALSE)
}
prepare_output_dir(output_path, is_file = TRUE)
fwrite(output, output_path)
message(
  "Wrote ", nrow(output), " checked annual rows for ", length(expected_sites),
  " sites to ", normalizePath(output_path)
)
