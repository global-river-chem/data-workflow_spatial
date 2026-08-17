### Setup

suppressPackageStartupMessages(library(sf))
source(file.path("workflow", "lib", "workflow_helpers.R"))

old_modis_default <- file.path(
  "generated_outputs", "harmonized-spatial-20260811",
  "harmonized_spatial_modis_human_impacts_20260811.csv"
)
old_era5_default <- file.path(
  "generated_outputs", "harmonized-spatial-20260811",
  "harmonized_spatial_era5land_modis_human_impacts_20260811.csv"
)
rerun_root_default <- file.path(
  "generated_outputs", "spatial-rerun-20260815"
)
output_root_default <- file.path(
  "generated_outputs", "harmonized-spatial-20260815"
)


### Small helpers

stop_with <- function(...) {
  stop(paste0(...), call. = FALSE)
}

site_key <- function(lter, stream) {
  paste(trimws(as.character(lter)), trimws(as.character(stream)), sep = "\r")
}

shape_key <- function(value) {
  tolower(gsub("[^a-z0-9]+", "", as.character(value)))
}

### Arguments

parse_args <- function(arguments) {
  values <- list(
    old_modis = old_modis_default,
    old_era5 = old_era5_default,
    watershed_qa = file.path(
      "generated_outputs", "watersheds-20260815",
      "watersheds_all_sites_20260815_qa.rds"
    ),
    aliases = file.path(
      "generated_outputs", "watersheds-20260815",
      "watersheds_all_sites_20260815_site_aliases.tsv"
    ),
    updates = file.path(
      "generated_outputs", "watersheds-20260815",
      "watersheds_site_reference_updates_66_20260815.tsv"
    ),
    state_updates = file.path(
      "generated_outputs", "public-site-incorporation-20260815",
      "site_reference_state_updates_154_20260815.tsv"
    ),
    discharge_updates = file.path(
      "generated_outputs", "public-site-incorporation-20260815",
      "discharge_assignment_updates_183_20260815.tsv"
    ),
    replacement_watersheds = file.path(
      rerun_root_default, "replacement-watersheds-66_20260815.gpkg"
    ),
    remaining_watersheds = file.path(
      rerun_root_default, "remaining-public-guadeloupe-85_20260815.gpkg"
    ),
    glc_source = file.path(
      rerun_root_default, "glc",
      "glc_fcs30d_replacements_151_20260815.csv"
    ),
    glc_crosswalk = file.path(
      "generated_outputs", "harmonized-spatial-20260811",
      "GLC_FCS30D_full_to_simple_class_translation.csv"
    ),
    modis_dir = file.path(rerun_root_default, "modis"),
    era5_source = file.path(
      rerun_root_default, "era5-land",
      "era5_land_replacements_151_20260815.csv"
    ),
    gee_qa = file.path(
      rerun_root_default,
      "gee_replacements_151_20260815_qa.rds"
    ),
    modis_qa = file.path(
      rerun_root_default,
      "modis",
      "modis_parity_qa_gee_20260815_boundary_fix.rds"
    ),
    human_source = file.path(
      rerun_root_default, "human-impacts",
      "human_impacts_release3_151_long.csv"
    ),
    air_temp_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_air-temp_20260815_release3-boundary-fix.csv"
    ),
    precip_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_precip_20260815_release3-boundary-fix.csv"
    ),
    elevation_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_elevation_20260815_release3-boundary-fix.csv"
    ),
    lithology_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_lithology_20260815_release3-boundary-fix.csv"
    ),
    permafrost_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_permafrost_20260815_release3-boundary-fix.csv"
    ),
    soil_source = file.path(
      rerun_root_default, "aurora",
      "si-extract_soil_20260815_release3-boundary-fix.csv"
    ),
    output_dir = output_root_default,
    site_base = "",
    write = FALSE
  )
  index <- 1L
  while (index <= length(arguments)) {
    token <- arguments[[index]]
    if (token == "--write") {
      values$write <- TRUE
      index <- index + 1L
      next
    }
    if (!startsWith(token, "--") || index == length(arguments)) {
      stop_with("Unexpected or incomplete argument: ", token)
    }
    name <- gsub("-", "_", substring(token, 3L), fixed = TRUE)
    if (!name %in% names(values) || name == "write") {
      stop_with("Unknown argument: ", token)
    }
    values[[name]] <- arguments[[index + 1L]]
    index <- index + 2L
  }
  values
}


### Input discovery

modis_files <- function(path) {
  products <- c("evapo", "greenup", "npp", "snow")
  output <- setNames(vector("list", length(products)), products)
  if (!dir.exists(path)) return(output)
  candidates <- list.files(
    path,
    pattern = "[.]csv$",
    recursive = TRUE,
    full.names = TRUE
  )
  for (product in products) {
    pattern <- paste0("^si-extract_", product, "_v061_.*[.]csv$")
    output[[product]] <- sort(candidates[grepl(pattern, basename(candidates))])
  }
  output
}

discover_inputs <- function(settings, site_base) {
  modis <- modis_files(settings$modis_dir)
  glc <- data_files(settings$glc_source, c("site_id", "Year", "LC_ID", "Area_m2"))
  era5 <- data_files(
    settings$era5_source,
    c(
      "site_id", "year", "precip_mm", "temp_degC", "evapotrans_mm",
      "potential_evap_mm", "snow_cover_fraction", "snow_water_equiv_mm"
    )
  )
  human <- data_files(
    settings$human_source,
    c("site_id", "human_impact_dataset", "year")
  )
  aurora <- c(
    air_temp = settings$air_temp_source,
    precip = settings$precip_source,
    elevation = settings$elevation_source,
    lithology = settings$lithology_source,
    permafrost = settings$permafrost_source,
    soil = settings$soil_source
  )
  static <- c(
    old_modis = settings$old_modis,
    old_era5 = settings$old_era5,
    watershed_qa = settings$watershed_qa,
    aliases = settings$aliases,
    updates = settings$updates,
    state_updates = settings$state_updates,
    discharge_updates = settings$discharge_updates,
    replacement_watersheds = settings$replacement_watersheds,
    remaining_watersheds = settings$remaining_watersheds,
    glc_crosswalk = settings$glc_crosswalk,
    site_base = site_base
  )
  ready <- c(
    setNames(file.exists(static), names(static)),
    glc = length(glc) > 0L,
    modis_evapo = length(modis$evapo) == 1L,
    modis_greenup = length(modis$greenup) == 1L,
    modis_npp = length(modis$npp) == 1L,
    modis_snow = length(modis$snow) == 1L,
    era5 = length(era5) > 0L,
    gee_qa = file.exists(settings$gee_qa),
    modis_qa = file.exists(settings$modis_qa),
    human_impacts = length(human) == 1L,
    setNames(file.exists(aurora), paste0("aurora_", names(aurora)))
  )
  list(
    ready = ready,
    static = static,
    glc = glc,
    modis = modis,
    era5 = era5,
    qa_files = c(gee = settings$gee_qa, modis = settings$modis_qa),
    human = human,
    aurora = aurora
  )
}

print_discovery <- function(found, settings) {
  cat("Release-three spatial input readiness\n")
  for (name in names(found$ready)) {
    cat(sprintf("  %-24s %s\n", name, if (found$ready[[name]]) "ready" else "missing"))
  }
  cat("\nDriver locations\n")
  cat("  GLC:           ", settings$glc_source, "\n", sep = "")
  cat("  MODIS:         ", settings$modis_dir, "\n", sep = "")
  cat("  ERA5-Land:     ", settings$era5_source, "\n", sep = "")
  cat("  human impacts: ", settings$human_source, "\n", sep = "")
  cat("  Aurora patches: ", dirname(settings$air_temp_source), "\n", sep = "")
}


### Release scope

read_discharge_updates <- function(path, old_key, new_key, site_reference_path) {
  columns <- c(
    "Live_LTER", "Spatial_LTER", "Stream_Name", "Discharge_File_Name",
    "Units", "Discharge_Site_Name", "Chemistry_Latitude",
    "Chemistry_Longitude", "Discharge_Latitude", "Discharge_Longitude",
    "Pairing_Distance_km", "Proposed_Use_WRTDS", "Use_WRTDS_for_release",
    "Spatial_Release_Match"
  )
  data <- read.delim(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = ""
  )
  if (!identical(names(data), columns)) {
    stop_with("The staged discharge updates do not have the exact 14-field schema")
  }

  live_key <- site_key(data$Live_LTER, data$Stream_Name)
  spatial_key <- site_key(data$Spatial_LTER, data$Stream_Name)
  matched <- spatial_key %in% c(old_key, new_key)
  staged_match <- normalized_text(data$Spatial_Release_Match) == "Yes"
  if (
    nrow(data) != 183L || anyDuplicated(live_key) || anyDuplicated(spatial_key) ||
      sum(matched) != 178L || sum(!matched) != 5L ||
      sum(spatial_key %in% old_key) != 173L ||
      sum(spatial_key %in% new_key) != 5L ||
      !identical(matched, staged_match)
  ) {
    stop_with("The discharge updates do not have the exact 183/178/5 release split")
  }

  lter_changed <- normalized_text(data$Live_LTER) !=
    normalized_text(data$Spatial_LTER)
  if (
    sum(lter_changed) != 4L ||
      any(data$Live_LTER[lter_changed] != "ECCC_Canada") ||
      any(data$Spatial_LTER[lter_changed] != "Canada_ECCC")
  ) {
    stop_with("The staged discharge LTER-name crosswalk is not the supported ECCC mapping")
  }

  required_text <- c(
    "Live_LTER", "Spatial_LTER", "Stream_Name", "Discharge_File_Name",
    "Units", "Proposed_Use_WRTDS", "Use_WRTDS_for_release",
    "Spatial_Release_Match"
  )
  if (any(vapply(required_text, function(column) {
    !nzchar(normalized_text(data[[column]]))
  }, logical(nrow(data))))) {
    stop_with("A staged discharge update is missing a required value")
  }
  if (
    any(normalized_text(data$Units) != "cms") ||
      any(!normalized_text(data$Proposed_Use_WRTDS) %in% c("Yes", "No")) ||
      any(!normalized_text(data$Use_WRTDS_for_release) %in% c("Yes", "No")) ||
      any(!normalized_text(data$Spatial_Release_Match) %in% c("Yes", "No"))
  ) {
    stop_with("The staged discharge units or decision fields are invalid")
  }

  held <- normalized_text(data$Proposed_Use_WRTDS) == "Yes" &
    normalized_text(data$Use_WRTDS_for_release) == "No"
  expected_held <- site_key("LMP", c("DCF03", "SBM0.2", "WHB01"))
  if (
    !setequal(live_key[held], expected_held) ||
      any(
        normalized_text(data$Proposed_Use_WRTDS[!held]) !=
          normalized_text(data$Use_WRTDS_for_release[!held])
      )
  ) {
    stop_with("The three provisional LMP WRTDS decisions were not held at No")
  }

  chemistry_latitude <- suppressWarnings(as.numeric(data$Chemistry_Latitude))
  chemistry_longitude <- suppressWarnings(as.numeric(data$Chemistry_Longitude))
  discharge_latitude <- suppressWarnings(as.numeric(data$Discharge_Latitude))
  discharge_longitude <- suppressWarnings(as.numeric(data$Discharge_Longitude))
  pairing_distance <- suppressWarnings(as.numeric(data$Pairing_Distance_km))
  if (
    any(!is.finite(chemistry_latitude) | chemistry_latitude < -90 |
      chemistry_latitude > 90) ||
      any(!is.finite(chemistry_longitude) | chemistry_longitude < -180 |
        chemistry_longitude > 180)
  ) {
    stop_with("A staged chemistry coordinate is invalid")
  }
  discharge_coordinates <- is.finite(discharge_latitude) &
    is.finite(discharge_longitude)
  if (
    any(xor(is.finite(discharge_latitude), is.finite(discharge_longitude))) ||
      any(discharge_coordinates != is.finite(pairing_distance)) ||
      sum(discharge_coordinates) != 158L ||
      sum(discharge_coordinates & matched) != 156L ||
      any(discharge_latitude[discharge_coordinates] < -90 |
        discharge_latitude[discharge_coordinates] > 90) ||
      any(discharge_longitude[discharge_coordinates] < -180 |
        discharge_longitude[discharge_coordinates] > 180) ||
      any(pairing_distance[discharge_coordinates] < 0)
  ) {
    stop_with("The staged discharge-coordinate coverage or range is invalid")
  }

  site_reference <- read_csv(site_reference_path)
  require_columns(
    site_reference,
    c("LTER", "Stream_Name", "Has_Spatial_Data", "Shapefile_Name"),
    "read-only site reference"
  )
  reference_key <- site_key(site_reference$LTER, site_reference$Stream_Name)
  reference_index <- match(live_key, reference_key)
  use_spatial_name <- is.na(reference_index)
  reference_index[use_spatial_name] <- match(
    spatial_key[use_spatial_name],
    reference_key
  )
  if (any(is.na(reference_index))) {
    stop_with("A staged discharge assignment is absent from the read-only site reference")
  }
  excluded_index <- reference_index[!matched]
  if (
    any(normalized_text(site_reference$Has_Spatial_Data[excluded_index]) != "No") ||
      any(nzchar(normalized_text(site_reference$Shapefile_Name[excluded_index])))
  ) {
    stop_with("A discharge assignment excluded from the spatial release has a watershed")
  }
  data
}

