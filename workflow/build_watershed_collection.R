# Build the Earth Engine watershed collection from the finalized site table
# and the exact versioned watershed library named by that table.

suppressPackageStartupMessages({
  library(dplyr)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
site_table_path <- cli_value(args, "--site-table", required = TRUE)
shapefile_root <- cli_value(args, "--shapefile-root", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
output_name <- cli_value(args, "--output-name", "watersheds")
expected_count <- suppressWarnings(as.integer(cli_value(args, "--expected-count", "")))
overwrite <- cli_boolean(args, "--overwrite", FALSE)
shared_area_tolerance_pct <- as.numeric(
  cli_value(args, "--shared-area-tolerance-pct", "2")
)

if (!dir.exists(shapefile_root)) {
  stop("Missing versioned watershed library: ", shapefile_root, call. = FALSE)
}
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
output_root <- normalizePath(output_root)

site_table <- read_workflow_table(site_table_path)
required <- c(
  "LTER", "Stream_Name", "Spatial_Data_Version", "Has_Spatial_Data",
  "Shapefile_Name", "Shapefile_CRS_EPSG", "Shapefile_Source",
  "drainSqKm", "drainSqKm_source"
)
require_columns(site_table, required, "site table")
if (!"Discharge_File_Name" %in% names(site_table)) {
  site_table$Discharge_File_Name <- ""
}

rows <- site_table %>%
  mutate(
    Spatial_Data_Version = suppressWarnings(as.integer(Spatial_Data_Version)),
    drainSqKm = suppressWarnings(as.numeric(drainSqKm)),
    geometry_key = paste(LTER, Shapefile_Name, sep = "::")
  ) %>%
  filter(
    trimws(Has_Spatial_Data) == "Yes",
    nzchar(trimws(Shapefile_Name)),
    Spatial_Data_Version %in% 1:3
  )
if (!nrow(rows)) stop("The site table contains no spatial rows.", call. = FALSE)

version_conflicts <- rows %>%
  distinct(geometry_key, Spatial_Data_Version) %>%
  count(geometry_key) %>%
  filter(n > 1L)
if (nrow(version_conflicts)) {
  stop(
    "The same LTER/shapefile name appears in multiple spatial versions: ",
    paste(version_conflicts$geometry_key, collapse = ", "),
    call. = FALSE
  )
}

first_text <- function(value) {
  value <- trimws(as.character(value))
  value <- value[nzchar(value)]
  if (length(value)) value[[1]] else ""
}

source_id <- function(attributes) {
  candidates <- grep(
    "^(hydro_id|hydrosheds_id|hybas_id|outlet|outlet_id|out_aroid)$",
    names(attributes),
    ignore.case = TRUE,
    value = TRUE
  )
  if (!length(candidates)) return("")
  first_text(attributes[[candidates[[1]]]])
}

read_geometry <- function(group) {
  row <- group[1, , drop = FALSE]
  shape_path <- file.path(
    shapefile_root,
    paste0("data_release_", row$Spatial_Data_Version),
    row$Shapefile_Name,
    paste0(row$Shapefile_Name, ".shp")
  )
  if (!file.exists(shape_path)) {
    stop("Missing watershed named by the site table: ", shape_path, call. = FALSE)
  }

  watershed <- st_read(shape_path, quiet = TRUE)
  if (!nrow(watershed) || any(st_is_empty(watershed))) {
    stop("Empty watershed: ", shape_path, call. = FALSE)
  }
  if (is.na(st_crs(watershed))) {
    epsg <- suppressWarnings(as.integer(row$Shapefile_CRS_EPSG))
    if (!is.finite(epsg)) {
      stop("Watershed lacks a CRS and the table has no numeric EPSG: ", shape_path)
    }
    st_crs(watershed) <- epsg
  }
  attributes <- st_drop_geometry(watershed)
  geometry <- st_union(st_geometry(st_make_valid(st_transform(watershed, 4326))))
  feature <- st_sf(geometry = geometry, crs = 4326)
  polygon_area_km2 <- as.numeric(st_area(st_transform(feature, 6933))) / 1e6

  reported_areas <- sort(unique(group$drainSqKm[is.finite(group$drainSqKm)]))
  if (length(reported_areas) > 1L) {
    difference_pct <- 100 * diff(range(reported_areas)) / max(reported_areas)
    if (difference_pct > shared_area_tolerance_pct) {
      stop(
        "Rows sharing ", row$geometry_key,
        " have conflicting drainage areas (", round(difference_pct, 2), "%)."
      )
    }
  }
  expected_area_km2 <- if (length(reported_areas)) reported_areas[[1]] else NA_real_

  feature$site_id <- paste(
    normalize_key(row$LTER),
    normalize_key(row$Shapefile_Name),
    sep = "__"
  )
  feature$run_group <- row$LTER
  feature$LTER <- row$LTER
  feature$Shapefile_Name <- row$Shapefile_Name
  feature$Stream_Name <- first_text(group$Stream_Name)
  feature$Discharge_File_Name <- first_text(group$Discharge_File_Name)
  feature$hydrosheds_used <- grepl(
    "hydrobasins|hydrosheds",
    first_text(group$Shapefile_Source),
    ignore.case = TRUE
  )
  feature$hydrosheds_id <- source_id(attributes)
  feature$expected_area_km2 <- expected_area_km2
  feature$drn_src <- first_text(group$drainSqKm_source)
  feature$polygon_area_km2 <- polygon_area_km2
  feature$tiny_ws <- polygon_area_km2 <= 10
  feature$source_type <- first_text(group$Shapefile_Source)
  feature$source_file <- file.path(
    paste0("data_release_", row$Spatial_Data_Version),
    row$Shapefile_Name,
    paste0(row$Shapefile_Name, ".shp")
  )
  feature$Spatial_Data_Version <- row$Spatial_Data_Version
  feature
}

groups <- split(rows, rows$geometry_key)
watersheds <- do.call(rbind, lapply(groups, read_geometry))
watersheds <- watersheds[order(watersheds$site_id), ]
if (anyDuplicated(watersheds$site_id)) {
  stop("Generated site IDs are not unique.", call. = FALSE)
}
if (any(st_is_empty(watersheds)) || !all(st_is_valid(watersheds))) {
  stop("Generated watershed collection contains invalid geometry.", call. = FALSE)
}
if (is.finite(expected_count) && nrow(watersheds) != expected_count) {
  stop(
    "Generated ", nrow(watersheds), " watersheds; expected ", expected_count, ".",
    call. = FALSE
  )
}

alias_table <- rows %>%
  transmute(
    site_id = paste(normalize_key(LTER), normalize_key(Shapefile_Name), sep = "__"),
    LTER,
    Stream_Name,
    Shapefile_Name,
    Spatial_Data_Version
  ) %>%
  distinct() %>%
  arrange(site_id, LTER, Stream_Name)

gpkg_path <- file.path(output_root, paste0(output_name, ".gpkg"))
shapefile_dir <- file.path(output_root, paste0(output_name, "_shapefile"))
shapefile_path <- file.path(shapefile_dir, paste0(output_name, ".shp"))
zip_path <- file.path(output_root, paste0(output_name, "_shapefile.zip"))
alias_path <- file.path(output_root, paste0(output_name, "_site_aliases.tsv"))
qa_path <- file.path(output_root, paste0(output_name, "_qa.rds"))

existing_outputs <- c(gpkg_path, zip_path, alias_path, qa_path)
if (!overwrite && (any(file.exists(existing_outputs)) || dir.exists(shapefile_dir))) {
  stop("Output already exists. Use --overwrite true to replace it.", call. = FALSE)
}
if (overwrite) {
  unlink(existing_outputs[file.exists(existing_outputs)])
  if (dir.exists(shapefile_dir)) unlink(shapefile_dir, recursive = TRUE)
}
dir.create(shapefile_dir, recursive = TRUE, showWarnings = FALSE)

st_write(watersheds, gpkg_path, quiet = TRUE)
shapefile_out <- watersheds %>%
  transmute(
    site_id,
    run_grp = run_group,
    LTER,
    Shpfl_N = Shapefile_Name,
    Strm_Nm = Stream_Name,
    Dsc_F_N = Discharge_File_Name,
    hydrshds_s = hydrosheds_used,
    hydrshds_d = hydrosheds_id,
    expc__2 = expected_area_km2,
    drn_src,
    plyg__2 = polygon_area_km2,
    tiny_ws,
    src_typ = source_type,
    sorc_fl = source_file
  )
st_write(shapefile_out, shapefile_path, quiet = TRUE)

old_working_directory <- getwd()
on.exit(setwd(old_working_directory), add = TRUE)
setwd(shapefile_dir)
utils::zip(
  zipfile = zip_path,
  files = list.files(shapefile_dir),
  flags = "-q"
)
setwd(old_working_directory)

write.table(
  alias_table,
  alias_path,
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
qa <- list(
  built_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  site_table = normalizePath(site_table_path),
  shapefile_root = normalizePath(shapefile_root),
  watershed_count = nrow(watersheds),
  site_row_count = nrow(alias_table),
  version_counts = as.data.frame(table(watersheds$Spatial_Data_Version)),
  outputs = c(gpkg = gpkg_path, shapefile_zip = zip_path, aliases = alias_path)
)
saveRDS(qa, qa_path)

cat("Built", nrow(watersheds), "watersheds for", nrow(alias_table), "site rows.\n")
cat("GeoPackage:", gpkg_path, "\n")
cat("Shapefile ZIP:", zip_path, "\n")
cat("Alias table:", alias_path, "\n")
