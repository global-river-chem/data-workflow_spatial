# ---- setup ----

script_path <- function() {
  argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(argument)) return(normalizePath(sub("^--file=", "", argument[[1]])))
  normalizePath("workflow/release/build_spatial_dataset_files.R", mustWork = FALSE)
}

repo_root <- normalizePath(file.path(dirname(script_path()), "../.."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
glass_path <- require_input_file(
  cli_value(args, "--glass-input", required = TRUE), "unchanged glass dataset"
)
saved_path <- require_input_file(
  cli_value(args, "--saved-input", required = TRUE), "human and river extraction results"
)
glass_hash <- tools::md5sum(glass_path)
output_root <- cli_value(args, "--output-root", required = TRUE)
if (any(dir.exists(file.path(output_root, c("modis-et", "modis-snow", "aurora-climate"))))) {
  stop("choose a new release folder so replaced products cannot remain alongside ERA5-Land")
}
expected_rows <- cli_integer(args, "--expected-rows", default = NULL, minimum = 1L)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

read_input <- function(path) {
  if (tolower(tools::file_ext(path)) == "rds") return(readRDS(path))
  read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("", "NA")
  )
}

identity_columns <- c(
  "LTER", "Stream_Name", "Latitude", "Longitude", "drainSqKm", "Site_Flag"
)

row_key <- function(data) {
  do.call(paste, c(data[c("LTER", "Stream_Name")], sep = "::"))
}

# package the checked combined file without rebuilding its upstream inputs
combined_path <- cli_value(args, "--combined-input")
if (!is.null(combined_path)) {
  combined_path <- require_input_file(combined_path, "updated combined dataset")
  metadata_input <- require_input_file(cli_value(args, "--metadata", required = TRUE), "site metadata")
  source_paths <- c(glass_path, saved_path, combined_path, metadata_input)
  if (normalizePath(combined_path) == normalizePath(glass_path)) stop("Use the updated dataset as input")
  era5 <- read_input(combined_path)
  site_metadata <- read_input(metadata_input)
  require_columns(era5, identity_columns, "updated combined dataset")
  require_columns(site_metadata, identity_columns, "site metadata")
  if (is.null(expected_rows)) expected_rows <- nrow(era5)
  if (nrow(era5) != expected_rows || anyDuplicated(row_key(era5)) ||
      anyDuplicated(row_key(site_metadata)) || !setequal(row_key(era5), row_key(site_metadata))) {
    stop("The combined dataset and metadata must contain the same unique sites")
  }
  site_metadata <- site_metadata[match(row_key(era5), row_key(site_metadata)), , drop = FALSE]
  if (!isTRUE(all.equal(era5[identity_columns], site_metadata[identity_columns],
      check.attributes = FALSE))) stop("Site identities differ between the combined file and metadata")
  source(file.path(repo_root, "workflow/release/update_new_spatial_dataset.R"))
  checked <- update_new_spatial_data(era5, read_input(glass_path), read_input(saved_path), site_metadata)
  if (!identical(checked, era5)) stop("The combined file differs from the checked source matches")
  # describe the coverage of the reviewed watersheds in the release metadata
  camrex <- read.delim(file.path(repo_root, "workflow/watershed_delineation/config/glorich_camrex_targets.tsv"))
  missing_camrex <- row_key(site_metadata) %in% row_key(camrex) & site_metadata$Has_Spatial_Data == "No"
  site_metadata$Spatial_Recovery_Note[missing_camrex] <-
    "Reviewed GLORICH boundary available. No verified annual predictor results for this watershed."
  ferguson <- site_metadata$LTER == "WesternAustralia" &
    site_metadata$Stream_Name == "Ferguson River - Dowdells Rd Bridge"
  if (any(ferguson) && all(!is.na(era5$bess_gpp_1982_gC_m2_year[ferguson]))) {
    site_metadata$Spatial_Recovery_Note[ferguson] <- paste(
      "Corrected watershed has annual ERA5-Land and BESS GPP, available MODIS NPP and greenup,
      human impacts and routing. Land cover and static predictors are missing."
    )
  }
} else {
  bess_path <- require_input_file(
    cli_value(args, "--bess-input", required = TRUE),
    "checked BESSv2 annual watershed summary"
  )
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
  chemistry_path <- require_input_file(
    cli_value(args, "--chemistry", required = TRUE), "finalized master chemistry"
  )
  data_root <- cli_value(args, "--data-root", required = TRUE)
  class_key <- require_input_file(
    cli_value(args, "--land-cover-key", required = TRUE), "existing land-cover class key"
  )
  era5_updates_path <- cli_value(args, "--era5-updates", "")
  boundary_updates_path <- cli_value(args, "--boundary-updates", "")
  download_boundary <- cli_boolean(args, "--download-boundary", TRUE)
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
  era5 <- add_bess_gpp(era5, read_input(bess_path), site_reference)

  # restore saved products and apply the era5-land replacement rules
  source(file.path(repo_root, "workflow/release/update_new_spatial_dataset.R"))
  glass <- read_input(glass_path)
  saved <- read_input(saved_path)
  current_metadata <- site_reference
  current_metadata$Watershed_File_Name <- site_reference$Shapefile_Name
  era5 <- update_new_spatial_data(era5, glass, saved, current_metadata)
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

  require_columns(modis, identity_columns, "MODIS harmonized input")
  require_columns(era5, identity_columns, "ERA5-Land harmonized input")

  if (nrow(modis) != expected_rows || nrow(era5) != expected_rows) {
    stop(
      "Expected ", expected_rows, " rows in each harmonized input; found ",
      nrow(modis), " and ", nrow(era5),
      call. = FALSE
    )
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
    Productivity_Source = rep("BESSv2 GPP", nrow(modis)),
    Productivity_Units = rep("gC_m2_year", nrow(modis)),
    Productivity_Note = rep(paste(
      "monthly mean daily GPP multiplied by calendar days and summed over the reported watershed area fraction;",
      "valid days and area fractions accompany each year; missing years stay blank;",
      "source-zero trend flags retain the original GPP values;",
      "ERA5-Land replaces overlapping climate, ET, and snow products;",
      "new NDVI and replacement greenup investigations are closed;",
      "MODIS NPP, greenup, and verified human and river results are included;",
      "the separate AppEEARS/GLASS version remains unchanged"
    ), nrow(modis)),
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

  source_paths <- c(glass_path, saved_path, modis_path, era5_path,
    site_reference_path, bess_path, chemistry_path, class_key)
}

# apply verified camrex results after checking the earlier source matches
camrex_options <- c(
  "bess-gpp" = "--camrex-bess-input", "modis-npp" = "--camrex-npp-input",
  "modis-greenup" = "--camrex-greenup-input", "site-metadata" = "--camrex-coverage-input"
)
camrex_paths <- lapply(camrex_options, function(option) cli_value(args, option))
provided <- !vapply(camrex_paths, is.null, logical(1))
if (!is.null(cli_value(args, "--verified-camrex-input")) || (any(provided) && !all(provided))) {
  stop("provide all four camrex inputs: ", paste(camrex_options, collapse = ", "))
}
if (all(provided)) {
  camrex_paths <- Map(require_input_file, camrex_paths, names(camrex_paths))
  source(file.path(repo_root, "workflow/release/apply_verified_camrex.R"))
  targets <- read.delim(file.path(repo_root, "workflow/watershed_delineation/config/glorich_camrex_targets.tsv"))
  refreshed <- apply_verified_camrex(era5, site_metadata, lapply(camrex_paths, read_input), targets)
  era5 <- refreshed$data
  site_metadata <- refreshed$metadata
  source_paths <- c(source_paths, unlist(camrex_paths, use.names = FALSE))
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
  `bess-gpp/bess_gpp_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^bess_gpp_")
  ),
  `modis-npp/modis_npp_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^npp_|^modis_(npp|vegetation)_status$")
  ),
  `modis-greenup/modis_greenup_base.csv` = list(
    data = era5,
    columns = matching_columns(era5, "^greenup_|^modis_(greenup|vegetation)_status$")
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
source_paths <- normalizePath(source_paths)
if (any(normalizePath(existing_outputs) %in% source_paths)) {
  stop("release outputs must be separate from their source inputs", call. = FALSE)
}
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

stopifnot(identical(tools::md5sum(glass_path), glass_hash))