read_release_scope <- function(settings, site_base_path, site_reference_path) {
  old_modis <- read_csv(settings$old_modis)
  old_era5 <- read_csv(settings$old_era5)
  aliases <- read.delim(
    settings$aliases,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = ""
  )
  updates <- read.delim(
    settings$updates,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = ""
  )
  state_updates <- read.delim(
    settings$state_updates,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = ""
  )
  site_base <- read_csv(site_base_path)

  require_columns(old_modis, c("LTER", "Stream_Name", "canonical_row_id"), "20260811 MODIS baseline")
  require_columns(old_era5, c("LTER", "Stream_Name", "canonical_row_id"), "20260811 ERA5-Land baseline")
  require_columns(
    aliases,
    c("site_id", "LTER", "Stream_Name", "Shapefile_Name", "Spatial_Data_Version"),
    "20260815 aliases"
  )
  require_columns(
    updates,
    c("LTER", "Stream_Name", "New_Site_ID", "Shapefile_Name_new"),
    "20260815 watershed updates"
  )
  require_columns(
    state_updates,
    c(
      "LTER", "Stream_Name", "Country", "Latitude", "Longitude", "State",
      "State_Source", "State_Source_ID"
    ),
    "20260815 public-site state updates"
  )
  require_columns(
    site_base,
    c(
      "LTER", "Stream_Name", "Country", "State", "Latitude", "Longitude",
      "Has_Spatial_Data", "Shapefile_Name", "Discharge_File_Name",
      "canonical_row_id"
    ),
    "full spatial base"
  )

  if (!identical(nrow(old_modis), 1040L) || !identical(nrow(old_era5), 1040L)) {
    stop_with("The 20260811 baselines must each contain 1,040 rows")
  }
  if (!identical(names(old_era5)[seq_along(names(old_modis))], names(old_modis))) {
    stop_with("The ERA5-Land baseline does not begin with the MODIS baseline schema")
  }
  if (ncol(old_modis) != 1864L || ncol(old_era5) != 2020L) {
    stop_with("The 20260811 baseline schemas have changed")
  }

  old_key <- site_key(old_modis$LTER, old_modis$Stream_Name)
  era_key <- site_key(old_era5$LTER, old_era5$Stream_Name)
  alias_key <- site_key(aliases$LTER, aliases$Stream_Name)
  base_key <- site_key(site_base$LTER, site_base$Stream_Name)
  update_key <- site_key(updates$LTER, updates$Stream_Name)
  state_key <- site_key(state_updates$LTER, state_updates$Stream_Name)
  if (
    anyDuplicated(old_key) || anyDuplicated(era_key) || anyDuplicated(alias_key) ||
      anyDuplicated(base_key) || anyDuplicated(update_key) || anyDuplicated(state_key)
  ) {
    stop_with("A release input contains duplicate LTER and Stream_Name keys")
  }
  if (!identical(old_key, era_key)) {
    stop_with("The two 20260811 baselines do not have the same row order")
  }
  if (!all(old_key %in% alias_key) || !all(alias_key %in% base_key)) {
    stop_with("The baseline, alias, and full-base row sets do not nest correctly")
  }

  new_aliases <- aliases[!alias_key %in% old_key, , drop = FALSE]
  new_aliases <- new_aliases[match(
    base_key[base_key %in% site_key(new_aliases$LTER, new_aliases$Stream_Name)],
    site_key(new_aliases$LTER, new_aliases$Stream_Name)
  ), , drop = FALSE]
  new_key <- site_key(new_aliases$LTER, new_aliases$Stream_Name)
  new_site_ids <- unique(new_aliases$site_id)
  if (
    nrow(aliases) != 1196L || nrow(new_aliases) != 156L ||
      length(new_site_ids) != 151L || nrow(updates) != 66L
  ) {
    stop_with("The assembly scope is not 1,196 rows, 156 new aliases, 151 sites, and 66 replacements")
  }
  if (!all(update_key %in% new_key)) {
    stop_with("A watershed replacement is not part of the 156 new alias rows")
  }
  if (!all(as.integer(new_aliases$Spatial_Data_Version) == 3L)) {
    stop_with("Every appended alias must use spatial data release 3")
  }

  replacement <- st_drop_geometry(st_read(settings$replacement_watersheds, quiet = TRUE))
  remaining <- st_drop_geometry(st_read(settings$remaining_watersheds, quiet = TRUE))
  require_columns(replacement, "site_id", "66 replacement watersheds")
  require_columns(remaining, "site_id", "85 remaining watersheds")
  if (
    nrow(replacement) != 66L || nrow(remaining) != 85L ||
      anyDuplicated(replacement$site_id) || anyDuplicated(remaining$site_id) ||
      length(intersect(replacement$site_id, remaining$site_id))
  ) {
    stop_with("The two watershed sets are not a distinct 66 plus 85 split")
  }
  geometry <- rbind(replacement, remaining)
  if (!setequal(geometry$site_id, new_site_ids)) {
    stop_with("The 151 watershed IDs do not match the 156 appended aliases")
  }
  geometry <- geometry[match(new_site_ids, geometry$site_id), , drop = FALSE]

  base_rows <- site_base[match(new_key, base_key), , drop = FALSE]
  if (any(is.na(base_rows$LTER))) {
    stop_with("The full spatial base is missing one or more appended aliases")
  }
  if (anyDuplicated(base_rows$canonical_row_id)) {
    stop_with("The appended row IDs are not unique")
  }
  public_key <- new_key[new_aliases$LTER != "Guadeloupe"]
  if (nrow(state_updates) != 154L || !setequal(state_key, public_key)) {
    stop_with("The state updates do not match the 154 public-site aliases")
  }
  required_state_values <- c("Country", "State", "State_Source", "State_Source_ID")
  if (any(vapply(required_state_values, function(column) {
    value <- state_updates[[column]]
    is.na(value) | !nzchar(trimws(as.character(value)))
  }, logical(nrow(state_updates))))) {
    stop_with("A public-site state update is missing a country, state, source, or source ID")
  }
  state_latitude <- suppressWarnings(as.numeric(state_updates$Latitude))
  state_longitude <- suppressWarnings(as.numeric(state_updates$Longitude))
  if (
    any(!is.finite(state_latitude) | state_latitude < -90 | state_latitude > 90) ||
      any(!is.finite(state_longitude) | state_longitude < -180 | state_longitude > 180)
  ) {
    stop_with("A public-site state update has an invalid coordinate")
  }
  base_state_rows <- base_rows[match(state_key, new_key), , drop = FALSE]
  coordinate_change <-
    abs(suppressWarnings(as.numeric(base_state_rows$Latitude)) - state_latitude) > 1e-10 |
    abs(suppressWarnings(as.numeric(base_state_rows$Longitude)) - state_longitude) > 1e-10
  limmat_key <- site_key("Switzerland_CAMELS_CH", "Limmat at Gebenstorf")
  if (sum(coordinate_change) != 1L || state_key[coordinate_change] != limmat_key) {
    stop_with("The staged public metadata must contain only the supported Limmat coordinate correction")
  }
  changed_country <- trimws(as.character(base_state_rows$Country)) !=
    trimws(as.character(state_updates$Country))
  weil_key <- site_key(
    "Switzerland_CAMELS_CH",
    "Rhein at Weil, Palmrainbrucke"
  )
  if (
    sum(changed_country) != 1L || state_key[changed_country] != weil_key ||
      trimws(as.character(base_state_rows$Country[changed_country])) != "Switzerland" ||
      trimws(as.character(state_updates$Country[changed_country])) != "Germany" ||
      trimws(as.character(state_updates$State[changed_country])) != "Baden-Württemberg"
  ) {
    stop_with("The staged public metadata must contain only the supported Weil country correction")
  }

  discharge_updates <- read_discharge_updates(
    settings$discharge_updates,
    old_key,
    new_key,
    site_reference_path
  )

  list(
    old_modis = old_modis,
    old_era5 = old_era5,
    aliases = aliases,
    new_aliases = new_aliases,
    updates = updates,
    state_updates = state_updates,
    discharge_updates = discharge_updates,
    base_rows = base_rows,
    geometry = geometry,
    new_site_ids = new_site_ids
  )
}


### New-row base

