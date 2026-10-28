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
site_reference_path <- require_input_file(
  cli_value(args, "--site-reference", required = TRUE),
  "site reference table"
)
output_root <- cli_value(args, "--output-root", required = TRUE)
chemistry_path <- require_input_file(
  cli_value(args, "--chemistry", required = TRUE), "finalized master chemistry"
)
data_root <- cli_value(args, "--data-root", required = TRUE)
class_key <- require_input_file(
  cli_value(args, "--land-cover-key", required = TRUE), "existing land-cover class key"
)
expected_rows <- cli_integer(args, "--expected-rows", default = NULL, minimum = 1L)
overwrite <- cli_boolean(args, "--overwrite", FALSE)
era5_updates_path <- cli_value(args, "--era5-updates", "")
boundary_updates_path <- cli_value(args, "--boundary-updates", "")
download_boundary <- cli_boolean(args, "--download-boundary", TRUE)

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
site_reference <- read_input(site_reference_path)
names(site_reference) <- trimws(names(site_reference))

site_flag_columns <- c("LTER", "Stream_Name", "Flag", "Has_Spatial_Data")
require_columns(site_reference, c(site_flag_columns, "Has_Spatial_Data",
  "Shapefile_Name", "Latitude", "Longitude", "drainSqKm"), "site reference table")

# recover saved results in memory before writing any release files
source(file.path(repo_root, "workflow/release/recover_saved_spatial_results.R"))
recovery <- recover_saved_spatial_results(
  modis, era5, site_reference, chemistry_path, data_root, class_key,
  boundary_updates_path = boundary_updates_path, era5_updates_path = era5_updates_path,
  download_boundary = download_boundary
)
modis <- recovery$modis
era5 <- recovery$era5
if (is.null(expected_rows)) expected_rows <- nrow(modis)

site_flags <- site_reference[, site_flag_columns, drop = FALSE]
site_flag_key <- paste(site_flags$LTER, site_flags$Stream_Name, sep = "\r")
if (anyDuplicated(site_flag_key)) {
  stop("The site reference table contains duplicate site keys", call. = FALSE)
}

# attach the current site flag without changing row order or site coverage
add_site_flags <- function(data, input_name) {
  require_columns(data, c("LTER", "Stream_Name"), input_name)
  input_key <- paste(data$LTER, data$Stream_Name, sep = "\r")
  matched <- match(input_key, site_flag_key)
  if (anyNA(matched)) {
    missing <- unique(paste(
      data$LTER[is.na(matched)],
      data$Stream_Name[is.na(matched)],
      sep = " / "
    ))
    shown <- head(missing, 20L)
    remainder <- length(missing) - length(shown)
    stop(
      input_name, " has ", length(missing),
      " sites missing from the site reference table: ",
      paste(shown, collapse = ", "),
      if (remainder > 0L) paste0(", and ", remainder, " more") else "",
      call. = FALSE
    )
  }
  data$Site_Flag <- spatial_site_flags(site_flags[matched, , drop = FALSE])
  data
}

modis <- add_site_flags(modis, "MODIS harmonized input")
era5 <- add_site_flags(era5, "ERA5-Land harmonized input")

