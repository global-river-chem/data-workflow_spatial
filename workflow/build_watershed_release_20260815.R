#!/usr/bin/Rscript

suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

### Settings

args <- commandArgs(trailingOnly = TRUE)

site_table_path <- cli_value(
  args,
  "--site-table",
  file.path(
    "..",
    "lterwg-silica-spatial",
    "generated_outputs",
    "final-integration",
    "final-spatial-20260805",
    "site_reference_table_final_candidate_20260805.csv"
  )
)
prior_root <- cli_value(
  args,
  "--prior-root",
  file.path("generated_outputs", "watersheds-20260811")
)
source_root <- cli_value(
  args,
  "--source-root",
  file.path("generated_outputs", "watersheds-20260815", "source")
)
output_root <- cli_value(
  args,
  "--output-root",
  file.path("generated_outputs", "watersheds-20260815")
)
overwrite <- cli_boolean(args, "--overwrite", FALSE)
discharge_updates_path <- cli_value(
  args,
  "--discharge-updates",
  file.path(
    "generated_outputs",
    "public-site-incorporation-20260815",
    "discharge_assignment_updates_183_20260815.tsv"
  )
)

prior_gpkg <- file.path(prior_root, "watersheds_all_sites_20260811.gpkg")
prior_alias_path <- file.path(
  prior_root,
  "watersheds_all_sites_20260811_site_aliases.tsv"
)
newfoundland_source <- file.path(
  source_root,
  "newfoundland-labrador-wqma-watersheds-20260815.gpkg"
)
chile_source <- file.path(
  source_root,
  "chile-camels-cl-watersheds-20260815.gpkg"
)

output_name <- "watersheds_all_sites_20260815"
gpkg_path <- file.path(output_root, paste0(output_name, ".gpkg"))
zip_path <- file.path(output_root, paste0(output_name, "_shapefile.zip"))
alias_path <- file.path(output_root, paste0(output_name, "_site_aliases.tsv"))
qa_path <- file.path(output_root, paste0(output_name, "_qa.rds"))
update_path <- file.path(
  output_root,
  "watersheds_site_reference_updates_66_20260815.tsv"
)

expected_prior_count <- 1148L
expected_final_count <- 1154L
expected_alias_rows <- 1196L
expected_update_rows <- 66L

### Helpers

area_text <- function(value) {
  format(value, scientific = FALSE, trim = TRUE, digits = 15)
}

first_text <- function(value) {
  value <- trimws(as.character(value))
  value <- value[nzchar(value)]
  if (length(value)) value[[1L]] else ""
}

geometry_binary <- function(value) {
  st_as_binary(st_geometry(value), EWKB = TRUE)
}

plain_attributes <- function(value) {
  value <- st_drop_geometry(value)
  row.names(value) <- NULL
  value
}

as_text_frame <- function(value) {
  value[] <- lapply(value, as.character)
  row.names(value) <- NULL
  value
}