prepare_new_base <- function(scope) {
  base <- scope$base_rows
  aliases <- scope$new_aliases
  updates <- scope$updates
  state_updates <- scope$state_updates
  key <- site_key(base$LTER, base$Stream_Name)
  alias_key <- site_key(aliases$LTER, aliases$Stream_Name)
  base <- base[match(alias_key, key), , drop = FALSE]

  update_key <- site_key(updates$LTER, updates$Stream_Name)
  row_index <- match(update_key, alias_key)
  new_columns <- grep("_new$", names(updates), value = TRUE)
  for (source_column in new_columns) {
    target_column <- sub("_new$", "", source_column)
    if (target_column %in% names(base)) {
      base[[target_column]][row_index] <- cast_like(
        updates[[source_column]],
        base[[target_column]],
        target_column
      )
    }
  }
  base$LTER <- aliases$LTER
  base$Stream_Name <- aliases$Stream_Name
  base$Shapefile_Name <- aliases$Shapefile_Name
  base$Spatial_Data_Version <- cast_like(
    aliases$Spatial_Data_Version,
    base$Spatial_Data_Version,
    "Spatial_Data_Version"
  )

  state_key <- site_key(state_updates$LTER, state_updates$Stream_Name)
  state_index <- match(alias_key, state_key)
  public_rows <- !is.na(state_index)
  if (sum(public_rows) != 154L) {
    stop_with("The public-site metadata updates were not matched exactly once")
  }
  for (column in c("Country", "State", "Latitude", "Longitude")) {
    base[[column]][public_rows] <- cast_like(
      state_updates[[column]][state_index[public_rows]],
      base[[column]],
      column
    )
  }
  proposed_country <- trimws(as.character(state_updates$Country[state_index[public_rows]]))
  applied_country <- trimws(as.character(base$Country[public_rows]))
  if (!identical(applied_country, proposed_country)) {
    stop_with("A staged public-site country update was not applied")
  }

  replacement_rows <- site_key(base$LTER, base$Stream_Name) %in% update_key
  old_boundary_columns <- grep(
    paste0(
      "^(temp_|precip_|elevation_|basin_slope_|major_rock$|rocks_|",
      "permafrost_|major_soil$|soil_)"
    ),
    names(base),
    value = TRUE
  )
  prior_aurora_values <- base[, old_boundary_columns, drop = FALSE]
  for (column in old_boundary_columns) base[[column]][replacement_rows] <- NA

  if (sum(replacement_rows) != 66L) {
    stop_with("The 66 replacement rows were not applied exactly once")
  }
  if (any(row_has_value(base[replacement_rows, old_boundary_columns, drop = FALSE]))) {
    stop_with("Pre-fix Aurora values remain on a replacement boundary")
  }
  list(
    data = base,
    replacement_rows = replacement_rows,
    old_boundary_columns = old_boundary_columns,
    prior_aurora_values = prior_aurora_values
  )
}


### Aurora boundary patches

numeric_patch <- function(data, columns, label) {
  output <- data[, columns, drop = FALSE]
  for (column in columns) {
    text <- trimws(as.character(output[[column]]))
    text[is.na(output[[column]]) | text == ""] <- NA_character_
    value <- suppressWarnings(as.numeric(text))
    if (any(!is.na(text) & is.na(value))) {
      stop_with(label, " contains a nonnumeric value in ", column)
    }
    output[[column]] <- value
  }
  output
}

check_numeric_range <- function(data, columns, lower, upper, label, complete = TRUE) {
  values <- as.matrix(data[, columns, drop = FALSE])
  if ((complete && any(!is.finite(values))) ||
      any(is.finite(values) & (values < lower | values > upper))) {
    stop_with(label, " values exceed their allowed range")
  }
  invisible(values)
}

check_summary_order <- function(data, columns, label, rows = rep(TRUE, nrow(data))) {
  values <- data[rows, columns, drop = FALSE]
  if (any(values[[1L]] > values[[2L]] | values[[2L]] > values[[4L]] |
          values[[1L]] > values[[3L]] | values[[3L]] > values[[4L]])) {
    stop_with(label, " summaries violate their expected order")
  }
  invisible(data)
}

check_fraction_family <- function(data, major_column, fraction_columns, label) {
  values <- numeric_patch(data, fraction_columns, label)
  numeric <- as.matrix(values)
  if (any(is.finite(numeric) & (numeric < 0 | numeric > 100))) {
    stop_with(label, " percentages fall outside zero to 100")
  }
  totals <- rowSums(numeric, na.rm = TRUE)
  has_fraction <- rowSums(is.finite(numeric)) > 0L
  if (any(has_fraction & abs(totals - 100) > 1e-5)) {
    stop_with(label, " percentage totals fail closure checks")
  }
  allowed <- sub(
    paste0("^", if (major_column == "major_rock") "rocks_" else "soil_"),
    "",
    fraction_columns
  )
  major <- trimws(as.character(data[[major_column]]))
  major[is.na(data[[major_column]])] <- ""
  has_major <- nzchar(major)
  if (any(has_fraction != has_major)) {
    stop_with(label, " major class and percentage coverage disagree")
  }
  tokens <- trimws(unlist(strsplit(major[nzchar(major)], ";", fixed = TRUE)))
  if (length(setdiff(tokens, allowed))) {
    stop_with(label, " contains an unknown major class")
  }
  data[fraction_columns] <- values
  attr(data, "no_coverage_rows") <- sum(!has_fraction)
  data
}

build_aurora_values <- function(files, scope, new_base, output_columns) {
  key_columns <- c(
    "LTER", "Shapefile_Name", "Discharge_File_Name", "Stream_Name"
  )
  fields <- list(
    air_temp = grep("^temp_", output_columns, value = TRUE),
    precip = grep("^precip_", output_columns, value = TRUE),
    elevation = grep("^(elevation_|basin_slope_)", output_columns, value = TRUE),
    lithology = grep("^(major_rock$|rocks_)", output_columns, value = TRUE),
    permafrost = grep("^permafrost_", output_columns, value = TRUE),
    soil = grep("^(major_soil$|soil_)", output_columns, value = TRUE)
  )
  expected_counts <- c(
    air_temp = 90L,
    precip = 59L,
    elevation = 8L,
    lithology = 6L,
    permafrost = 4L,
    soil = 13L
  )
  actual_counts <- vapply(fields, length, integer(1))
  if (!identical(actual_counts, expected_counts)) {
    stop_with("The released Aurora field groups do not match the expected 180 fields")
  }

  aliases <- scope$new_aliases
  alias_key <- site_key(aliases$LTER, aliases$Stream_Name)
  replacement_key <- site_key(scope$updates$LTER, scope$updates$Stream_Name)
  target_rows <- alias_key %in% replacement_key | aliases$LTER == "Guadeloupe"
  target_key <- alias_key[target_rows]
  if (sum(target_rows) != 68L || anyDuplicated(target_key)) {
    stop_with("The Aurora patch target is not 66 replacements plus two Guadeloupe rows")
  }
  expected_shapes <- trimws(as.character(aliases$Shapefile_Name[target_rows]))
  expected_discharge <- trimws(as.character(new_base$data$Discharge_File_Name[target_rows]))
  expected_discharge[is.na(expected_discharge)] <- ""

  values <- list()
  no_coverage <- setNames(integer(length(fields)), names(fields))
  for (family in names(fields)) {
    data <- read_csv(files[[family]], all_character = TRUE)
    family_fields <- fields[[family]]
    require_columns(data, c(key_columns, family_fields), paste(family, "Aurora patch"))
    if (
      anyDuplicated(names(data)) ||
        ncol(data) != length(key_columns) + expected_counts[[family]] ||
        !setequal(names(data), c(key_columns, family_fields))
    ) {
      stop_with(family, " Aurora patch does not have its exact released schema")
    }
    key <- site_key(data$LTER, data$Stream_Name)
    if (nrow(data) != 68L || anyDuplicated(key) || !setequal(key, target_key)) {
      stop_with(family, " Aurora patch does not have the exact 68 target keys")
    }
    data <- data[match(target_key, key), , drop = FALSE]
    if (!identical(trimws(as.character(data$Shapefile_Name)), expected_shapes)) {
      stop_with(family, " Aurora patch has a mismatched Shapefile_Name")
    }
    discharge <- trimws(as.character(data$Discharge_File_Name))
    discharge[is.na(discharge)] <- ""
    if (!identical(discharge, expected_discharge)) {
      stop_with(family, " Aurora patch has a mismatched Discharge_File_Name")
    }

    if (family %in% c("air_temp", "precip", "elevation")) {
      data[family_fields] <- numeric_patch(data, family_fields, family)
    }
    if (family == "air_temp") {
      check_numeric_range(data, family_fields, -90, 60, "Air temperature")
    }
    if (family == "precip") {
      check_numeric_range(data, family_fields, 0, 1000, "Precipitation")
    }
    if (family == "elevation") {
      check_numeric_range(data, grep("^elevation_", family_fields, value = TRUE),
                          -500, 9000, "Elevation")
      check_numeric_range(data, grep("^basin_slope_", family_fields, value = TRUE),
                          0, 90, "Basin slope")
      check_summary_order(data, c("elevation_min_m", "elevation_median_m",
                                  "elevation_mean_m", "elevation_max_m"), "Elevation")
      check_summary_order(data, c("basin_slope_min_degree", "basin_slope_median_degree",
                                  "basin_slope_mean_degree", "basin_slope_max_degree"),
                          "Basin slope")
    }
    if (family == "lithology") {
      data <- check_fraction_family(
        data,
        "major_rock",
        setdiff(family_fields, "major_rock"),
        "Lithology"
      )
    }
    if (family == "soil") {
      data <- check_fraction_family(
        data,
        "major_soil",
        setdiff(family_fields, "major_soil"),
        "Soil"
      )
    }
    if (family == "permafrost") {
      data[family_fields] <- numeric_patch(data, family_fields, "Permafrost")
      numeric <- as.matrix(data[family_fields])
      check_numeric_range(data, family_fields, 0, 1, "Permafrost", complete = FALSE)
      complete <- rowSums(is.finite(numeric)) == length(family_fields)
      check_summary_order(data, c("permafrost_min_m", "permafrost_median_m",
                                  "permafrost_mean_m", "permafrost_max_m"),
                          "Permafrost", complete)
      no_coverage[[family]] <- sum(rowSums(is.finite(numeric)) == 0L)
    }
    if (family %in% c("lithology", "soil")) {
      no_coverage[[family]] <- attr(data, "no_coverage_rows")
    }
    values[[family]] <- data[, family_fields, drop = FALSE]
  }
  list(
    values = values,
    fields = fields,
    target_rows = target_rows,
    no_coverage = no_coverage
  )
}

apply_aurora_values <- function(new_base, aurora) {
  for (family in names(aurora$values)) {
    columns <- aurora$fields[[family]]
    for (column in columns) {
      new_base$data[[column]][aurora$target_rows] <- cast_like(
        aurora$values[[family]][[column]],
        new_base$data[[column]],
        column
      )
    }
  }
  new_base$aurora_target_rows <- aurora$target_rows
  new_base$aurora_fields <- unique(unlist(aurora$fields, use.names = FALSE))
  if (length(new_base$aurora_fields) != 180L) {
    stop_with("The Aurora patches did not cover all 180 released fields")
  }
  if (!setequal(new_base$aurora_fields, new_base$old_boundary_columns)) {
    stop_with("The Aurora patch fields do not match the 180 boundary-dependent fields")
  }
  if (!identical(
    new_base$data[!aurora$target_rows, new_base$aurora_fields, drop = FALSE],
    new_base$prior_aurora_values[
      !aurora$target_rows,
      new_base$aurora_fields,
      drop = FALSE
    ]
  )) {
    stop_with("An Aurora value changed outside the 68 patch targets")
  }
  for (family in names(aurora$values)) {
    for (column in aurora$fields[[family]]) {
      expected <- cast_like(
        aurora$values[[family]][[column]],
        new_base$data[[column]],
        column
      )
      if (!identical(
        unname(new_base$data[[column]][aurora$target_rows]),
        unname(expected)
      )) {
        stop_with("An Aurora patch value was not reproduced in ", column)
      }
    }
  }
  new_base
}