identity_columns <- c(
  "LTER", "Stream_Name", "Latitude", "Longitude", "drainSqKm", "Site_Flag"
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
  do.call(paste, c(data[c("LTER", "Stream_Name")], sep = "::"))
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

# keep descriptive site details in one public metadata file
reference_key <- paste(modis$LTER, modis$Stream_Name, sep = "\r")
reference_rows <- site_reference[match(reference_key, site_flag_key), , drop = FALSE]

metadata_value <- function(reference_column, harmonized_column = reference_column) {
  if (reference_column %in% names(reference_rows)) {
    value <- reference_rows[[reference_column]]
  } else if (harmonized_column %in% names(modis)) {
    return(modis[[harmonized_column]])
  } else {
    return(rep(NA_character_, nrow(modis)))
  }

  if (harmonized_column %in% names(modis)) {
    fallback <- modis[[harmonized_column]]
    missing <- is.na(value) | trimws(as.character(value)) == ""
    value[missing] <- fallback[missing]
  }
  value
}

metadata_values <- list(
  LTER = modis$LTER,
  Stream_Name = modis$Stream_Name,
  Country = metadata_value("Country"),
  State = metadata_value("State"),
  Waterbody = metadata_value("Waterbody"),
  Major_Drainage_Basin = metadata_value("Major_Drainage_Basin"),
  Latitude = modis$Latitude,
  Longitude = modis$Longitude,
  Alt_Stream_Name = metadata_value("Alt_Stream_Name"),
  drainSqKm = modis$drainSqKm,
  Drainage_Area_Verified = metadata_value("drainSqKm_Verified"),
  Drainage_Area_Source = metadata_value("drainSqKm_url", "drainSqKm_source"),
  Site_Flag = modis$Site_Flag,
  Has_Spatial_Data = recovery$has_spatial,
  ERA5_Coverage = recovery$coverage,
  Spatial_Recovery_Note = recovery$recovery_note,
  Watershed_File_Name = metadata_value("Shapefile_Name"),
  Watershed_CRS_EPSG = metadata_value("Shapefile_CRS_EPSG"),
  Watershed_Boundary_Source = metadata_value("shapefile_url", "Shapefile_Link"),
  Spatial_Notes = metadata_value("Spatial_Notes"),
  USGSGageNumber = metadata_value("USGSGageNumber"),
  Use_WRTDS = metadata_value("Use_WRTDS"),
  Discharge_File_Name = metadata_value("Discharge_File_Name"),
  Discharge_Units = metadata_value("Units"),
  Discharge_Site_Name = metadata_value("Discharge_Site_Name"),
  Discharge_Latitude = metadata_value("q.latitude_dd"),
  Discharge_Longitude = metadata_value("q.longitude_dd"),
  Chemistry_Discharge_Distance_km = metadata_value("c.q.distance_km"),
  Site_Coordinate_Source = metadata_value("chem_latlong_source_url"),
  Discharge_Coordinate_Source = metadata_value("q_latlong_source_url"),
  Chemistry_Source = metadata_value("chem_source_URL"),
  Discharge_Source = metadata_value("q_source_URL"),
  CQ_Notes = metadata_value("CQ_Notes"),
  GlASS_First_Release = metadata_value("GlASS_First_Release"),
  CQ_Data_Version = metadata_value("CQ_Data_Version"),
  Spatial_Data_Version = metadata_value("Spatial_Data_Version")
)
has_value <- vapply(
  metadata_values,
  function(value) any(!is.na(value) & trimws(as.character(value)) != ""),
  logical(1L)
)
has_value[names(metadata_values) %in% identity_columns] <- TRUE
site_metadata <- as.data.frame(
  metadata_values[has_value],
  stringsAsFactors = FALSE,
  check.names = FALSE
)

if (nrow(site_metadata) != expected_rows || anyDuplicated(row_key(site_metadata))) {
  stop("Invalid site metadata rows", call. = FALSE)
}

# ---- dataset groups ----

matching_columns <- function(data, pattern) {
  grep(pattern, names(data), value = TRUE, perl = TRUE)
}

glc_value_columns <- matching_columns(era5, "^gee_glc_[0-9]{4}_")
glc_years <- suppressWarnings(as.integer(sub(
  "^gee_glc_([0-9]{4})_.*$",
  "\\1",
  glc_value_columns
)))
glc_classes <- sub("^gee_glc_[0-9]{4}_", "", glc_value_columns)
glc_year_counts <- table(glc_years)
expected_glc_classes <- sort(unique(glc_classes[glc_years == 1985L]))
glc_classes_by_year <- split(glc_classes, glc_years)
if (
  !identical(sort(unique(glc_years)), 1985:2022) ||
    !identical(as.integer(glc_year_counts), rep(11L, 38L)) ||
    length(expected_glc_classes) != 11L ||
    anyDuplicated(glc_value_columns) ||
    !all(vapply(
      glc_classes_by_year,
      function(classes) identical(sort(classes), expected_glc_classes),
      logical(1L)
    ))
) {
  stop(
    "GLC columns must contain 11 classes for every year from 1985 through 2022.",
    call. = FALSE
  )
}

glc_columns <- c(
  setdiff(matching_columns(era5, "^gee_glc_"), glc_value_columns),
  glc_value_columns
)

coast_pattern <- paste0(
  "^(hydrorivers_|HYRIV_ID$|MAIN_RIV$|NEXT_DOWN$|HYBAS_L12$|",
  "downstream_|upland_skm$|reach_length_km$|discharge_est_cms$|",
  "endorheic$|drains_to_ocean$|coast_distance_status$|ORD_|",
  "snap_distance_km$|hydrorivers_match_source$|point_match_method$)"
)

groups <- list(
  `land-cover-glc/glc_land_cover_base.csv` = list(
    data = era5,
    columns = glc_columns
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

# human impacts and distance to coast are not part of this release
groups <- groups[!names(groups) %in% c(
  "human-impacts/human_impacts_base.csv", "distance-to-coast/distance_to_coast_base.csv"
)]

names(groups) <- sub(
  "[.]csv$",
  paste0("_", expected_rows, ".csv"),
  names(groups)
)

empty_groups <- names(groups)[!vapply(
  groups,
  function(group) length(group$columns) > 0L,
  logical(1L)
)]
if (length(empty_groups)) {
  stop(
    "No dataset columns selected for: ",
    paste(empty_groups, collapse = ", "),
    call. = FALSE
  )
}

# ---- outputs ----

metadata_relative_path <- file.path(
  "site-metadata",
  paste0("site_metadata_", expected_rows, ".csv")
)
output_paths <- file.path(output_root, c(names(groups), metadata_relative_path))
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}

metadata_path <- file.path(output_root, metadata_relative_path)
prepare_output_dir(metadata_path, is_file = TRUE)
write.csv(site_metadata, metadata_path, row.names = FALSE, na = "")
message(
  metadata_relative_path, ": ", nrow(site_metadata), " rows, ",
  ncol(site_metadata), " columns"
)

for (relative_path in names(groups)) {
  group <- groups[[relative_path]]
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
