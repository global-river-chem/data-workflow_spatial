# ---- setup ----

script_path <- function() {
  argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(argument)) return(normalizePath(sub("^--file=", "", argument[[1]])))
  normalizePath("workflow/release/build_spatial_dataset_files.R", mustWork = FALSE)
}

repo_root <- normalizePath(file.path(dirname(script_path()), "../.."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
modis_path <- require_input_file(
  cli_value(args, "--modis-input", required = TRUE),
  "MODIS harmonized input"
)
era5_path <- require_input_file(
  cli_value(args, "--era5-input", required = TRUE),
  "ERA5-Land harmonized input"
)
output_root <- cli_value(args, "--output-root", required = TRUE)
expected_rows <- cli_integer(args, "--expected-rows", default = 1040L, minimum = 1L)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

# ---- inputs ----

read_input <- function(path) {
  read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("NA")
  )
}

modis <- read_input(modis_path)
era5 <- read_input(era5_path)

identity_columns <- c(
  "LTER", "Stream_Name", "Stream_ID", "Shapefile_Name",
  "Discharge_File_Name", "Latitude", "Longitude", "drainSqKm"
)
require_columns(modis, identity_columns, "MODIS harmonized input")
require_columns(era5, identity_columns, "ERA5-Land harmonized input")

if (nrow(modis) != expected_rows || nrow(era5) != expected_rows) {
  stop(
    "Expected ", expected_rows, " rows in each harmonized input; found ",
    nrow(modis), " and ", nrow(era5),
    call. = FALSE
  )
}

row_key <- function(data) {
  do.call(paste, c(data[c("LTER", "Stream_Name", "Stream_ID")], sep = "::"))
}

modis_key <- row_key(modis)
era5_key <- row_key(era5)
if (anyDuplicated(modis_key) || anyDuplicated(era5_key)) {
  stop("Harmonized inputs contain duplicate site keys", call. = FALSE)
}
identity_mismatches <- identity_columns[!vapply(
  identity_columns,
  function(column) identical(modis[[column]], era5[[column]]),
  logical(1L)
)]
if (length(identity_mismatches)) {
  stop(
    "MODIS and ERA5-Land identity fields differ in value or row order: ",
    paste(identity_mismatches, collapse = ", "),
    call. = FALSE
  )
}

# ---- dataset groups ----

matching_columns <- function(data, pattern) {
  grep(pattern, names(data), value = TRUE, perl = TRUE)
}

coast_pattern <- paste0(
  "^(hydrorivers_|HYRIV_ID$|MAIN_RIV$|NEXT_DOWN$|HYBAS_L12$|",
  "downstream_|upland_skm$|reach_length_km$|discharge_est_cms$|",
  "endorheic$|drains_to_ocean$|coast_distance_status$|ORD_|",
  "snap_distance_km$|hydrorivers_match_source$|point_match_method$)"
)

groups <- list(
  `land-cover-glc/glc_land_cover_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^gee_glc_")
  ),
  `era5-land/era5_land_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^era5_land_")
  ),
  `modis-npp/modis_npp_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^npp_")
  ),
  `modis-et/modis_et_base.csv` = list(
    data = modis,
    columns = matching_columns(modis, "^evapotrans_")
  ),
  `modis-greenup/modis_greenup_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^greenup_")
  ),
  `modis-snow/modis_snow_base.csv` = list(
    data = modis,
    columns = matching_columns(modis, "^snow_")
  ),
  `aurora-climate/aurora_climate_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^(temp_|precip_)")
  ),
  `static-variables/static_variables_base.csv` = list(
    data = era5,
    columns = matching_columns(
      era5,
      "^(elevation_|basin_slope_|major_rock$|rocks_|permafrost_|major_soil$|soil_)"
    )
  ),
  `human-impacts/human_impacts_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^human_")
  ),
  `distance-to-coast/distance_to_coast_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, coast_pattern)
  )
)

names(groups) <- sub(
  "[.]csv$",
  paste0("_", expected_rows, ".csv"),
  names(groups)
)

# ---- outputs ----

output_paths <- file.path(output_root, names(groups))
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}

for (relative_path in names(groups)) {
  group <- groups[[relative_path]]
  if (!length(group$columns)) {
    stop("No dataset columns selected for ", relative_path, call. = FALSE)
  }
  columns <- unique(c(identity_columns, group$columns))
  output <- group$data[, columns, drop = FALSE]
  if (nrow(output) != expected_rows || anyDuplicated(row_key(output))) {
    stop("Invalid output rows for ", relative_path, call. = FALSE)
  }
  output_path <- file.path(output_root, relative_path)
  prepare_output_dir(output_path, is_file = TRUE)
  write.csv(output, output_path, row.names = FALSE, na = "")
  message(
    relative_path, ": ", nrow(output), " rows, ", ncol(output), " columns"
  )
}