### GLC land cover

build_glc_values <- function(raw, crosswalk_path, site_ids, output_columns) {
  require_columns(raw, c("site_id", "Year", "LC_ID", "Area_m2"), "GLC replacement data")
  crosswalk <- read_csv(crosswalk_path, all_character = TRUE)
  require_columns(crosswalk, c("LC_ID", "Simple_Class"), "GLC class crosswalk")
  if (nrow(crosswalk) != 37L || anyDuplicated(crosswalk$LC_ID)) {
    stop_with("The GLC class crosswalk must contain 37 unique IDs")
  }

  raw$site_id <- trimws(raw$site_id)
  raw$Year <- suppressWarnings(as.integer(raw$Year))
  raw$LC_ID <- trimws(raw$LC_ID)
  raw$Area_m2 <- suppressWarnings(as.numeric(raw$Area_m2))
  anchor_years <- c(1985L, 1990L, 1995L, 2000:2022)
  expected_key <- expand.grid(
    site_id = site_ids,
    Year = anchor_years,
    LC_ID = crosswalk$LC_ID,
    stringsAsFactors = FALSE
  )
  key <- paste(raw$site_id, raw$Year, raw$LC_ID, sep = "\r")
  expected_key <- paste(
    expected_key$site_id, expected_key$Year, expected_key$LC_ID,
    sep = "\r"
  )
  if (
    any(!is.finite(raw$Area_m2) | raw$Area_m2 < 0) || anyDuplicated(key) ||
      !setequal(key, expected_key)
  ) {
    stop_with("GLC rows do not form the complete 151-site, 26-year, 37-class grid")
  }
  raw <- raw[match(expected_key, key), , drop = FALSE]
  raw$Simple_Class <- crosswalk$Simple_Class[match(raw$LC_ID, crosswalk$LC_ID)]
  if (any(is.na(raw$Simple_Class))) stop_with("An extracted GLC class is not mapped")

  total <- aggregate(Area_m2 ~ site_id + Year, raw, sum)
  names(total)[[3]] <- "total_area_m2"
  total_key <- paste(total$site_id, total$Year, sep = "\r")
  raw_total <- total$total_area_m2[match(
    paste(raw$site_id, raw$Year, sep = "\r"),
    total_key
  )]
  if (any(!is.finite(raw_total) | raw_total <= 0)) {
    stop_with("A GLC site-year has zero or missing area")
  }
  if ("polygon_area_m2" %in% names(raw)) {
    polygon <- suppressWarnings(as.numeric(raw$polygon_area_m2))
    closure <- abs(raw_total - polygon) / polygon
    if (any(!is.finite(closure) | closure > 0.011)) {
      stop_with("A GLC site-year fails the area-closure check")
    }
  }

  grouped <- aggregate(
    Area_m2 ~ site_id + Year + Simple_Class,
    raw,
    sum
  )
  grouped$proportion <- grouped$Area_m2 / total$total_area_m2[match(
    paste(grouped$site_id, grouped$Year, sep = "\r"),
    total_key
  )]

  glc_columns <- grep("^gee_glc_[0-9]{4}_", output_columns, value = TRUE)
  years <- as.integer(sub("^gee_glc_([0-9]{4})_.*$", "\\1", glc_columns))
  classes <- sub("^gee_glc_[0-9]{4}_", "", glc_columns)
  output_years <- unique(years)
  class_order <- unique(classes)
  if (
    length(glc_columns) != 1353L || !identical(output_years, 1900:2022) ||
      length(class_order) != 11L
  ) {
    stop_with("The released GLC output schema is not 1900:2022 by 11 classes")
  }
  if (!setequal(unique(grouped$Simple_Class), class_order)) {
    stop_with("The GLC simple classes do not match the released schema")
  }

  anchors <- array(
    0,
    dim = c(length(site_ids), length(anchor_years), length(class_order)),
    dimnames = list(site_ids, anchor_years, class_order)
  )
  grouped_index <- cbind(
    match(grouped$site_id, site_ids),
    match(grouped$Year, anchor_years),
    match(grouped$Simple_Class, class_order)
  )
  anchors[grouped_index] <- grouped$proportion
  if (max(abs(apply(anchors, c(1, 2), sum) - 1)) > 1e-10) {
    stop_with("GLC anchor-year proportions do not sum to one")
  }

  values <- matrix(
    NA_real_,
    nrow = length(site_ids),
    ncol = length(glc_columns),
    dimnames = list(site_ids, glc_columns)
  )
  for (site_index in seq_along(site_ids)) {
    annual <- matrix(
      NA_real_,
      nrow = length(output_years),
      ncol = length(class_order)
    )
    for (class_index in seq_along(class_order)) {
      annual[, class_index] <- approx(
        anchor_years,
        anchors[site_index, , class_index],
        xout = output_years,
        rule = 2
      )$y
    }
    values[site_index, ] <- as.vector(t(annual))
  }
  if (
    any(!is.finite(values) | values < -1e-10 | values > 1 + 1e-10) ||
      max(abs(rowSums(array(
        values,
        dim = c(length(site_ids), length(class_order), length(output_years))
      ), dims = 1L) - length(output_years))) > 1e-7
  ) {
    stop_with("Interpolated GLC values fail range or closure checks")
  }
  as.data.frame(values, stringsAsFactors = FALSE, check.names = FALSE)
}


### MODIS products

resolve_modis_site_ids <- function(data, geometry, label) {
  if ("site_id" %in% names(data) && all(nzchar(trimws(data$site_id)))) {
    return(trimws(data$site_id))
  }
  require_columns(data, "Shapefile_Name", paste(label, "MODIS data"))
  geometry_shape <- shape_key(geometry$Shapefile_Name)
  if (anyDuplicated(geometry_shape)) {
    stop_with("The 151 MODIS target shapes are not unique")
  }
  output <- geometry$site_id[match(shape_key(data$Shapefile_Name), geometry_shape)]
  if (any(is.na(output))) stop_with(label, " MODIS rows do not match the 151 shapes")
  output
}

build_modis_values <- function(files, geometry, site_ids, output_columns) {
  product_patterns <- c(
    evapo = "^evapotrans_",
    greenup = "^greenup_",
    npp = "^npp_",
    snow = "^snow_"
  )
  expected_counts <- c(evapo = 37L, greenup = 48L, npp = 25L, snow = 72L)
  output <- list()
  for (product in names(product_patterns)) {
    if (length(files[[product]]) != 1L) {
      stop_with("Expected one consolidated MODIS ", product, " file")
    }
    data <- read_csv(files[[product]], all_character = TRUE)
    ids <- resolve_modis_site_ids(data, geometry, product)
    value_columns <- grep(product_patterns[[product]], output_columns, value = TRUE)
    require_columns(data, value_columns, paste(product, "MODIS data"))
    if (
      length(value_columns) != expected_counts[[product]] || nrow(data) != 151L ||
        anyDuplicated(ids) || !setequal(ids, site_ids)
    ) {
      stop_with(product, " MODIS data do not match the released field and site counts")
    }
    data <- data[match(site_ids, ids), value_columns, drop = FALSE]
    if (product == "greenup") {
      for (column in value_columns) {
        present_text <- !is.na(data[[column]]) &
          nzchar(trimws(as.character(data[[column]])))
        value <- as.Date(data[[column]])
        if (any(present_text & is.na(value))) {
          stop_with("An invalid greenup date occurs in ", column)
        }
        year <- as.integer(sub("^greenup_cycle[01]_([0-9]{4})MMDD$", "\\1", column))
        present <- !is.na(value)
        if (any(
          value[present] < as.Date(sprintf("%d-01-01", year - 1L)) |
            value[present] > as.Date(sprintf("%d-12-31", year + 1L))
        )) {
          stop_with("A greenup date is outside its product-year window: ", column)
        }
        data[[column]] <- as.character(value)
      }
    } else {
      present_text <- lapply(data, function(value) {
        !is.na(value) & nzchar(trimws(as.character(value)))
      })
      data[] <- lapply(data, function(value) suppressWarnings(as.numeric(value)))
      invalid <- vapply(seq_along(data), function(index) {
        any(present_text[[index]] & !is.finite(data[[index]]))
      }, logical(1))
      if (any(invalid)) {
        stop_with(product, " MODIS data contain an invalid numeric value")
      }
      values <- unlist(data, use.names = FALSE)
      finite_values <- values[is.finite(values)]
      if (!length(finite_values)) stop_with(product, " MODIS data contain no values")
      if (
        product == "npp" &&
          any(finite_values < -3 - 1e-8 | finite_values > 3.27 + 1e-8)
      ) {
        stop_with("MODIS NPP exceeds its physical range")
      }
      if (product == "snow") {
        prop <- unlist(data[grep("(max_prop_area|avg_prop_area)$", names(data))])
        days <- unlist(data[grep("_num_days$", names(data))])
        prop <- prop[is.finite(prop)]
        days <- days[is.finite(days)]
        if (
          !length(prop) || !length(days) ||
            any(prop < 0 | prop > 1) || any(days < 0 | days > 368)
        ) {
          stop_with("MODIS snow values exceed their physical ranges")
        }
      }
    }
    output[[product]] <- data
  }
  output
}


### Human impacts

