#!/usr/bin/Rscript

suppressPackageStartupMessages(library(sf))
source(file.path("workflow", "lib", "workflow_helpers.R"))

### Settings

args <- commandArgs(trailingOnly = TRUE)

default_input <- file.path(
  "..",
  "data-workflow_disc-chem",
  "outputs",
  "019fce13-0564-7cd1-a0df-692029416ecb",
  "spatial",
  "final_site_catchments",
  "SiSyn_all_154_site_catchments_20260804.gpkg"
)

input_file <- if (length(args) >= 1L) args[[1L]] else default_input
output_dir <- if (length(args) >= 2L) {
  args[[2L]]
} else {
  file.path("generated_outputs", "watersheds-20260815")
}

watershed_service_url <- paste0(
  "https://maps.gov.nl.ca/gsdw/rest/services/water/Stations/",
  "FeatureServer/4/query"
)
station_service_url <- paste0(
  "https://maps.gov.nl.ca/gsdw/rest/services/water/Stations/",
  "FeatureServer/2/query"
)
retrieved_date <- as.Date("2026-08-15")
batch_size <- 8L
boundary_tolerance_m <- 2000

source_dir <- file.path(output_dir, "source")
site_dir <- file.path(output_dir, "per-site-gpkg")
source_file <- file.path(
  source_dir,
  "newfoundland-labrador-wqma-watersheds-20260815.gpkg"
)
combined_file <- file.path(
  output_dir,
  "SiSyn_all_154_site_catchments_20260815.gpkg"
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

query_batch <- function(station_ids, query_url) {
  station_values <- paste0("'", station_ids, "'", collapse = ",")
  where <- paste0("STATION_NUM IN (", station_values, ")")
  query <- paste0(
    query_url,
    "?where=", URLencode(where, reserved = TRUE),
    "&outFields=*&returnGeometry=true&outSR=4326",
    "&geometryPrecision=6&f=geojson"
  )
  destination <- tempfile(fileext = ".geojson")
  on.exit(unlink(destination), add = TRUE)

  status <- download.file(
    query,
    destination,
    method = "libcurl",
    mode = "wb",
    quiet = TRUE
  )
  if (!identical(status, 0L)) {
    stop("Official watershed request failed for: ", paste(station_ids, collapse = ", "))
  }

  result <- st_read(destination, quiet = TRUE, stringsAsFactors = FALSE)
  if (nrow(result) != length(station_ids)) {
    stop(
      "Expected ", length(station_ids), " official watersheds but received ",
      nrow(result), " for: ", paste(station_ids, collapse = ", ")
    )
  }
  result
}

distance_to_boundary <- function(points, polygons) {
  points_projected <- st_transform(points, 3347)
  polygons_projected <- st_transform(polygons, 3347)
  as.numeric(st_distance(
    points_projected,
    st_boundary(polygons_projected),
    by_element = TRUE
  ))
}

### Read current catchments

if (!file.exists(input_file)) {
  stop("Current 154-site catchment file not found: ", input_file)
}

current <- st_transform(st_read(input_file, quiet = TRUE), 4326)
if (nrow(current) != 154L) {
  stop("Expected 154 current catchments; found ", nrow(current))
}

nl_rows <- current$Source_Key == "Canada_ECCC_WSC" &
  grepl("^NF", current$Chemistry_Site_ID)
nl_current <- current[nl_rows, ]

if (nrow(nl_current) != 64L || anyDuplicated(nl_current$Chemistry_Site_ID)) {
  stop("Expected 64 unique Newfoundland and Labrador site IDs")
}

### Retrieve official watersheds

station_ids <- sort(nl_current$Chemistry_Site_ID)
batches <- split(station_ids, ceiling(seq_along(station_ids) / batch_size))
official <- do.call(rbind, lapply(
  batches,
  query_batch,
  query_url = watershed_service_url
))
official <- st_transform(official, 4326)
official <- st_make_valid(official)
official <- st_cast(official, "MULTIPOLYGON", warn = FALSE)

official_points <- do.call(rbind, lapply(
  batches,
  query_batch,
  query_url = station_service_url
))
official_points <- st_transform(official_points, 4326)

if (nrow(official) != 64L || anyDuplicated(official$STATION_NUM)) {
  stop("Official source did not return 64 unique station IDs")
}
if (!setequal(official$STATION_NUM, station_ids)) {
  stop("Official watershed IDs do not match the 64 requested site IDs")
}
if (nrow(official_points) != 64L || anyDuplicated(official_points$STATION_NUM)) {
  stop("Official station source did not return 64 unique station IDs")
}
if (!setequal(official_points$STATION_NUM, station_ids)) {
  stop("Official station IDs do not match the 64 requested site IDs")
}
if (any(!st_is_valid(official)) || any(st_is_empty(official))) {
  stop("Official watershed source contains invalid or empty geometry")
}
if (any(st_is_empty(official_points))) {
  stop("Official station source contains empty geometry")
}

official <- official[match(station_ids, official$STATION_NUM), ]
official_points <- official_points[match(station_ids, official_points$STATION_NUM), ]
official$Source_URL <- sub("/query$", "", watershed_service_url)
official$Retrieved_Date <- retrieved_date
official_points$Source_URL <- sub("/query$", "", station_service_url)
official_points$Retrieved_Date <- retrieved_date

### Quantitative QA

nl_current <- nl_current[match(station_ids, nl_current$Chemistry_Site_ID), ]
site_points <- st_as_sf(
  st_drop_geometry(nl_current),
  coords = c("Site_Longitude", "Site_Latitude"),
  crs = 4326,
  remove = FALSE
)

official_projected <- st_transform(official, "ESRI:102001")
current_projected <- st_transform(nl_current, "ESRI:102001")
official_area <- as.numeric(st_area(official_projected)) / 1e6
current_area <- as.numeric(st_area(current_projected)) / 1e6
official_area_difference <- percent_difference(official_area, official$AREA_SQKM)
current_area_difference <- percent_difference(current_area, official$AREA_SQKM)

point_in_official <- lengths(st_intersects(site_points, official)) > 0L
point_in_current <- lengths(st_intersects(site_points, nl_current)) > 0L
official_boundary_distance <- distance_to_boundary(site_points, official)
current_boundary_distance <- distance_to_boundary(site_points, nl_current)
site_to_official_station <- as.numeric(st_distance(
  st_transform(site_points, 3347),
  st_transform(official_points, 3347),
  by_element = TRUE
))
official_station_boundary_distance <- distance_to_boundary(official_points, official)

official_attribute_points <- st_as_sf(
  st_drop_geometry(official_points),
  coords = c("LONGITUDE", "LATITUDE"),
  crs = 4326,
  remove = FALSE
)
official_point_attribute_difference <- as.numeric(st_distance(
  st_transform(official_points, 3347),
  st_transform(official_attribute_points, 3347),
  by_element = TRUE
))

intersection_area <- vapply(seq_len(nrow(official)), function(row_index) {
  intersection <- suppressWarnings(st_intersection(
    official_projected[row_index, ],
    current_projected[row_index, ]
  ))
  if (nrow(intersection) == 0L) 0 else sum(as.numeric(st_area(intersection))) / 1e6
}, numeric(1L))

official_overlap_percent <- 100 * intersection_area / official_area
current_overlap_percent <- 100 * intersection_area / current_area

qa_pass <-
  official_area_difference <= 5 &
  official_boundary_distance <= boundary_tolerance_m &
  official_station_boundary_distance <= boundary_tolerance_m

coordinate_review_needed <- site_to_official_station > boundary_tolerance_m

qa_note <- ifelse(
  qa_pass & coordinate_review_needed,
  paste(
    "Accepted polygon; review stored site coordinate because it differs by more",
    "than 2 km from the official WQMA station point"
  ),
  ifelse(
    qa_pass,
    paste(
      "Accepted: exact WQMA station ID, valid geometry, official area agreement,",
      "and current and official station coordinates no more than 2 km apart"
    ),
    paste(
      "Retained current catchment: official polygon failed area or site-coordinate QA"
    )
  )
)

qa <- st_sf(
  Chemistry_Site_ID = station_ids,
  Stream_Name = official$STATION_NAME,
  Official_Area_Attribute_km2 = official$AREA_SQKM,
  Official_Geometry_Area_km2 = official_area,
  Official_Area_Difference_Percent = official_area_difference,
  Current_Geometry_Area_km2 = current_area,
  Current_to_Official_Area_Difference_Percent = current_area_difference,
  Site_Inside_Official = point_in_official,
  Site_Inside_Current = point_in_current,
  Site_to_Official_Boundary_m = official_boundary_distance,
  Site_to_Current_Boundary_m = current_boundary_distance,
  Official_Station_Latitude = official_points$LATITUDE,
  Official_Station_Longitude = official_points$LONGITUDE,
  Site_to_Official_Station_m = site_to_official_station,
  Official_Station_to_Watershed_Boundary_m = official_station_boundary_distance,
  Official_Point_Attribute_Difference_m = official_point_attribute_difference,
  Coordinate_Review_Needed = coordinate_review_needed,
  Official_Area_Overlapping_Current_Percent = official_overlap_percent,
  Current_Area_Overlapping_Official_Percent = current_overlap_percent,
  Replace_Current = qa_pass,
  QA_Status = qa_note,
  geometry = st_geometry(official)
)

### Write source and QA layers

stage_root <- tempfile("newfoundland-watersheds-", tmpdir = output_dir)
dir.create(stage_root)
on.exit(unlink(stage_root, recursive = TRUE), add = TRUE)
stage_source <- file.path(stage_root, basename(source_file))
stage_combined <- file.path(stage_root, basename(combined_file))
stage_site_dir <- file.path(stage_root, basename(site_dir))
dir.create(stage_site_dir)

st_write(official, stage_source, layer = "official_watersheds", quiet = TRUE)
st_write(
  official_points,
  stage_source,
  layer = "official_stations",
  append = FALSE,
  quiet = TRUE
)
st_write(qa, stage_source, layer = "qa", append = FALSE, quiet = TRUE)

### Build updated catchments

updated <- current
accepted <- which(qa_pass)
updated_rows <- which(nl_rows)[match(station_ids[accepted], current$Chemistry_Site_ID[nl_rows])]

st_geometry(updated)[updated_rows] <- st_geometry(official)[accepted]
updated$Final_Catchment_Area_km2[updated_rows] <- official$AREA_SQKM[accepted]
updated$Catchment_Area_Source[updated_rows] <-
  "Government of Newfoundland and Labrador WQMA official watershed"
updated$Catchment_Polygon_Source[updated_rows] <-
  "Government of Newfoundland and Labrador WQMA watershed"
updated$Catchment_Polygon_Source_File[updated_rows] <- basename(source_file)
updated$QA_Status[updated_rows] <- qa_note[accepted]

st_write(updated, stage_combined, layer = "site_catchments", quiet = TRUE)

for (row_index in seq_len(nrow(updated))) {
  source_key <- safe_file_name(updated$Source_Key[[row_index]])
  site_id <- safe_file_name(updated$Chemistry_Site_ID[[row_index]])
  staged_site_file <- file.path(
    stage_site_dir,
    paste0(source_key, "_", site_id, "_catchment.gpkg")
  )
  st_write(
    updated[row_index, ],
    staged_site_file,
    layer = "catchment",
    quiet = TRUE
  )
}

### Final checks

if (any(!st_is_valid(updated)) || any(st_is_empty(updated))) {
  stop("Updated catchment collection contains invalid or empty geometry")
}
source_check <- st_read(stage_source, layer = "official_watersheds", quiet = TRUE)
qa_check <- st_read(stage_source, layer = "qa", quiet = TRUE)
combined_check <- st_read(stage_combined, layer = "site_catchments", quiet = TRUE)
if (
  nrow(source_check) != 64L || nrow(qa_check) != 64L ||
    nrow(combined_check) != 154L ||
    any(!st_is_valid(combined_check)) || any(st_is_empty(combined_check)) ||
    length(list.files(stage_site_dir, pattern = "[.]gpkg$")) != 154L
) {
  stop("Expected 154 per-site GeoPackages")
}

install_checked_outputs(
  c(stage_source, stage_combined, stage_site_dir),
  c(source_file, combined_file, site_dir),
  backup_root = output_dir
)
if (nrow(st_read(combined_file, quiet = TRUE)) != 154L ||
    length(list.files(site_dir, pattern = "[.]gpkg$")) != 154L) {
  stop("Installed Newfoundland watershed outputs failed read-back QA")
}

message("Official Newfoundland and Labrador watersheds retrieved: ", nrow(official))
message("Replacements accepted: ", sum(qa_pass))
message("Current catchments retained: ", sum(!qa_pass))
message("Official source and QA: ", source_file)
message("Updated 154-site catchments: ", combined_file)