make_update_rows <- function(
  site_rows,
  source_ids,
  areas,
  names_new,
  area_source,
  polygon_source,
  source_link,
  update_basis
) {
  data.frame(
    LTER = site_rows$LTER,
    Stream_Name = site_rows$Stream_Name,
    Chemistry_Site_ID = site_rows$Chemistry_Site_ID,
    Source_Geometry_ID = source_ids,
    Old_Site_ID = paste(
      normalize_key(site_rows$LTER),
      normalize_key(site_rows$Shapefile_Name),
      sep = "__"
    ),
    New_Site_ID = paste(
      normalize_key(site_rows$LTER),
      normalize_key(names_new),
      sep = "__"
    ),
    Spatial_Data_Version_old = site_rows$Spatial_Data_Version,
    Spatial_Data_Version_new = "3",
    Has_Spatial_Data_old = site_rows$Has_Spatial_Data,
    Has_Spatial_Data_new = "Yes",
    Shapefile_Name_old = site_rows$Shapefile_Name,
    Shapefile_Name_new = names_new,
    Shapefile_CRS_EPSG_old = site_rows$Shapefile_CRS_EPSG,
    Shapefile_CRS_EPSG_new = "4326",
    drainSqKm_old = site_rows$drainSqKm,
    drainSqKm_new = area_text(areas),
    Derived_DA_Unverified_old = site_rows$Derived_DA_Unverified,
    Derived_DA_Unverified_new = "No",
    drainSqKm_source_old = site_rows$drainSqKm_source,
    drainSqKm_source_new = area_source,
    Shapefile_Source_old = site_rows$Shapefile_Source,
    Shapefile_Source_new = polygon_source,
    Shapefile_Link_old = site_rows$Shapefile_Link,
    Shapefile_Link_new = source_link,
    Update_Basis = update_basis,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

make_release_features <- function(source_features, updates, updated_sites) {
  site_rows <- updated_sites[match(
    updates$Chemistry_Site_ID,
    updated_sites$Chemistry_Site_ID
  ), , drop = FALSE]
  source_rows <- source_features[match(
    updates$Chemistry_Site_ID,
    source_features$Chemistry_Site_ID
  ), ]

  if (anyNA(site_rows$Chemistry_Site_ID) || anyNA(source_rows$Chemistry_Site_ID)) {
    stop("Could not align replacement features with site rows", call. = FALSE)
  }

  polygon_area_km2 <- as.numeric(st_area(st_transform(source_rows, 6933))) / 1e6
  attributes <- data.frame(
    site_id = updates$New_Site_ID,
    run_group = site_rows$LTER,
    LTER = site_rows$LTER,
    Shapefile_Name = site_rows$Shapefile_Name,
    Stream_Name = site_rows$Stream_Name,
    Discharge_File_Name = site_rows$Discharge_File_Name,
    hydrosheds_used = FALSE,
    hydrosheds_id = "",
    expected_area_km2 = suppressWarnings(as.numeric(site_rows$drainSqKm)),
    drn_src = site_rows$drainSqKm_source,
    polygon_area_km2 = polygon_area_km2,
    tiny_ws = polygon_area_km2 <= 10,
    source_type = site_rows$Shapefile_Source,
    source_file = file.path(
      "data_release_3",
      site_rows$Shapefile_Name,
      paste0(site_rows$Shapefile_Name, ".shp")
    ),
    Spatial_Data_Version = 3L,
    stringsAsFactors = FALSE
  )
  st_sf(attributes, geom = st_geometry(source_rows), crs = 4326)
}

### Inputs

input_files <- c(
  site_table_path,
  prior_gpkg,
  prior_alias_path,
  newfoundland_source,
  chile_source,
  discharge_updates_path
)
missing_inputs <- input_files[!file.exists(input_files)]
if (length(missing_inputs)) {
  stop("Missing inputs: ", paste(missing_inputs, collapse = ", "), call. = FALSE)
}

site_table_md5_before <- unname(tools::md5sum(site_table_path))
input_file_records <- file_records(
  input_files,
  c(
    "site_reference_snapshot",
    "prior_watersheds",
    "prior_site_aliases",
    "newfoundland_source",
    "chile_source",
    "discharge_updates"
  )
)
site_table <- read_workflow_table(site_table_path)
required_site_fields <- c(
  "LTER", "Stream_Name", "Chemistry_Site_ID", "Spatial_Data_Version",
  "Has_Spatial_Data", "Shapefile_Name", "Shapefile_CRS_EPSG",
  "drainSqKm", "Derived_DA_Unverified", "drainSqKm_source",
  "Shapefile_Source", "Shapefile_Link", "Discharge_File_Name"
)
require_columns(site_table, required_site_fields, "site table")
if (anyDuplicated(site_table$Chemistry_Site_ID[nzchar(site_table$Chemistry_Site_ID)])) {
  stop("Chemistry_Site_ID is not unique in the source site table", call. = FALSE)
}

prior <- st_transform(st_read(prior_gpkg, quiet = TRUE), 4326)
prior_alias <- read.delim(
  prior_alias_path,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  check.names = FALSE
)
if (nrow(prior) != expected_prior_count || anyDuplicated(prior$site_id)) {
  stop("Prior watershed release does not contain 1,148 unique geometries")
}
if (nrow(prior_alias) != expected_alias_rows) {
  stop("Prior alias table does not contain 1,196 rows")
}

newfoundland <- st_transform(st_read(
  newfoundland_source,
  layer = "official_watersheds",
  quiet = TRUE
), 4326)
newfoundland_qa <- st_read(
  newfoundland_source,
  layer = "qa",
  quiet = TRUE
)
chile <- st_transform(st_read(
  chile_source,
  layer = "official_candidates",
  quiet = TRUE
), 4326)
chile_qa <- st_read(chile_source, layer = "qa", quiet = TRUE)

if (nrow(newfoundland) != 64L || anyDuplicated(newfoundland$STATION_NUM)) {
  stop("Expected 64 unique Newfoundland WQMA polygons")
}
if (nrow(newfoundland_qa) != 64L || !all(newfoundland_qa$Replace_Current)) {
  stop("All 64 Newfoundland WQMA polygons must pass source QA")
}
coordinate_review_ids <- sort(as.character(
  newfoundland_qa$Chemistry_Site_ID[
    as.logical(newfoundland_qa$Coordinate_Review_Needed)
  ]
))
expected_coordinate_review_ids <- c("NF02ZM0020", "NF02ZM0185")
if (!identical(coordinate_review_ids, expected_coordinate_review_ids)) {
  stop("The two Newfoundland coordinate-review sites changed")
}
accepted_chile_ids <- chile_qa$Chemistry_Site_ID[chile_qa$Replace_Current]
expected_chile_ids <- c("09420001-6", "10340001-5")
if (!setequal(accepted_chile_ids, expected_chile_ids)) {
  stop("The two accepted CAMELS-CL site IDs changed")
}

newfoundland$Chemistry_Site_ID <- newfoundland$STATION_NUM
chile <- chile[chile$Chemistry_Site_ID %in% accepted_chile_ids, ]
if (any(!st_is_valid(newfoundland)) || any(st_is_empty(newfoundland)) ||
    any(!st_is_valid(chile)) || any(st_is_empty(chile))) {
  stop("Replacement sources contain invalid or empty geometry")
}

### Derived 66-row update table

newfoundland_sites <- site_table[match(
  newfoundland$Chemistry_Site_ID,
  site_table$Chemistry_Site_ID
), , drop = FALSE]
chile_sites <- site_table[match(
  chile$Chemistry_Site_ID,
  site_table$Chemistry_Site_ID
), , drop = FALSE]
if (anyNA(newfoundland_sites$Chemistry_Site_ID) || anyNA(chile_sites$Chemistry_Site_ID)) {
  stop("Replacement site IDs are missing from the source site table")
}

newfoundland_names <- paste0(
  "sisyn_canada_eccc_wqma_",
  tolower(newfoundland_sites$Chemistry_Site_ID)
)
if (anyDuplicated(newfoundland_names) || length(unique(newfoundland_names)) != 64L) {
  stop("Newfoundland exact-site shapefile names are not unique")
}

newfoundland_updates <- make_update_rows(
  newfoundland_sites,
  newfoundland$STATION_NUM,
  newfoundland$AREA_SQKM,
  newfoundland_names,
  "Government of Newfoundland and Labrador WQMA official watershed area",
  "Government of Newfoundland and Labrador WQMA official watershed",
  first_text(newfoundland$Source_URL),
  "Accepted exact WQMA station watershed"
)
chile_updates <- make_update_rows(
  chile_sites,
  chile$gauge_id,
  chile$area_km2,
  chile_sites$Shapefile_Name,
  "CAMELS-CL v1.3 published station catchment area",
  "CAMELS-CL v1.3 station catchment boundary",
  first_text(chile$Source_URL),
  "Accepted CAMELS-CL station catchment"
)
updates <- rbind(newfoundland_updates, chile_updates)
updates <- updates[order(updates$LTER, updates$Chemistry_Site_ID), , drop = FALSE]
row.names(updates) <- NULL

newfoundland_qa_rows <- st_drop_geometry(newfoundland_qa)[match(
  updates$Chemistry_Site_ID,
  newfoundland_qa$Chemistry_Site_ID
), , drop = FALSE]
updates$Coordinate_Review_Needed <- ifelse(
  is.na(newfoundland_qa_rows$Coordinate_Review_Needed),
  FALSE,
  as.logical(newfoundland_qa_rows$Coordinate_Review_Needed)
)
updates$Coordinate_Review_Distance_m <- suppressWarnings(as.numeric(
  newfoundland_qa_rows$Site_to_Official_Station_m
))
updates$Coordinate_Review_Status <- ifelse(
  updates$Coordinate_Review_Needed,
  as.character(newfoundland_qa_rows$QA_Status),
  ""
)

if (nrow(updates) != expected_update_rows ||
    anyDuplicated(updates$Chemistry_Site_ID) ||
    !all(updates$Spatial_Data_Version_new == "3") ||
    !all(updates$Derived_DA_Unverified_new == "No")) {
  stop("The derived site-table update is not the expected 66-row change set")
}

updated_sites <- site_table
update_indices <- match(updates$Chemistry_Site_ID, updated_sites$Chemistry_Site_ID)
fields_to_apply <- c(
  "Spatial_Data_Version", "Has_Spatial_Data", "Shapefile_Name",
  "Shapefile_CRS_EPSG", "drainSqKm", "Derived_DA_Unverified",
  "drainSqKm_source", "Shapefile_Source", "Shapefile_Link"
)
for (field in fields_to_apply) {
  updated_sites[update_indices, field] <- updates[[paste0(field, "_new")]]
}

### Updated aliases and replacement features

spatial_version <- suppressWarnings(as.integer(updated_sites$Spatial_Data_Version))
spatial_rows <- updated_sites[
  trimws(updated_sites$Has_Spatial_Data) == "Yes" &
    nzchar(trimws(updated_sites$Shapefile_Name)) &
    spatial_version %in% 1:3,
  ,
  drop = FALSE
]
spatial_rows$Spatial_Data_Version <- suppressWarnings(as.integer(
  spatial_rows$Spatial_Data_Version
))
aliases <- data.frame(
  site_id = paste(
    normalize_key(spatial_rows$LTER),
    normalize_key(spatial_rows$Shapefile_Name),
    sep = "__"
  ),
  LTER = spatial_rows$LTER,
  Stream_Name = spatial_rows$Stream_Name,
  Shapefile_Name = spatial_rows$Shapefile_Name,
  Spatial_Data_Version = spatial_rows$Spatial_Data_Version,
  stringsAsFactors = FALSE
)
aliases <- unique(aliases)
aliases <- aliases[order(
  aliases$site_id,
  aliases$LTER,
  aliases$Stream_Name
), , drop = FALSE]
row.names(aliases) <- NULL

if (nrow(aliases) != expected_alias_rows ||
    length(unique(aliases$site_id)) != expected_final_count) {
  stop("Updated aliases do not resolve to 1,154 geometries and 1,196 rows")
}

discharge_updates <- read.delim(
  discharge_updates_path,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  check.names = FALSE
)
required_discharge_fields <- c(
  "Live_LTER", "Spatial_LTER", "Stream_Name", "Discharge_File_Name",
  "Units", "Discharge_Site_Name", "Chemistry_Latitude",
  "Chemistry_Longitude", "Discharge_Latitude", "Discharge_Longitude",
  "Pairing_Distance_km", "Proposed_Use_WRTDS", "Use_WRTDS_for_release",
  "Spatial_Release_Match"
)
require_columns(
  discharge_updates,
  required_discharge_fields,
  "discharge assignment updates"
)
if (nrow(discharge_updates) != 183L ||
    any(!discharge_updates$Spatial_Release_Match %in% c("Yes", "No")) ||
    sum(discharge_updates$Spatial_Release_Match == "Yes") != 178L ||
    any(trimws(discharge_updates$Units) != "cms") ||
    any(!nzchar(trimws(discharge_updates$Discharge_File_Name)))) {
  stop("Discharge assignment updates failed schema or content checks")
}
release_discharge <- discharge_updates[
  discharge_updates$Spatial_Release_Match == "Yes",
  ,
  drop = FALSE
]
release_discharge_key <- paste(
  release_discharge$Spatial_LTER,
  release_discharge$Stream_Name,
  sep = "::"
)
alias_discharge_key <- paste(aliases$LTER, aliases$Stream_Name, sep = "::")
alias_match_counts <- vapply(
  release_discharge_key,
  function(key) sum(alias_discharge_key == key),
  integer(1L)
)
if (anyDuplicated(release_discharge_key) || any(alias_match_counts != 1L)) {
  stop("The 178 spatial discharge assignments do not resolve exactly once")
}

target_keys <- paste(updates$LTER, updates$Stream_Name, sep = "::")
prior_alias_keys <- paste(prior_alias$LTER, prior_alias$Stream_Name, sep = "::")
new_alias_keys <- paste(aliases$LTER, aliases$Stream_Name, sep = "::")
prior_alias_unchanged <- prior_alias[!prior_alias_keys %in% target_keys, , drop = FALSE]
new_alias_unchanged <- aliases[!new_alias_keys %in% target_keys, , drop = FALSE]
prior_alias_unchanged <- prior_alias_unchanged[order(
  prior_alias_unchanged$site_id,
  prior_alias_unchanged$LTER,
  prior_alias_unchanged$Stream_Name
), , drop = FALSE]
new_alias_unchanged <- new_alias_unchanged[order(
  new_alias_unchanged$site_id,
  new_alias_unchanged$LTER,
  new_alias_unchanged$Stream_Name
), , drop = FALSE]
if (!identical(
  as_text_frame(prior_alias_unchanged),
  as_text_frame(new_alias_unchanged)
)) {
  stop("An unaffected alias row changed")
}

newfoundland_features <- make_release_features(
  newfoundland,
  newfoundland_updates,
  updated_sites
)
chile_features <- make_release_features(chile, chile_updates, updated_sites)
replacements <- rbind(newfoundland_features, chile_features)
replacements <- replacements[order(replacements$site_id), ]

old_replaced_ids <- unique(updates$Old_Site_ID)
if (length(old_replaced_ids) != 60L ||
    sum(old_replaced_ids %in% prior$site_id) != 60L) {
  stop("Expected the 66 updates to replace 60 prior geometries")
}
unaffected <- prior[!prior$site_id %in% old_replaced_ids, ]
if (nrow(unaffected) != 1088L) stop("Unexpected unaffected geometry count")
if (length(intersect(unaffected$site_id, replacements$site_id))) {
  stop("A replacement site ID collides with an unaffected geometry")
}

watersheds <- rbind(unaffected, replacements)
watersheds <- watersheds[order(watersheds$site_id), ]
if (nrow(watersheds) != expected_final_count ||
    anyDuplicated(watersheds$site_id) ||
    !setequal(watersheds$site_id, aliases$site_id)) {
  stop("Updated watershed collection failed ID or count checks")
}
if (any(st_is_empty(watersheds)) || !all(st_is_valid(watersheds))) {
  stop("Updated watershed collection contains invalid or empty geometry")
}
if (st_crs(watersheds)$epsg != 4326L) stop("Updated release is not EPSG:4326")

watershed_discharge_key <- paste(
  watersheds$LTER,
  watersheds$Stream_Name,
  sep = "::"
)
primary_match_counts <- vapply(
  release_discharge_key,
  function(key) sum(watershed_discharge_key == key),
  integer(1L)
)
discharge_rows <- match(release_discharge_key, watershed_discharge_key)
unmatched_discharge <- release_discharge[is.na(discharge_rows), , drop = FALSE]
if (!identical(unname(sort(primary_match_counts)), c(0L, rep(1L, 177L))) ||
    sum(!is.na(discharge_rows)) != 177L ||
    nrow(unmatched_discharge) != 1L ||
    unmatched_discharge$Spatial_LTER != "PIE" ||
    unmatched_discharge$Stream_Name != "Parker") {
  stop("Primary watershed discharge matching changed from 177 plus PIE Parker")
}
matched_updates <- !is.na(discharge_rows)
watersheds$Discharge_File_Name[discharge_rows[matched_updates]] <-
  release_discharge$Discharge_File_Name[matched_updates]
if (!identical(
  as.character(watersheds$Discharge_File_Name[discharge_rows[matched_updates]]),
  as.character(release_discharge$Discharge_File_Name[matched_updates])
)) {
  stop("A staged discharge filename was not applied to the watershed release")
}

prior_unaffected <- prior[match(unaffected$site_id, prior$site_id), ]
expected_unaffected <- watersheds[match(unaffected$site_id, watersheds$site_id), ]
non_discharge_fields <- setdiff(
  names(plain_attributes(prior_unaffected)),
  "Discharge_File_Name"
)
if (!identical(
  plain_attributes(prior_unaffected)[non_discharge_fields],
  plain_attributes(expected_unaffected)[non_discharge_fields]
) ||
    !identical(geometry_binary(prior_unaffected), geometry_binary(unaffected))) {
  stop("An unaffected geometry or attribute changed in memory")
}

version_counts <- table(watersheds$Spatial_Data_Version)
if (!identical(
  as.integer(version_counts[c("1", "2", "3")]),
  c(199L, 188L, 767L)
)) {
  stop("Spatial version counts are not 199, 188, and 767")
}

### Stage and verify release files

dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
output_root <- normalizePath(output_root)
final_paths <- c(gpkg_path, zip_path, alias_path, qa_path, update_path)
if (!overwrite && any(file.exists(final_paths))) {
  stop("Release output exists; use --overwrite true to replace it")
}

stage_dir <- tempfile(".watershed-release-20260815-", tmpdir = output_root)
dir.create(stage_dir)
stage_dir <- normalizePath(stage_dir)
on.exit(unlink(stage_dir, recursive = TRUE), add = TRUE)

stage_gpkg <- file.path(stage_dir, basename(gpkg_path))
stage_zip <- file.path(stage_dir, basename(zip_path))
stage_alias <- file.path(stage_dir, basename(alias_path))
stage_qa <- file.path(stage_dir, basename(qa_path))
stage_update <- file.path(stage_dir, basename(update_path))
shapefile_dir <- file.path(stage_dir, paste0(output_name, "_shapefile"))
dir.create(shapefile_dir)
shapefile_path <- file.path(shapefile_dir, paste0(output_name, ".shp"))

st_write(
  watersheds,
  stage_gpkg,
  layer = output_name,
  quiet = TRUE
)

shapefile_attributes <- data.frame(
  site_id = watersheds$site_id,
  run_grp = watersheds$run_group,
  LTER = watersheds$LTER,
  Shpfl_N = watersheds$Shapefile_Name,
  Strm_Nm = watersheds$Stream_Name,
  Dsc_F_N = watersheds$Discharge_File_Name,
  hydrshds_s = watersheds$hydrosheds_used,
  hydrshds_d = watersheds$hydrosheds_id,
  expc__2 = watersheds$expected_area_km2,
  drn_src = watersheds$drn_src,
  plyg__2 = watersheds$polygon_area_km2,
  tiny_ws = watersheds$tiny_ws,
  src_typ = watersheds$source_type,
  sorc_fl = watersheds$source_file,
  spat_ver = watersheds$Spatial_Data_Version,
  stringsAsFactors = FALSE
)
shapefile_out <- st_sf(
  shapefile_attributes,
  geom = st_geometry(watersheds),
  crs = 4326
)
st_write(
  shapefile_out,
  shapefile_path,
  layer_options = "ENCODING=UTF-8",
  quiet = TRUE
)

write.table(
  aliases,
  stage_alias,
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
write.table(
  updates,
  stage_update,
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)

old_working_directory <- getwd()
on.exit(setwd(old_working_directory), add = TRUE)
setwd(shapefile_dir)
utils::zip(
  zipfile = stage_zip,
  files = list.files(shapefile_dir),
  flags = "-q"
)
setwd(old_working_directory)

gpkg_check <- st_read(stage_gpkg, layer = output_name, quiet = TRUE)
zip_check_dir <- file.path(stage_dir, "shapefile-zip-check")
dir.create(zip_check_dir)
unzip(stage_zip, exdir = zip_check_dir)
zip_shape_path <- list.files(
  zip_check_dir,
  pattern = "[.]shp$",
  full.names = TRUE
)
if (length(zip_shape_path) != 1L) {
  stop("Staged shapefile ZIP does not contain exactly one shapefile")
}
shape_check <- st_read(zip_shape_path, quiet = TRUE)
alias_check <- read.delim(
  stage_alias,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  check.names = FALSE
)
update_check <- read.delim(
  stage_update,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  check.names = FALSE
)

if (nrow(gpkg_check) != expected_final_count ||
    anyDuplicated(gpkg_check$site_id) ||
    any(st_is_empty(gpkg_check)) ||
    !all(st_is_valid(gpkg_check))) {
  stop("Staged GeoPackage failed final geometry QA")
}
if (nrow(shape_check) != expected_final_count ||
    any(st_is_empty(shape_check)) ||
    !all(st_is_valid(shape_check)) ||
    !identical(
      as.integer(table(shape_check$spat_ver)[c("1", "2", "3")]),
      c(199L, 188L, 767L)
    )) {
  stop("Staged shapefile failed final geometry QA")
}
if (nrow(alias_check) != expected_alias_rows ||
    length(unique(alias_check$site_id)) != expected_final_count ||
    nrow(update_check) != expected_update_rows) {
  stop("Staged alias or update table failed final QA")
}

gpkg_unaffected <- gpkg_check[match(unaffected$site_id, gpkg_check$site_id), ]
gpkg_replacements <- gpkg_check[match(
  replacements$site_id,
  gpkg_check$site_id
), ]
attributes_unchanged <- identical(
  plain_attributes(expected_unaffected),
  plain_attributes(gpkg_unaffected)
)
geometry_unchanged <- identical(
  geometry_binary(prior_unaffected),
  geometry_binary(gpkg_unaffected)
)
replacement_attributes_identical <- identical(
  plain_attributes(watersheds[match(
    replacements$site_id,
    watersheds$site_id
  ), ]),
  plain_attributes(gpkg_replacements)
)
replacement_geometry_identical <- identical(
  geometry_binary(replacements),
  geometry_binary(gpkg_replacements)
)
if (!attributes_unchanged || !geometry_unchanged) {
  stop("An unaffected geometry or attribute changed after GeoPackage write")
}
if (!replacement_attributes_identical || !replacement_geometry_identical) {
  stop("A replacement geometry or attribute changed after GeoPackage write")
}

replacement_area_difference_percent <- 100 * abs(
  replacements$polygon_area_km2 - replacements$expected_area_km2
) / replacements$expected_area_km2
if (max(replacement_area_difference_percent) > 5) {
  stop("A replacement geometry differs from its official area by more than 5%")
}

zip_members <- unzip(stage_zip, list = TRUE)$Name
required_extensions <- c(".shp", ".shx", ".dbf", ".prj")
if (!all(vapply(
  required_extensions,
  function(extension) any(endsWith(zip_members, extension)),
  logical(1L)
))) {
  stop("Shapefile ZIP is missing a required member")
}

site_table_md5_after <- unname(tools::md5sum(site_table_path))
if (!identical(site_table_md5_before, site_table_md5_after)) {
  stop("The source Site Reference Table changed during the build")
}
input_md5_after <- unname(tools::md5sum(input_files))
if (!identical(input_file_records$md5, input_md5_after)) {
  stop("A watershed release input changed during the build")
}
input_file_records$md5_after <- input_md5_after
input_file_records$unchanged_during_build <- TRUE

qa <- list(
  built_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  source_site_table = normalizePath(site_table_path),
  source_site_table_md5_before = site_table_md5_before,
  source_site_table_md5_after = site_table_md5_after,
  source_site_table_unchanged = identical(
    site_table_md5_before,
    site_table_md5_after
  ),
  input_files = input_file_records,
  prior_release = normalizePath(prior_gpkg),
  source_geometries = c(
    newfoundland = normalizePath(newfoundland_source),
    chile = normalizePath(chile_source)
  ),
  source_checks = data.frame(
    source = c("Newfoundland WQMA", "Chile CAMELS-CL"),
    candidates = c(64L, 3L),
    accepted = c(64L, 2L),
    stringsAsFactors = FALSE
  ),
  coordinate_review = data.frame(
    Chemistry_Site_ID = coordinate_review_ids,
    Site_to_Official_Station_m = newfoundland_qa$Site_to_Official_Station_m[
      match(coordinate_review_ids, newfoundland_qa$Chemistry_Site_ID)
    ],
    status = newfoundland_qa$QA_Status[
      match(coordinate_review_ids, newfoundland_qa$Chemistry_Site_ID)
    ],
    stringsAsFactors = FALSE
  ),
  discharge_overlay = list(
    staged_rows = nrow(discharge_updates),
    spatial_rows = nrow(release_discharge),
    primary_geometry_rows_updated = sum(matched_updates),
    alias_only_assignment = data.frame(
      LTER = unmatched_discharge$Spatial_LTER,
      Stream_Name = unmatched_discharge$Stream_Name,
      Discharge_File_Name = unmatched_discharge$Discharge_File_Name,
      stringsAsFactors = FALSE
    )
  ),
  change_checks = data.frame(
    update_rows = nrow(updates),
    old_geometry_ids_replaced = length(old_replaced_ids),
    new_geometry_rows = nrow(replacements),
    unaffected_geometry_rows = nrow(unaffected),
    final_geometry_rows = nrow(watersheds),
    alias_rows = nrow(aliases),
    unique_alias_site_ids = length(unique(aliases$site_id)),
    unique_newfoundland_names = length(unique(newfoundland_updates$Shapefile_Name_new)),
    stringsAsFactors = FALSE
  ),
  geometry_checks = data.frame(
    invalid_geometries = sum(!st_is_valid(gpkg_check)),
    empty_geometries = sum(st_is_empty(gpkg_check)),
    crs_epsg = st_crs(gpkg_check)$epsg,
    unaffected_attributes_identical = attributes_unchanged,
    unaffected_geometry_binary_identical = geometry_unchanged,
    replacement_attributes_identical = replacement_attributes_identical,
    replacement_geometry_binary_identical = replacement_geometry_identical,
    maximum_replacement_area_difference_percent = max(
      replacement_area_difference_percent
    ),
    stringsAsFactors = FALSE
  ),
  version_counts = as.data.frame(version_counts),
  zip_members = zip_members,
  outputs = c(
    geopackage = gpkg_path,
    shapefile_zip = zip_path,
    aliases = alias_path,
    site_reference_updates = update_path,
    qa = qa_path
  ),
  temporary_library_used = FALSE,
  temporary_unzipped_shapefile_removed_after_qa = TRUE
)
qa$output_files <- file_records(
  c(stage_gpkg, stage_zip, stage_alias, stage_update),
  c("geopackage", "shapefile_zip", "site_aliases", "site_reference_updates")
)
qa$output_files$path <- normalizePath(
  final_paths[c(1L, 2L, 3L, 5L)],
  mustWork = FALSE
)
saveRDS(qa, stage_qa)

staged_paths <- c(stage_gpkg, stage_zip, stage_alias, stage_qa, stage_update)
backup_dir <- tempfile(".watershed-release-backup-", tmpdir = output_root)
dir.create(backup_dir)
backup_paths <- file.path(
  backup_dir,
  sprintf("%02d_%s", seq_along(final_paths), basename(final_paths))
)
existed <- file.exists(final_paths)
backed <- logical(length(final_paths))
installed <- logical(length(final_paths))
rollback_required <- TRUE
on.exit({
  if (rollback_required) {
    for (index in which(installed)) {
      if (file.exists(final_paths[[index]])) file.remove(final_paths[[index]])
    }
    for (index in which(backed)) {
      file.rename(backup_paths[[index]], final_paths[[index]])
    }
  }
  if (dir.exists(backup_dir)) unlink(backup_dir, recursive = TRUE)
}, add = TRUE)

for (index in which(existed)) {
  backed[[index]] <- file.rename(final_paths[[index]], backup_paths[[index]])
  if (!backed[[index]]) {
    stop("Could not stage an existing release output for replacement")
  }
}
for (index in seq_along(final_paths)) {
  installed[[index]] <- file.rename(staged_paths[[index]], final_paths[[index]])
  if (!installed[[index]]) {
    stop("Could not install all watershed release outputs")
  }
}

installed_gpkg <- st_read(gpkg_path, layer = output_name, quiet = TRUE)
installed_alias <- read.delim(
  alias_path,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE
)
installed_update <- read.delim(
  update_path,
  sep = "\t",
  quote = "",
  comment.char = "",
  stringsAsFactors = FALSE,
  check.names = FALSE
)
installed_qa <- readRDS(qa_path)
if (nrow(installed_gpkg) != expected_final_count ||
    nrow(installed_alias) != expected_alias_rows ||
    nrow(installed_update) != expected_update_rows ||
    installed_qa$change_checks$update_rows != expected_update_rows ||
    !identical(as_text_frame(installed_alias), as_text_frame(alias_check)) ||
    !identical(as_text_frame(installed_update), as_text_frame(update_check)) ||
    !identical(
      unname(tools::md5sum(final_paths[c(1L, 2L, 3L, 5L)])),
      qa$output_files$md5
    )) {
  stop("Installed watershed release failed final read-back checks")
}

rollback_required <- FALSE
unlink(backup_dir, recursive = TRUE)

unlink(stage_dir, recursive = TRUE)
if (dir.exists(stage_dir)) stop("Temporary watershed staging directory remains")

message("Built 1,154 watersheds for 1,196 site aliases")
message("Derived Site Reference update rows: 66")
message("GeoPackage: ", gpkg_path)
message("Shapefile ZIP: ", zip_path)