build_human_values <- function(raw, site_ids, output_columns) {
  require_columns(
    raw,
    c("site_id", "human_impact_dataset", "year"),
    "human-impact replacement data"
  )
  raw$site_id <- trimws(raw$site_id)
  raw$human_impact_dataset <- trimws(raw$human_impact_dataset)
  raw$year <- suppressWarnings(as.integer(raw$year))
  key <- paste(
    raw$site_id,
    raw$human_impact_dataset,
    ifelse(is.na(raw$year), "static", raw$year),
    sep = "\r"
  )
  expected <- rbind(
    expand.grid(
      site_id = site_ids,
      dataset = c("dams", "fertilizer", "wastewater"),
      period = "static",
      stringsAsFactors = FALSE
    ),
    expand.grid(
      site_id = site_ids,
      dataset = "population",
      period = as.character(2000:2024),
      stringsAsFactors = FALSE
    )
  )
  expected_key <- paste(expected$site_id, expected$dataset, expected$period, sep = "\r")
  if (anyDuplicated(key) || !setequal(key, expected_key)) {
    stop_with("Human-impact rows do not form the complete 151-site by 28-period grid")
  }

  human_columns <- grep("^human_", output_columns, value = TRUE)
  annual_columns <- grep(
    "^human_population_(density_people_km2|total_people|data_coverage_fraction)_[0-9]{4}$",
    human_columns,
    value = TRUE
  )
  static_columns <- setdiff(human_columns, annual_columns)
  if (length(human_columns) != 97L || length(static_columns) != 22L) {
    stop_with("The released human-impact schema is not 22 static plus 75 annual fields")
  }
  raw_static <- sub("^human_", "", static_columns)
  raw_annual <- sub(
    "^human_(population_(density_people_km2|total_people|data_coverage_fraction))_[0-9]{4}$",
    "\\1",
    annual_columns
  )
  require_columns(raw, unique(c(raw_static, raw_annual)), "human-impact replacement data")

  values <- matrix(
    NA_real_,
    nrow = length(site_ids),
    ncol = length(human_columns),
    dimnames = list(site_ids, human_columns)
  )
  for (column in static_columns) {
    raw_column <- sub("^human_", "", column)
    values[, column] <- vapply(site_ids, function(site_id) {
      first_numeric(raw[[raw_column]][raw$site_id == site_id], paste(site_id, raw_column))
    }, numeric(1))
  }
  for (column in annual_columns) {
    year <- as.integer(sub(".*_([0-9]{4})$", "\\1", column))
    raw_column <- sub(
      "^human_(population_(density_people_km2|total_people|data_coverage_fraction))_[0-9]{4}$",
      "\\1",
      column
    )
    values[, column] <- vapply(site_ids, function(site_id) {
      keep <- raw$site_id == site_id & raw$human_impact_dataset == "population" &
        raw$year == year
      first_numeric(raw[[raw_column]][keep], paste(site_id, raw_column, year))
    }, numeric(1))
  }
  coverage <- values[, grep("data_coverage_fraction", colnames(values)), drop = FALSE]
  if (
    any(!is.finite(values)) || any(values < 0) ||
      any(coverage < 0 | coverage > 1)
  ) {
    stop_with("Human-impact values fail completeness or physical-range checks")
  }
  as.data.frame(values, stringsAsFactors = FALSE, check.names = FALSE)
}


### ERA5-Land

build_era5_values <- function(raw, site_ids, output_columns) {
  metrics <- c(
    "precip_mm", "temp_degC", "evapotrans_mm", "potential_evap_mm",
    "snow_cover_fraction", "snow_water_equiv_mm"
  )
  require_columns(raw, c("site_id", "year", metrics), "ERA5-Land replacement data")
  raw$site_id <- trimws(raw$site_id)
  raw$year <- suppressWarnings(as.integer(raw$year))
  key <- paste(raw$site_id, raw$year, sep = "\r")
  expected <- expand.grid(site_id = site_ids, year = 2000:2025, stringsAsFactors = FALSE)
  expected_key <- paste(expected$site_id, expected$year, sep = "\r")
  if (anyDuplicated(key) || !setequal(key, expected_key)) {
    stop_with("ERA5-Land rows do not form the complete 151-site by 26-year grid")
  }
  raw <- raw[match(expected_key, key), , drop = FALSE]
  raw[metrics] <- lapply(raw[metrics], function(value) suppressWarnings(as.numeric(value)))
  if (any(!is.finite(as.matrix(raw[metrics])))) {
    stop_with("ERA5-Land contains a missing or non-finite value")
  }
  if (
    any(raw$precip_mm < 0) || any(raw$evapotrans_mm < 0) ||
      any(raw$potential_evap_mm < 0) ||
      any(raw$temp_degC < -90 | raw$temp_degC > 60) ||
      any(raw$snow_cover_fraction < 0 | raw$snow_cover_fraction > 1) ||
      any(raw$snow_water_equiv_mm < 0)
  ) {
    stop_with("ERA5-Land values exceed their physical ranges")
  }

  era_columns <- grep("^era5_land_", output_columns, value = TRUE)
  if (length(era_columns) != 156L) {
    stop_with("The released ERA5-Land schema does not contain 156 fields")
  }
  values <- matrix(
    NA_real_,
    nrow = length(site_ids),
    ncol = length(era_columns),
    dimnames = list(site_ids, era_columns)
  )
  for (column in era_columns) {
    year <- as.integer(sub(".*_([0-9]{4})$", "\\1", column))
    metric <- sub("^era5_land_(.*)_[0-9]{4}$", "\\1", column)
    if (!metric %in% metrics) stop_with("Unknown ERA5-Land output field: ", column)
    rows <- raw$year == year
    values[, column] <- raw[[metric]][rows][match(site_ids, raw$site_id[rows])]
  }
  if (any(!is.finite(values))) stop_with("ERA5-Land wide values are incomplete")
  as.data.frame(values, stringsAsFactors = FALSE, check.names = FALSE)
}


### Geometry metadata

