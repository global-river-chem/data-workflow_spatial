# ---- inputs and review limits ----

suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
archive_path <- cli_value(args, "--source-archive", required = TRUE)
targets_path <- cli_value(args, "--targets", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
maximum_area_difference_pct <- as.numeric(
  cli_value(args, "--maximum-area-difference-pct", "1")
)
maximum_station_distance_m <- as.numeric(
  cli_value(args, "--maximum-station-distance-m", "2000")
)
minimum_nesting_pct <- as.numeric(
  cli_value(args, "--minimum-nesting-pct", "99.9")
)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

# reject invalid review limits before reading the source archive
limits <- c(maximum_area_difference_pct, maximum_station_distance_m, minimum_nesting_pct)
if (any(!is.finite(limits)) || any(limits < 0) || minimum_nesting_pct > 100) {
  stop("Review limits must be finite and nonnegative, with nesting at most 100 percent", call. = FALSE)
}

archive_path <- require_input_file(archive_path, "GLORICH source archive")
targets <- read_workflow_table(targets_path)
if (!nrow(targets)) stop("The GLORICH target table is empty", call. = FALSE)
require_columns(
  targets,
  c(
    "LTER", "Stream_Name", "Shapefile_Name", "Spatial_Data_Version",
    "Stat_Id", "HydroBASINS_ID", "Latitude", "Longitude",
    "reference_area_km2", "downstream_order"
  ),
  "GLORICH target table"
)

spatial_versions <- suppressWarnings(as.integer(targets$Spatial_Data_Version))
if (
  any(!is.finite(spatial_versions)) ||
    any(spatial_versions != as.numeric(targets$Spatial_Data_Version)) ||
    any(spatial_versions < 1L)
) {
  stop("Spatial data versions must be positive whole numbers", call. = FALSE)
}
targets$Spatial_Data_Version <- spatial_versions

downstream_order <- suppressWarnings(as.integer(targets$downstream_order))
if (
  any(!is.finite(downstream_order)) ||
    any(downstream_order != as.numeric(targets$downstream_order)) ||
    !identical(sort(downstream_order), seq_len(nrow(targets)))
) {
  stop(
    "Downstream order must contain each whole number from 1 to the row count",
    call. = FALSE
  )
}
targets$downstream_order <- downstream_order

hydrobasins_ids <- as.character(targets$HydroBASINS_ID)
if (
  any(!grepl("^[0-9]{10}$", hydrobasins_ids)) ||
    anyDuplicated(hydrobasins_ids)
) {
  stop("HydroBASINS identifiers must be unique 10-digit values", call. = FALSE)
}
targets$HydroBASINS_ID <- hydrobasins_ids

if (
  anyDuplicated(targets$Stat_Id) ||
    anyDuplicated(targets$Shapefile_Name)
) {
  stop("GLORICH target identifiers must be unique", call. = FALSE)
}

# ---- source catchments ----

# read the published shapes directly from the zip file
source_path <- paste0(
  "/vsizip/", normalizePath(archive_path, mustWork = TRUE),
  "/Shapefiles_GloRiCh/Shapes_GloRiCh/Catchments_v1.shp"
)
catchments <- st_read(source_path, quiet = TRUE)
require_columns(
  catchments,
  c("Stat_Id", "DEM", "Qual", "WS_LVL", "Shape_Leng", "Shape_Area"),
  "GLORICH catchments"
)
if (is.na(st_crs(catchments))) {
  stop("GLORICH catchments have no coordinate system", call. = FALSE)
}

suppressMessages(sf_use_s2(TRUE))
geometries <- vector("list", nrow(targets))
qa_rows <- vector("list", nrow(targets))

# ---- watershed checks ----

# use the published station id to select each watershed
for (index in seq_len(nrow(targets))) {
  target <- targets[index, ]
  source_row <- catchments[
    as.character(catchments$Stat_Id) == as.character(target$Stat_Id),
  ]
  if (nrow(source_row) != 1L) {
    stop(
      "Expected one GLORICH catchment for Stat_Id ", target$Stat_Id,
      call. = FALSE
    )
  }
  if (trimws(source_row$DEM) != "HS15s SA") {
    stop(
      "Expected a South America HydroSHEDS 15-arc-second catchment for Stat_Id ",
      target$Stat_Id,
      call. = FALSE
    )
  }

  recovered <- st_transform(st_make_valid(source_row), 4326)
  source_area_km2 <- as.numeric(source_row$Shape_Area) / 1e6
  # measure the polygon in an equal-area projection so the area is in square meters
  polygon_area_km2 <- as.numeric(
    st_area(st_union(st_transform(recovered, 6933)))
  ) / 1e6
  reference_area_km2 <- as.numeric(target$reference_area_km2)
  source_reference_difference_pct <- 100 *
    (source_area_km2 - reference_area_km2) / reference_area_km2
  polygon_source_difference_pct <- 100 *
    (polygon_area_km2 - source_area_km2) / source_area_km2
  polygon_reference_difference_pct <- 100 *
    (polygon_area_km2 - reference_area_km2) / reference_area_km2

  # check how far the sampling point is from the watershed
  station <- st_sfc(
    st_point(c(as.numeric(target$Longitude), as.numeric(target$Latitude))),
    crs = 4326
  )
  station_distance_m <- as.numeric(st_distance(
    station,
    recovered
  ))

  recovered$shp_name <- target$Shapefile_Name
  recovered$Shape_Area <- NULL
  recovered$area_km2 <- source_area_km2
  recovered$glorich_id <- as.character(target$Stat_Id)
  recovered$hydro_id <- as.character(target$HydroBASINS_ID)
  recovered$src_doi <- "PANGAEA.902360"
  recovered$src_crs <- "ESRI:54012"
  recovered$out_crs <- "EPSG:4326"
  geometries[[index]] <- recovered
  qa_rows[[index]] <- data.frame(
    LTER = target$LTER,
    Stream_Name = target$Stream_Name,
    Shapefile_Name = target$Shapefile_Name,
    Spatial_Data_Version = target$Spatial_Data_Version,
    Stat_Id = target$Stat_Id,
    HydroBASINS_ID = target$HydroBASINS_ID,
    Has_Spatial_Data = "Yes",
    Shapefile_CRS_EPSG = 4326,
    Shapefile_Source = paste(
      "GLORICH 2019 catchment derived from HydroSHEDS",
      "15-arc-second South America"
    ),
    source_area_km2 = source_area_km2,
    drainSqKm = source_area_km2,
    drainSqKm_source = paste0(
      "GLORICH Shape_Area for Stat_ID ", target$Stat_Id,
      ": https://doi.org/10.1594/PANGAEA.902360"
    ),
    reference_area_km2 = reference_area_km2,
    source_reference_difference_pct = source_reference_difference_pct,
    polygon_area_km2 = polygon_area_km2,
    polygon_source_difference_pct = polygon_source_difference_pct,
    polygon_reference_difference_pct = polygon_reference_difference_pct,
    station_distance_m = station_distance_m,
    valid = all(st_is_valid(recovered)),
    stringsAsFactors = FALSE
  )
}

# ---- downstream nesting ----

# compare each watershed with the next one downstream using equal-area polygons
suppressMessages(sf_use_s2(FALSE))
ordered <- order(targets$downstream_order)
nesting_pct <- rep(NA_real_, nrow(targets))
for (position in seq_len(length(ordered) - 1L)) {
  upstream_index <- ordered[[position]]
  downstream_index <- ordered[[position + 1L]]
  upstream <- st_union(st_transform(geometries[[upstream_index]], 6933))
  downstream <- st_union(st_transform(geometries[[downstream_index]], 6933))
  # disjoint polygons share no area
  shared_area <- sum(as.numeric(st_area(st_intersection(upstream, downstream))))
  nesting_pct[[upstream_index]] <- 100 * shared_area / as.numeric(st_area(upstream))
}

if (any(!is.finite(nesting_pct[ordered[-length(ordered)]]))) {
  stop("Could not measure overlap for each upstream catchment", call. = FALSE)
}

qa <- do.call(rbind, qa_rows)
qa$upstream_inside_next_pct <- nesting_pct

failed <- !qa$valid |
  abs(qa$source_reference_difference_pct) > maximum_area_difference_pct |
  abs(qa$polygon_source_difference_pct) > maximum_area_difference_pct |
  abs(qa$polygon_reference_difference_pct) > maximum_area_difference_pct |
  qa$station_distance_m > maximum_station_distance_m |
  (!is.na(qa$upstream_inside_next_pct) &
    qa$upstream_inside_next_pct < minimum_nesting_pct)
failed[is.na(failed)] <- TRUE
if (any(failed)) {
  print(qa[failed, ], row.names = FALSE)
  stop("At least one GLORICH catchment failed review", call. = FALSE)
}

# ---- output files ----

# write shapes and review results only after every watershed passes
output_paths <- file.path(
  output_root,
  paste0("data_release_", targets$Spatial_Data_Version),
  targets$Shapefile_Name,
  paste0(targets$Shapefile_Name, ".shp")
)
qa_path <- file.path(output_root, "glorich_recovery_qa.tsv")
if (
  !overwrite &&
    (any(dir.exists(dirname(output_paths))) || file.exists(qa_path))
) {
  stop("At least one recovery output already exists", call. = FALSE)
}

dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
for (index in seq_len(nrow(targets))) {
  dir.create(dirname(output_paths[[index]]), recursive = TRUE, showWarnings = FALSE)
  st_write(
    geometries[[index]],
    output_paths[[index]],
    delete_layer = overwrite,
    quiet = TRUE
  )
}

write.table(
  qa,
  qa_path,
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
print(qa, row.names = FALSE)