build_geometry_values <- function(scope, old_modis) {
  geometry <- scope$geometry
  aliases <- scope$new_aliases
  site_ids <- scope$new_site_ids
  require_columns(
    geometry,
    c(
      "site_id", "expected_area_km2", "polygon_area_km2",
      "Spatial_Data_Version"
    ),
    "release-three watersheds"
  )
  geometry <- geometry[match(site_ids, geometry$site_id), , drop = FALSE]
  expected <- suppressWarnings(as.numeric(geometry$expected_area_km2))
  polygon <- suppressWarnings(as.numeric(geometry$polygon_area_km2))
  if (any(!is.finite(expected) | expected <= 0 | !is.finite(polygon) | polygon <= 0)) {
    stop_with("A release-three watershed has invalid area metadata")
  }
  difference <- 100 * (polygon - expected) / expected

  old_numbers <- suppressWarnings(as.integer(sub(
    "^ws_", "", unique(old_modis$gee_watershed_id)
  )))
  if (any(!is.finite(old_numbers))) stop_with("The old watershed IDs are not ws_ numbers")
  watershed_ids <- sprintf("ws_%04d", max(old_numbers) + seq_along(site_ids))
  alias_count <- as.integer(table(factor(aliases$site_id, levels = site_ids)))
  status <- ifelse(
    abs(difference) <= 15,
    "within 15 percent",
    "unresolved mismatch"
  )
  if (any(status == "unresolved mismatch")) {
    stop_with("A release-three watershed differs from its reference area by more than 15 percent")
  }
  data.frame(
    site_id = site_ids,
    gee_watershed_id = watershed_ids,
    gee_polygon_area_km2 = polygon,
    gee_expected_area_km2 = expected,
    gee_area_percent_difference = difference,
    gee_area_qa_status = status,
    gee_spatial_release = suppressWarnings(as.integer(geometry$Spatial_Data_Version)),
    gee_canonical_site_count = alias_count,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}


### Discharge metadata

apply_discharge_updates <- function(modis, era5, scope) {
  fields <- c(
    "Discharge_File_Name", "Units", "Discharge_Site_Name", "Use_WRTDS"
  )
  require_columns(modis, c("LTER", "Stream_Name", "Latitude", "Longitude", fields),
    "MODIS release rows")
  require_columns(era5, c("LTER", "Stream_Name", "Latitude", "Longitude", fields),
    "ERA5-Land release rows")
  modis_key <- site_key(modis$LTER, modis$Stream_Name)
  era5_key <- site_key(era5$LTER, era5$Stream_Name)
  if (anyDuplicated(modis_key) || !identical(modis_key, era5_key)) {
    stop_with("The release rows are not ready for discharge metadata matching")
  }

  updates <- scope$discharge_updates
  keep <- normalized_text(updates$Spatial_Release_Match) == "Yes"
  updates <- updates[keep, , drop = FALSE]
  update_key <- site_key(updates$Spatial_LTER, updates$Stream_Name)
  rows <- match(update_key, modis_key)
  if (
    nrow(updates) != 178L || any(is.na(rows)) || anyDuplicated(rows) ||
      sum(rows <= 1040L) != 173L || sum(rows > 1040L) != 5L
  ) {
    stop_with("The staged discharge updates did not match the exact spatial rows")
  }

  current_file <- normalized_text(modis$Discharge_File_Name[rows])
  current_units <- normalized_text(modis$Units[rows])
  current_name <- normalized_text(modis$Discharge_Site_Name[rows])
  current_wrtds <- normalized_text(modis$Use_WRTDS[rows])
  target_file <- normalized_text(updates$Discharge_File_Name)
  target_units <- normalized_text(updates$Units)
  target_name <- normalized_text(updates$Discharge_Site_Name)
  target_wrtds <- normalized_text(updates$Use_WRTDS_for_release)
  proposed_wrtds <- normalized_text(updates$Proposed_Use_WRTDS)

  file_change <- current_file != target_file
  units_change <- current_units != target_units
  name_change <- current_name != target_name
  wrtds_change <- current_wrtds != target_wrtds
  proposed_wrtds_change <- current_wrtds != proposed_wrtds
  baseline <- rows <= 1040L
  held <- proposed_wrtds == "Yes" & target_wrtds == "No"
  if (
    sum(file_change) != 178L || sum(file_change & baseline) != 173L ||
      sum(!nzchar(current_file)) != 177L ||
      sum(units_change) != 178L || sum(units_change & baseline) != 173L ||
      any(nzchar(current_units)) || any(target_units != "cms") ||
      sum(name_change) != 177L || sum(name_change & baseline) != 172L ||
      any(nzchar(current_name)) || sum(nzchar(target_name)) != 177L ||
      sum(wrtds_change) != 109L || sum(wrtds_change & baseline) != 109L ||
      sum(proposed_wrtds_change) != 112L || sum(held) != 3L ||
      any(current_wrtds[held] != "No") ||
      any(current_wrtds[wrtds_change] != "") ||
      any(target_wrtds[wrtds_change] != "No")
  ) {
    stop_with("The staged discharge metadata changes differ from the reviewed counts")
  }
  blank_name <- !nzchar(target_name)
  if (
    sum(blank_name) != 1L ||
      updates$Spatial_LTER[blank_name] != "ColoradoAlpine" ||
      updates$Stream_Name[blank_name] != "andrewscreek"
  ) {
    stop_with("The single unresolved discharge station name changed")
  }

  chemistry_latitude <- suppressWarnings(as.numeric(updates$Chemistry_Latitude))
  chemistry_longitude <- suppressWarnings(as.numeric(updates$Chemistry_Longitude))
  modis_latitude <- suppressWarnings(as.numeric(modis$Latitude[rows]))
  modis_longitude <- suppressWarnings(as.numeric(modis$Longitude[rows]))
  era5_latitude <- suppressWarnings(as.numeric(era5$Latitude[rows]))
  era5_longitude <- suppressWarnings(as.numeric(era5$Longitude[rows]))
  if (
    any(abs(modis_latitude - chemistry_latitude) > 1e-10) ||
      any(abs(modis_longitude - chemistry_longitude) > 1e-10) ||
      any(abs(era5_latitude - chemistry_latitude) > 1e-10) ||
      any(abs(era5_longitude - chemistry_longitude) > 1e-10)
  ) {
    stop_with("A staged discharge update would change a chemistry coordinate")
  }

  discharge_latitude <- suppressWarnings(as.numeric(updates$Discharge_Latitude))
  discharge_longitude <- suppressWarnings(as.numeric(updates$Discharge_Longitude))
  pairing_distance <- suppressWarnings(as.numeric(updates$Pairing_Distance_km))
  discharge_coordinates <- is.finite(discharge_latitude) &
    is.finite(discharge_longitude)
  if (
    any(xor(is.finite(discharge_latitude), is.finite(discharge_longitude))) ||
      any(discharge_coordinates != is.finite(pairing_distance)) ||
      sum(discharge_coordinates) != 156L ||
      sum(!discharge_coordinates) != 22L ||
      any(discharge_latitude[discharge_coordinates] < -90 |
        discharge_latitude[discharge_coordinates] > 90) ||
      any(discharge_longitude[discharge_coordinates] < -180 |
        discharge_longitude[discharge_coordinates] > 180) ||
      any(pairing_distance[discharge_coordinates] < 0)
  ) {
    stop_with("The matched discharge coordinates or distances fail QA")
  }

  targets <- list(
    Discharge_File_Name = target_file,
    Units = target_units,
    Discharge_Site_Name = target_name,
    Use_WRTDS = target_wrtds
  )
  coordinates_before <- modis[c("Latitude", "Longitude")]
  for (column in fields) {
    modis[[column]][rows] <- cast_like(targets[[column]], modis[[column]], column)
    era5[[column]][rows] <- cast_like(targets[[column]], era5[[column]], column)
  }
  if (
    !identical(modis[c("Latitude", "Longitude")], coordinates_before) ||
      !identical(modis[fields], era5[fields])
  ) {
    stop_with("The discharge metadata application changed coordinates or variants disagree")
  }

  list(
    modis = modis,
    era5 = era5,
    qa = list(
      counts = c(
        staged_assignments = 183L,
        spatial_matches = 178L,
        no_spatial_matches = 5L,
        baseline_matches = 173L,
        appended_matches = 5L,
        discharge_file_changes = 178L,
        unit_changes = 178L,
        discharge_site_name_changes = 177L,
        use_wrtds_release_changes = 109L,
        use_wrtds_proposed_changes = 112L,
        provisional_yes_held_at_no = 3L,
        chemistry_coordinate_changes = 0L,
        discharge_coordinate_pairs = 156L,
        missing_discharge_coordinate_pairs = 22L
      ),
      pairing_distance_km_range = range(
        pairing_distance[discharge_coordinates]
      ),
      held_use_wrtds = data.frame(
        LTER = updates$Spatial_LTER[held],
        Stream_Name = updates$Stream_Name[held],
        proposed = proposed_wrtds[held],
        released = target_wrtds[held],
        stringsAsFactors = FALSE
      )
    )
  )
}


### Final assembly

assemble_outputs <- function(scope, new_base, drivers) {
  old_modis <- scope$old_modis
  old_era5 <- scope$old_era5
  aliases <- scope$new_aliases
  site_ids <- scope$new_site_ids
  alias_match <- match(aliases$site_id, site_ids)

  new_modis <- empty_like(old_modis, nrow(aliases))
  new_modis <- fill_columns(new_modis, new_base$data)
  new_modis$LTER <- aliases$LTER
  new_modis$Stream_Name <- aliases$Stream_Name
  new_modis$source_variant <- "MODIS and human impacts"

  geometry_alias <- drivers$geometry[alias_match, , drop = FALSE]
  new_modis <- fill_columns(
    new_modis,
    geometry_alias,
    setdiff(names(geometry_alias), "site_id")
  )
  new_modis$gee_glc_match_method <- "site_id"
  new_modis$gee_glc_match <- TRUE
  new_modis <- fill_columns(new_modis, drivers$glc[alias_match, , drop = FALSE])
  for (product in names(drivers$modis)) {
    new_modis <- fill_columns(
      new_modis,
      drivers$modis[[product]][alias_match, , drop = FALSE]
    )
  }
  new_modis <- fill_columns(new_modis, drivers$human[alias_match, , drop = FALSE])

  new_era5 <- empty_like(old_era5, nrow(aliases))
  new_era5 <- fill_columns(new_era5, new_modis, names(old_modis))
  new_era5$source_variant <- "ERA5-Land, MODIS, and human impacts"
  new_era5 <- fill_columns(new_era5, drivers$era5[alias_match, , drop = FALSE])

  modis <- rbind(old_modis, new_modis)
  era5 <- rbind(old_era5, new_era5)
  rownames(modis) <- NULL
  rownames(era5) <- NULL

  discharge <- apply_discharge_updates(modis, era5, scope)
  modis <- discharge$modis
  era5 <- discharge$era5
  allowed_metadata_changes <- c(
    "Discharge_File_Name", "Units", "Discharge_Site_Name", "Use_WRTDS"
  )
  preserved_modis <- setdiff(names(old_modis), allowed_metadata_changes)
  preserved_era5 <- setdiff(names(old_era5), allowed_metadata_changes)
  if (!identical(
    modis[seq_len(nrow(old_modis)), preserved_modis, drop = FALSE],
    old_modis[, preserved_modis, drop = FALSE]
  )) {
    stop_with("A non-discharge value changed in the existing MODIS rows")
  }
  if (!identical(
    era5[seq_len(nrow(old_era5)), preserved_era5, drop = FALSE],
    old_era5[, preserved_era5, drop = FALSE]
  )) {
    stop_with("A non-discharge value changed in the existing ERA5-Land rows")
  }
  if (
    nrow(modis) != 1196L || nrow(era5) != 1196L ||
      !identical(names(modis), names(old_modis)) ||
      !identical(names(era5), names(old_era5))
  ) {
    stop_with("Assembled row counts or schemas differ from the release design")
  }
  modis_key <- site_key(modis$LTER, modis$Stream_Name)
  era5_key <- site_key(era5$LTER, era5$Stream_Name)
  if (
    anyDuplicated(modis_key) || anyDuplicated(era5_key) ||
      anyDuplicated(modis$canonical_row_id) || anyDuplicated(era5$canonical_row_id)
  ) {
    stop_with("A final dataset contains duplicate site or row IDs")
  }
  if (!identical(modis_key, era5_key)) {
    stop_with("The two final datasets do not have the same row order")
  }

  new_rows <- 1041:1196
  required_metadata <- c(
    "LTER", "Stream_Name", "Country", "State", "Latitude", "Longitude", "drainSqKm",
    "Has_Spatial_Data", "Shapefile_Name", "canonical_row_id", "gee_watershed_id"
  )
  require_columns(modis, required_metadata, "final MODIS dataset")
  metadata_present <- vapply(required_metadata, function(column) {
    value <- modis[[column]][new_rows]
    !is.na(value) & nzchar(trimws(as.character(value)))
  }, logical(length(new_rows)))
  if (any(!metadata_present)) {
    stop_with("An appended row is missing required metadata")
  }
  latitude <- suppressWarnings(as.numeric(modis$Latitude[new_rows]))
  longitude <- suppressWarnings(as.numeric(modis$Longitude[new_rows]))
  drainage <- suppressWarnings(as.numeric(modis$drainSqKm[new_rows]))
  if (
    any(!is.finite(latitude) | latitude < -90 | latitude > 90) ||
      any(!is.finite(longitude) | longitude < -180 | longitude > 180) ||
      any(!is.finite(drainage) | drainage <= 0)
  ) {
    stop_with("Appended site coordinates or drainage areas fail range checks")
  }
  if (
    !all(modis$Has_Spatial_Data[new_rows] == "Yes") ||
      !all(as.integer(modis$Spatial_Data_Version[new_rows]) == 3L) ||
      !all(modis$gee_glc_match[new_rows])
  ) {
    stop_with("Appended spatial metadata do not identify complete release-three rows")
  }
  state_key <- site_key(scope$state_updates$LTER, scope$state_updates$Stream_Name)
  new_key <- site_key(modis$LTER[new_rows], modis$Stream_Name[new_rows])
  state_match <- match(state_key, new_key)
  if (
    any(is.na(state_match)) ||
      !identical(
        trimws(as.character(modis$Country[new_rows][state_match])),
        trimws(as.character(scope$state_updates$Country))
      ) ||
      !identical(
        trimws(as.character(modis$State[new_rows][state_match])),
        trimws(as.character(scope$state_updates$State))
      ) ||
      any(abs(
        suppressWarnings(as.numeric(modis$Latitude[new_rows][state_match])) -
          suppressWarnings(as.numeric(scope$state_updates$Latitude))
      ) > 1e-10) ||
      any(abs(
        suppressWarnings(as.numeric(modis$Longitude[new_rows][state_match])) -
          suppressWarnings(as.numeric(scope$state_updates$Longitude))
      ) > 1e-10)
  ) {
    stop_with("The staged public-site metadata were not reproduced exactly")
  }

  duplicate_ids <- names(which(table(aliases$site_id) > 1L))
  driver_columns <- c(
    grep("^gee_glc_", names(modis), value = TRUE),
    grep("^(evapotrans_|greenup_|npp_|snow_|human_)", names(modis), value = TRUE)
  )
  for (site_id in duplicate_ids) {
    rows <- new_rows[aliases$site_id == site_id]
    reference <- modis[rows[[1]], driver_columns, drop = FALSE]
    if (!all(vapply(rows, function(row) {
      identical(
        as.list(modis[row, driver_columns, drop = FALSE]),
        as.list(reference)
      )
    }, logical(1)))) {
      stop_with("Aliases for ", site_id, " do not share identical driver values")
    }
  }
  list(modis = modis, era5 = era5, discharge_qa = discharge$qa)
}


### Flowing-water scope

keep_flowing_water_sites <- function(outputs) {
  required <- c(
    "canonical_row_id", "LTER", "Stream_Name", "Waterbody", "Location",
    "Original_Stream_Name"
  )
  require_columns(outputs$modis, required, "assembled MODIS dataset")
  require_columns(outputs$era5, required, "assembled ERA5-Land dataset")

  modis_key <- site_key(outputs$modis$LTER, outputs$modis$Stream_Name)
  era5_key <- site_key(outputs$era5$LTER, outputs$era5$Stream_Name)
  modis_type <- tolower(normalized_text(outputs$modis$Waterbody))
  era5_type <- tolower(normalized_text(outputs$era5$Waterbody))
  if (!identical(modis_key, era5_key) || !identical(modis_type, era5_type)) {
    stop_with("The two assembled datasets differ in site order or waterbody type")
  }

  flowing_types <- c("river", "stream", "creek", "brook", "river or stream")
  standing_types <- c("lake", "pond", "reservoir", "tarn", "impoundment")
  unexpected <- !modis_type %in% c(flowing_types, standing_types)
  if (any(unexpected)) {
    values <- sort(unique(outputs$modis$Waterbody[unexpected]))
    stop_with(
      "A spatial row has an unreviewed waterbody type: ",
      paste(values, collapse = ", ")
    )
  }

  remove <- modis_type %in% standing_types
  expected_removed <- site_key(c("Danube", "GEMS"), c("MD5", "ITA00391"))
  if (!setequal(modis_key[remove], expected_removed)) {
    stop_with("The reviewed standing-water exclusion set changed")
  }

  name_text <- paste(
    normalized_text(outputs$modis$Stream_Name),
    normalized_text(outputs$modis$Original_Stream_Name),
    normalized_text(outputs$modis$Location)
  )
  standing_word <- grepl(
    "\\b(lake|lakes|pond|ponds|reservoir|reservoirs|tarn|tarns|impoundment|impoundments)\\b",
    name_text,
    ignore.case = TRUE,
    perl = TRUE
  )
  retained_name_rows <- !remove & standing_word

  excluded <- outputs$modis[remove, required, drop = FALSE]
  retained_names <- outputs$modis[
    retained_name_rows,
    c("canonical_row_id", "LTER", "Stream_Name", "Waterbody"),
    drop = FALSE
  ]
  outputs$modis <- outputs$modis[!remove, , drop = FALSE]
  outputs$era5 <- outputs$era5[!remove, , drop = FALSE]
  rownames(outputs$modis) <- NULL
  rownames(outputs$era5) <- NULL
  outputs$waterbody_qa <- list(
    rule = paste0(
      "Exclude reviewed standing-water Waterbody types; retain flowing-water ",
      "sites even when a lake, pond, or reservoir appears in the site name"
    ),
    flowing_types = flowing_types,
    standing_types = standing_types,
    assembled_type_counts = table(modis_type),
    released_type_counts = table(modis_type[!remove]),
    excluded = excluded,
    retained_name_matches = retained_names
  )
  outputs
}


### Driver QA records

check_recorded_outputs <- function(records, paths, labels, source_label) {
  require_columns(records, c("label", "md5"), source_label)
  index <- match(labels, records$label)
  if (anyNA(index)) {
    stop_with(source_label, " lacks one or more expected output records")
  }
  actual <- unname(tools::md5sum(paths))
  if (!identical(actual, as.character(records$md5[index]))) {
    stop_with(source_label, " does not match the current driver files")
  }
}

validate_driver_qa <- function(settings, scope, found, glc_files, era5_files) {
  gee <- readRDS(settings$gee_qa)
  modis <- readRDS(settings$modis_qa)
  required_gee_checks <- c(
    "glc_grid_complete", "glc_area_closure_passed",
    "glc_sampling_diagnostics_valid", "era5_grid_complete",
    "era5_source_image_counts_valid", "era5_physical_ranges_valid",
    "staged_csv_readback_equal"
  )
  required_modis_checks <- c(
    "complete_task_grid", "released_field_counts",
    "et_present_values_finite", "greenup_dates_plausible",
    "npp_present_values_in_physical_range",
    "snow_present_values_in_physical_range",
    "snow_full_composite_parity_preserved",
    "missing_coverage_retained_as_missing", "output_csv_readback_equal"
  )
  if (!is.list(gee) || !is.list(modis)) {
    stop_with("A replacement-driver QA file is invalid")
  }
  if (!all(required_gee_checks %in% names(gee$checks)) ||
      !all(required_modis_checks %in% names(modis$checks)) ||
      !all(unlist(gee$checks[required_gee_checks], use.names = FALSE)) ||
      !all(unlist(modis$checks[required_modis_checks], use.names = FALSE))) {
    stop_with("A replacement-driver QA check is not true")
  }
  check_recorded_outputs(
    gee$outputs,
    c(glc_files, era5_files),
    c("glc", "era5_land"),
    "GEE replacement QA"
  )
  modis_paths <- unname(unlist(found$modis, use.names = FALSE))
  check_recorded_outputs(
    modis$output_files,
    modis_paths,
    names(found$modis),
    "MODIS replacement QA"
  )

  glc_site <- gee$glc$per_site
  era5_row <- gee$era5_land$per_site_year
  modis_site <- modis$spatial_method_by_site
  expected_modis_methods <- c(
    "fractional_polygon_mean_native_500m_interior_fallback_v3",
    "fractional_polygon_mean_bounded_scale_interior_fallback_v3"
  )
  require_columns(
    glc_site,
    c(
      "site_id", "extraction_method", "maximum_sample_standard_error",
      "maximum_area_closure_relative_error"
    ),
    "GEE GLC per-site QA"
  )
  require_columns(
    era5_row,
    c("site_id", "year", "used_fine_scale_fallback", "source_image_count"),
    "GEE ERA5-Land per-site-year QA"
  )
  require_columns(
    modis_site,
    c(
      "site_id", "analysis_scale_m", "extraction_method",
      "spatial_pixel_cap", "requested_value_count", "polygon_value_count",
      "interior_fallback_value_count", "missing_value_count",
      "value_coverage_fraction", "interior_fallback_fraction"
    ),
    "MODIS per-site QA"
  )
  if (
    nrow(glc_site) != 151L || anyDuplicated(glc_site$site_id) ||
      !setequal(glc_site$site_id, scope$new_site_ids) ||
      nrow(era5_row) != 151L * 26L ||
      anyDuplicated(paste(era5_row$site_id, era5_row$year)) ||
      !setequal(era5_row$site_id, scope$new_site_ids) ||
      nrow(modis_site) != 151L || anyDuplicated(modis_site$site_id) ||
      !setequal(modis_site$site_id, scope$new_site_ids)
  ) {
    stop_with("Replacement-driver QA does not cover the exact 151-site scope")
  }
  sampled_glc <- glc_site$extraction_method ==
    "deterministic_local_equal_area_points_v1"
  era5_expected_days <- ifelse(
    era5_row$year %% 400L == 0L |
      (era5_row$year %% 4L == 0L & era5_row$year %% 100L != 0L),
    366L,
    365L
  )
  if (
    any(!glc_site$extraction_method %in% c(
      "native_30m_exact",
      "deterministic_local_equal_area_points_v1"
    )) ||
      any(!is.finite(glc_site$maximum_area_closure_relative_error) |
        glc_site$maximum_area_closure_relative_error > 0.011) ||
      any(sampled_glc & (
        !is.finite(glc_site$maximum_sample_standard_error) |
          glc_site$maximum_sample_standard_error < 0
      )) ||
      any(!era5_row$used_fine_scale_fallback %in% c(0L, 1L)) ||
      any(era5_row$source_image_count != era5_expected_days) ||
      !setequal(era5_row$year, 2000:2025)
  ) {
    stop_with("GEE method, closure, fallback, or source-count QA is invalid")
  }
  if (
    !identical(modis$extraction_version, "modis_release3_field_time_bounded_scale_v3") ||
      !identical(
        modis$snow_summary_method,
        "legacy_mod10a2_full_composite_equivalent_v1"
      ) ||
      !identical(
        modis$legacy_calendar_day_rebuild_locally_reproducible,
        FALSE
      ) ||
      !grepl("not strict calendar-day", modis$snow_summary_note, fixed = TRUE) ||
      any(!modis_site$extraction_method %in% expected_modis_methods) ||
      any(modis_site$spatial_pixel_cap != 10000L) ||
      any(!is.finite(modis_site$analysis_scale_m) |
        modis_site$analysis_scale_m < 500) ||
      any(
        modis_site$requested_value_count !=
          modis_site$polygon_value_count +
            modis_site$interior_fallback_value_count +
            modis_site$missing_value_count
      ) ||
      any(!is.finite(modis_site$value_coverage_fraction) |
        modis_site$value_coverage_fraction < 0 |
        modis_site$value_coverage_fraction > 1)
  ) {
    stop_with("MODIS extraction provenance or coverage QA is invalid")
  }
  if (length(gee$expected_assets$glc) != 151L ||
      length(gee$expected_assets$era5_land) != 182L ||
      gee$glc$rows != 151L * 25L * 30L ||
      gee$era5_land$rows != 151L * 26L) {
    stop_with("GEE asset or row counts changed from the release-three plan")
  }

  list(
    gee_qa_file = file_records(settings$gee_qa),
    modis_qa_file = file_records(settings$modis_qa),
    glc_method_counts = gee$glc$method_counts,
    glc_per_site = glc_site,
    era5_fine_scale_fallback_rows = gee$era5_land$fine_scale_fallback_rows,
    modis_spatial_method_by_site = modis_site,
    modis_interior_fallback_site_count = modis$interior_fallback_site_count,
    modis_interior_fallback_value_count = modis$interior_fallback_value_count,
    modis_missing_extracted_value_count = modis$missing_extracted_value_count,
    snow_summary_method = modis$snow_summary_method,
    snow_summary_note = modis$snow_summary_note,
    legacy_calendar_day_rebuild_locally_reproducible =
      modis$legacy_calendar_day_rebuild_locally_reproducible,
    legacy_calendar_day_rebuild_reason =
      modis$legacy_calendar_day_rebuild_reason,
    snow_summary_scope = paste(
      "All released rows use legacy full-composite-equivalent snow summaries;",
      "the released snow column names are preserved"
    )
  )
}


### Output

assert_csv_readback <- function(expected, path, label) {
  actual <- read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = ""
  )
  if (!identical(dim(actual), dim(expected)) ||
      !identical(names(actual), names(expected))) {
    stop_with(label, " changed dimensions or columns during CSV read-back")
  }
  key_columns <- c("LTER", "Stream_Name", "canonical_row_id")
  if (!identical(
    as.data.frame(lapply(expected[key_columns], normalized_text)),
    as.data.frame(lapply(actual[key_columns], normalized_text))
  )) {
    stop_with(label, " changed row identity during CSV read-back")
  }
  for (column in names(expected)) {
    expected_value <- expected[[column]]
    actual_value <- actual[[column]]
    if (is.numeric(expected_value) || is.integer(expected_value)) {
      actual_value <- suppressWarnings(as.numeric(actual_value))
      if (!identical(is.na(expected_value), is.na(actual_value))) {
        stop_with(label, " changed missing numeric values in ", column)
      }
      present <- !is.na(expected_value)
      difference <- abs(expected_value[present] - actual_value[present])
      tolerance <- 1e-12 * (1 + abs(expected_value[present]))
      if (any(!is.finite(actual_value[present])) || any(difference > tolerance)) {
        stop_with(label, " changed numeric values in ", column)
      }
    } else if (is.logical(expected_value)) {
      if (!identical(expected_value, as.logical(actual_value))) {
        stop_with(label, " changed logical values in ", column)
      }
    } else if (!identical(
      normalized_text(expected_value),
      normalized_text(actual_value)
    )) {
      stop_with(label, " changed text values in ", column)
    }
  }
  invisible(actual)
}

write_outputs <- function(outputs, qa, output_dir) {
  if (file.exists(output_dir)) {
    stop_with("Output directory already exists: ", output_dir)
  }
  parent <- dirname(output_dir)
  dir.create(parent, recursive = TRUE, showWarnings = FALSE)
  stage <- tempfile(".harmonized-spatial-20260815-", tmpdir = parent)
  dir.create(stage)
  on.exit(if (dir.exists(stage)) unlink(stage, recursive = TRUE), add = TRUE)

  names_out <- c(
    modis = "harmonized_spatial_modis_human_impacts_20260815.csv",
    era5 = "harmonized_spatial_era5land_modis_human_impacts_20260815.csv",
    qa = "harmonized_spatial_qa_20260815.rds"
  )
  modis_path <- file.path(stage, names_out[["modis"]])
  era5_path <- file.path(stage, names_out[["era5"]])
  write.csv(outputs$modis, modis_path, row.names = FALSE, na = "")
  write.csv(outputs$era5, era5_path, row.names = FALSE, na = "")
  assert_csv_readback(outputs$modis, modis_path, "Staged MODIS dataset")
  assert_csv_readback(outputs$era5, era5_path, "Staged ERA5-Land dataset")
  qa$checks <- c(
    qa$checks,
    staged_csv_readback_values_equal = TRUE,
    installed_csv_readback_values_equal = TRUE
  )
  qa$outputs <- data.frame(
    file = names_out[c("modis", "era5")],
    rows = c(nrow(outputs$modis), nrow(outputs$era5)),
    columns = c(ncol(outputs$modis), ncol(outputs$era5)),
    md5 = unname(tools::md5sum(c(modis_path, era5_path))),
    stringsAsFactors = FALSE
  )
  qa_path <- file.path(stage, names_out[["qa"]])
  saveRDS(qa, qa_path, compress = "xz")
  qa_check <- readRDS(qa_path)
  if (!identical(qa_check$outputs$md5, qa$outputs$md5) ||
      !all(qa_check$checks)) {
    stop_with("The staged harmonized QA record failed read-back")
  }
  if (!file.rename(stage, output_dir)) {
    stop_with("Could not move the checked outputs into ", output_dir)
  }
  installed_modis <- file.path(output_dir, names_out[["modis"]])
  installed_era5 <- file.path(output_dir, names_out[["era5"]])
  assert_csv_readback(outputs$modis, installed_modis, "Installed MODIS dataset")
  assert_csv_readback(outputs$era5, installed_era5, "Installed ERA5-Land dataset")
  if (!identical(
    unname(tools::md5sum(c(installed_modis, installed_era5))),
    qa$outputs$md5
  ) || !is.list(readRDS(file.path(output_dir, names_out[["qa"]])))) {
    stop_with("Installed harmonized outputs failed final hash or QA read-back")
  }
  cat("Wrote ", normalizePath(output_dir), "\n", sep = "")
}


### Run

run_release3_rebuild <- function(settings) {
  if (!file.exists(settings$watershed_qa)) {
    stop_with("Missing watershed QA record: ", settings$watershed_qa)
  }
  watershed_qa <- readRDS(settings$watershed_qa)
  site_reference <- watershed_qa$source_site_table
  if (!nzchar(settings$site_base)) {
    settings$site_base <- file.path(
      dirname(site_reference),
      "final_combined_spatial_drivers.csv"
    )
  }
  if (
    !file.exists(site_reference) ||
      !identical(
        unname(tools::md5sum(site_reference)),
        watershed_qa$source_site_table_md5_before
      )
  ) {
    stop_with("The read-only site-reference snapshot no longer matches the watershed QA record")
  }

  found <- discover_inputs(settings, settings$site_base)
  print_discovery(found, settings)
  static_names <- names(found$static)
  if (any(!found$ready[static_names])) {
    stop_with("A required baseline or release-scope input is missing")
  }
  scope <- read_release_scope(settings, settings$site_base, site_reference)
  cat(
    paste0(
      "\nValidated assembly scope: 1,040 baseline rows + 156 appended aliases ",
      "from 151 sites; 178 staged discharge matches\n"
    )
  )

  driver_names <- setdiff(names(found$ready), static_names)
  if (any(!found$ready[driver_names])) {
    waiting <- names(found$ready)[!found$ready & names(found$ready) %in% driver_names]
    cat("Waiting for: ", paste(waiting, collapse = ", "), "\n", sep = "")
    cat("No outputs written\n")
    if (settings$write) stop_with("The replacement drivers are not complete")
    return(invisible(FALSE))
  }

  all_inputs <- c(
    unname(found$static),
    found$glc,
    unlist(found$modis, use.names = FALSE),
    found$era5,
    found$human,
    unname(found$qa_files),
    unname(found$aurora),
    site_reference
  )
  input_records <- file_records(all_inputs)

  new_base <- prepare_new_base(scope)
  aurora_values <- build_aurora_values(
    found$aurora,
    scope,
    new_base,
    names(scope$old_modis)
  )
  new_base <- apply_aurora_values(new_base, aurora_values)
  glc_source <- read_data_set(
    settings$glc_source,
    c("site_id", "Year", "LC_ID", "Area_m2"),
    "GLC replacement"
  )
  era5_source <- read_data_set(
    settings$era5_source,
    c(
      "site_id", "year", "precip_mm", "temp_degC", "evapotrans_mm",
      "potential_evap_mm", "snow_cover_fraction", "snow_water_equiv_mm"
    ),
    "ERA5-Land replacement"
  )
  human_source <- read_data_set(
    settings$human_source,
    c("site_id", "human_impact_dataset", "year"),
    "human-impact replacement"
  )
  driver_qa <- validate_driver_qa(
    settings,
    scope,
    found,
    glc_source$files,
    era5_source$files
  )
  geometry_values <- build_geometry_values(scope, scope$old_modis)
  drivers <- list(
    geometry = geometry_values,
    glc = build_glc_values(
      glc_source$data,
      settings$glc_crosswalk,
      scope$new_site_ids,
      names(scope$old_modis)
    ),
    modis = build_modis_values(
      found$modis,
      scope$geometry,
      scope$new_site_ids,
      names(scope$old_modis)
    ),
    human = build_human_values(
      human_source$data,
      scope$new_site_ids,
      names(scope$old_modis)
    ),
    era5 = build_era5_values(
      era5_source$data,
      scope$new_site_ids,
      names(scope$old_era5)
    )
  )
  outputs <- assemble_outputs(scope, new_base, drivers)
  outputs <- keep_flowing_water_sites(outputs)
  if (nrow(outputs$modis) != 1194L || nrow(outputs$era5) != 1194L) {
    stop_with("The flowing-water release does not contain exactly 1,194 rows")
  }
  cat(
    "Excluded ", nrow(outputs$waterbody_qa$excluded),
    " reviewed standing-water sites; lake and reservoir outlets remain\n",
    sep = ""
  )

  input_md5_after <- unname(tools::md5sum(input_records$path))
  if (!identical(input_records$md5, input_md5_after)) {
    stop_with("A harmonization input changed during the rebuild")
  }
  input_records$md5_after <- input_md5_after
  input_records$unchanged_during_build <- TRUE
  new_output_rows <- match(
    site_key(scope$new_aliases$LTER, scope$new_aliases$Stream_Name),
    site_key(outputs$modis$LTER, outputs$modis$Stream_Name)
  )
  if (anyNA(new_output_rows)) {
    stop_with("A release-three alias was removed by the waterbody filter")
  }
  qa <- list(
    built_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    counts = c(
      assembled_baseline_rows = 1040L,
      appended_alias_rows = 156L,
      appended_site_ids = 151L,
      assembled_rows = 1196L,
      replacement_boundaries = 66L,
      remaining_boundaries = 85L,
      public_state_updates = 154L,
      country_corrections = 1L,
      coordinate_corrections = 1L,
      aurora_patch_alias_rows = 68L,
      aurora_reused_alias_rows = 88L,
      aurora_fields = 180L,
      standing_water_rows_excluded = 2L,
      standing_water_name_rows_retained =
        nrow(outputs$waterbody_qa$retained_name_matches),
      baseline_rows_retained = 1038L,
      final_rows = 1194L,
      modis_columns = 1864L,
      era5_columns = 2020L,
      outputs$discharge_qa$counts
    ),
    checks = c(
      old_modis_non_discharge_fields_identical = TRUE,
      old_era5_non_discharge_fields_identical = TRUE,
      final_site_keys_unique = TRUE,
      final_row_ids_unique = TRUE,
      schemas_unchanged = TRUE,
      aliases_expanded_by_site_id = TRUE,
      replacement_metadata_applied = TRUE,
      public_state_updates_applied = TRUE,
      single_country_correction_applied = TRUE,
      aurora_target_keys_complete = TRUE,
      aurora_180_fields_replaced = TRUE,
      unchanged_public_aurora_values_reused = TRUE,
      glc_complete_and_closed = TRUE,
      modis_fields_and_ranges_valid = TRUE,
      human_impacts_complete_and_valid = TRUE,
      era5_land_complete_and_valid = TRUE,
      gee_qa_matches_current_driver_files = TRUE,
      modis_qa_matches_current_driver_files = TRUE,
      modis_interior_fallback_coverage_valid = TRUE,
      snow_full_composite_parity_preserved_for_all_rows = TRUE,
      watershed_area_qa_passed = TRUE,
      discharge_updates_exact = TRUE,
      chemistry_coordinates_unchanged = TRUE,
      provisional_wrtds_yes_held_at_no = TRUE,
      standing_water_sites_excluded = TRUE,
      flowing_water_types_reviewed = TRUE,
      lake_outlet_sites_retained = TRUE
    ),
    aurora_no_coverage_rows = aurora_values$no_coverage,
    discharge_metadata = outputs$discharge_qa,
    waterbody_scope = outputs$waterbody_qa,
    driver_qa = driver_qa,
    modis_missing_value_counts = vapply(drivers$modis, function(data) {
      sum(!as.matrix(as.data.frame(lapply(data, function(value) {
        !is.na(value) & nzchar(trimws(as.character(value)))
      }), check.names = FALSE)))
    }, integer(1)),
    modis_all_missing_site_counts = vapply(drivers$modis, function(data) {
      present <- as.data.frame(lapply(data, function(value) {
        !is.na(value) & nzchar(trimws(as.character(value)))
      }), check.names = FALSE)
      sum(rowSums(present) == 0L)
    }, integer(1)),
    new_aliases = data.frame(
      canonical_row_id = outputs$modis$canonical_row_id[new_output_rows],
      LTER = scope$new_aliases$LTER,
      Stream_Name = scope$new_aliases$Stream_Name,
      Country = outputs$modis$Country[new_output_rows],
      State = outputs$modis$State[new_output_rows],
      site_id = scope$new_aliases$site_id,
      gee_watershed_id = outputs$modis$gee_watershed_id[new_output_rows],
      replacement_boundary = new_base$replacement_rows,
      aurora_patch = new_base$aurora_target_rows,
      stringsAsFactors = FALSE
    ),
    inputs = input_records
  )
  cat("All rebuild checks passed\n")
  if (!settings$write) {
    cat("Dry run only; no outputs written\n")
    return(invisible(TRUE))
  }
  write_outputs(outputs, qa, settings$output_dir)
  invisible(TRUE)
}


if (sys.nframe() == 0L) {
  tryCatch(
    run_release3_rebuild(parse_args(commandArgs(trailingOnly = TRUE))),
    error = function(error) {
      message("Release-three spatial rebuild failed: ", conditionMessage(error))
      quit(status = 1L)
    }
  )
}
