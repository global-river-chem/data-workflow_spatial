#!/usr/bin/Rscript

suppressPackageStartupMessages(library(sf))
source(file.path("workflow", "lib", "workflow_helpers.R"))

### Settings

args <- commandArgs(trailingOnly = TRUE)

output_dir <- if (length(args) >= 1L) {
  args[[1L]]
} else {
  file.path("generated_outputs", "watersheds-20260815")
}

combined_file <- if (length(args) >= 2L) {
  args[[2L]]
} else {
  file.path(output_dir, "SiSyn_all_154_site_catchments_20260815.gpkg")
}

source_url <- paste0(
  "https://store.pangaea.de/Publications/Alvarez-Garreton-etal_2018/",
  "CAMELScl_catchment_boundaries.zip"
)
source_file <- file.path(
  output_dir,
  "source",
  "chile-camels-cl-watersheds-20260815.gpkg"
)
site_dir <- file.path(output_dir, "per-site-gpkg")
retrieved_date <- as.Date("2026-08-15")
boundary_tolerance_m <- 250

target_sites <- data.frame(
  Chemistry_Site_ID = c("09420001-6", "10322003-3", "10340001-5"),
  gauge_id = c("9420001", "10322003", "10340001"),
  Site_Latitude = c(-39.2752777777778, -40.6655555555556, -40.7877777777778),
  Site_Longitude = c(-72.2344444444444, -72.2544444444444, -72.6908333333333),
  stringsAsFactors = FALSE
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

### Read current catchments

if (!file.exists(combined_file)) {
  stop("Current 154-site catchment file not found: ", combined_file)
}

current <- st_transform(st_read(combined_file, quiet = TRUE), 4326)
if (nrow(current) != 154L || anyDuplicated(current$Chemistry_Site_ID)) {
  stop("Expected 154 unique current catchments")
}

current_rows <- match(target_sites$Chemistry_Site_ID, current$Chemistry_Site_ID)
if (anyNA(current_rows)) {
  stop("One or more Chile sites are absent from the current catchments")
}
current_sites <- current[current_rows, ]

### Retrieve published catchments

download_dir <- tempfile("camels-cl-")
dir.create(download_dir)
on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

archive_file <- file.path(download_dir, "CAMELScl_catchment_boundaries.zip")
status <- download.file(
  source_url,
  archive_file,
  method = "libcurl",
  mode = "wb",
  quiet = TRUE
)
if (!identical(status, 0L)) {
  stop("CAMELS-CL catchment download failed")
}

archive_members <- utils::unzip(archive_file, list = TRUE)$Name
required_members <- paste0(
  "CAMELScl_catchment_boundaries/catchments_camels_cl_v1.3.",
  c("shp", "shx", "dbf", "prj")
)
if (!all(required_members %in% archive_members)) {
  stop("CAMELS-CL archive is missing required shapefile members")
}

utils::unzip(archive_file, exdir = download_dir)
shapefile <- file.path(download_dir, required_members[[1L]])
published_all <- st_transform(st_read(shapefile, quiet = TRUE), 4326)
published_all$gauge_id <- as.character(published_all$gauge_id)

published_rows <- match(target_sites$gauge_id, published_all$gauge_id)
if (anyNA(published_rows)) {
  stop("One or more target gauges are absent from CAMELS-CL")
}

published_raw <- published_all[published_rows, ]
raw_valid <- st_is_valid(published_raw)
published <- st_make_valid(published_raw)
published <- st_cast(published, "MULTIPOLYGON", warn = FALSE)

if (any(!st_is_valid(published)) || any(st_is_empty(published))) {
  stop("Selected CAMELS-CL catchments remain invalid or empty after repair")
}

published$Chemistry_Site_ID <- target_sites$Chemistry_Site_ID
published$Source_URL <- source_url
published$Retrieved_Date <- retrieved_date

### Quantitative QA

site_points <- st_as_sf(
  target_sites,
  coords = c("Site_Longitude", "Site_Latitude"),
  crs = 4326,
  remove = FALSE
)

published_projected <- st_transform(published, 6933)
current_projected <- st_transform(current_sites, 6933)
points_projected <- st_transform(site_points, 6933)

published_area <- as.numeric(st_area(published_projected)) / 1e6
current_area <- as.numeric(st_area(current_projected)) / 1e6
area_difference <- percent_difference(published_area, current_area)
attribute_area_difference <- percent_difference(published_area, published$area_km2)

boundary_distance <- as.numeric(st_distance(
  points_projected,
  st_boundary(published_projected),
  by_element = TRUE
))
point_inside <- lengths(st_intersects(site_points, published)) > 0L

intersection_area <- vapply(seq_len(nrow(published)), function(row_index) {
  overlap <- suppressWarnings(st_intersection(
    published_projected[row_index, ],
    current_projected[row_index, ]
  ))
  if (nrow(overlap) == 0L) 0 else sum(as.numeric(st_area(overlap))) / 1e6
}, numeric(1L))

union_area <- published_area + current_area - intersection_area
intersection_over_union <- intersection_area / union_area

replace_current <-
  boundary_distance <= boundary_tolerance_m &
  area_difference <= 10 &
  attribute_area_difference <= 2 &
  intersection_over_union >= 0.9

expected_decision <- c(TRUE, FALSE, TRUE)
if (!identical(replace_current, expected_decision)) {
  stop("Chile replacement decisions changed; inspect the QA before continuing")
}

qa_status <- ifelse(
  replace_current,
  paste(
    "Accepted: CAMELS-CL gauge catchment agrees with the published area,",
    "the chemistry outlet is within 250 m of its boundary, and overlap with",
    "the current catchment exceeds 90%"
  ),
  paste(
    "Retained current chemistry-site catchment: the chemistry outlet is",
    "more than 6 km outside the CAMELS-CL gauge catchment"
  )
)

qa <- st_sf(
  Chemistry_Site_ID = target_sites$Chemistry_Site_ID,
  gauge_id = target_sites$gauge_id,
  gauge_name = published$gauge_name,
  Published_Raw_Geometry_Valid = raw_valid,
  Published_Area_Attribute_km2 = published$area_km2,
  Published_Geometry_Area_km2 = published_area,
  Published_Area_Difference_Percent = attribute_area_difference,
  Current_Geometry_Area_km2 = current_area,
  Current_to_Published_Area_Difference_Percent = area_difference,
  Chemistry_Site_Inside_Published = point_inside,
  Chemistry_Site_to_Published_Boundary_m = boundary_distance,
  Intersection_Over_Union = intersection_over_union,
  Replace_Current = replace_current,
  QA_Status = qa_status,
  geometry = st_geometry(published)
)

### Write source and QA layers

stage_root <- tempfile("chile-watersheds-", tmpdir = output_dir)
dir.create(stage_root)
on.exit(unlink(stage_root, recursive = TRUE), add = TRUE)
stage_source <- file.path(stage_root, basename(source_file))
stage_combined <- file.path(stage_root, basename(combined_file))
stage_site_dir <- file.path(stage_root, basename(site_dir))
dir.create(stage_site_dir)

st_write(published, stage_source, layer = "official_candidates", quiet = TRUE)
st_write(qa, stage_source, layer = "qa", append = FALSE, quiet = TRUE)

### Update accepted catchments

updated <- current
accepted <- which(replace_current)
accepted_rows <- current_rows[accepted]

st_geometry(updated)[accepted_rows] <- st_geometry(published)[accepted]
updated$Final_Catchment_Area_km2[accepted_rows] <- published$area_km2[accepted]
updated$Catchment_Area_Source[accepted_rows] <-
  "CAMELS-CL v1.3 published station catchment area"
updated$Catchment_Polygon_Source[accepted_rows] <-
  "CAMELS-CL v1.3 station catchment boundary"
updated$Catchment_Polygon_Source_File[accepted_rows] <- basename(source_file)
updated$QA_Status[accepted_rows] <- qa_status[accepted]

unchanged_rows <- setdiff(seq_len(nrow(current)), accepted_rows)
if (!identical(
  st_as_binary(st_geometry(current)[unchanged_rows]),
  st_as_binary(st_geometry(updated)[unchanged_rows])
)) {
  stop("A non-target catchment geometry changed")
}
if (any(!st_is_valid(updated)) || any(st_is_empty(updated))) {
  stop("Updated catchment collection contains invalid or empty geometry")
}

st_write(updated, stage_combined, layer = "site_catchments", quiet = TRUE)
check <- st_read(stage_combined, quiet = TRUE)
if (nrow(check) != 154L || any(!st_is_valid(check)) || any(st_is_empty(check))) {
  stop("Replacement catchment file failed final QA")
}

for (row_index in seq_len(nrow(updated))) {
  staged_site_file <- file.path(
    stage_site_dir,
    paste0(
      safe_file_name(updated$Source_Key[[row_index]]),
      "_",
      safe_file_name(updated$Chemistry_Site_ID[[row_index]]),
      "_catchment.gpkg"
    )
  )
  st_write(
    updated[row_index, ],
    staged_site_file,
    layer = "catchment",
    quiet = TRUE
  )
}

source_check <- st_read(stage_source, layer = "official_candidates", quiet = TRUE)
qa_check <- st_read(stage_source, layer = "qa", quiet = TRUE)
if (nrow(source_check) != 3L || nrow(qa_check) != 3L ||
    length(list.files(stage_site_dir, pattern = "[.]gpkg$")) != 154L) {
  stop("Expected 154 per-site GeoPackages")
}

install_checked_outputs(
  c(stage_source, stage_combined, stage_site_dir),
  c(source_file, combined_file, site_dir),
  backup_root = output_dir
)
if (nrow(st_read(combined_file, quiet = TRUE)) != 154L ||
    length(list.files(site_dir, pattern = "[.]gpkg$")) != 154L) {
  stop("Installed Chile watershed outputs failed read-back QA")
}

message("CAMELS-CL candidates checked: ", nrow(published))
message("Chile replacements accepted: ", sum(replace_current))
message("Chile current catchments retained: ", sum(!replace_current))
message("Source and QA: ", source_file)
message("Updated 154-site catchments: ", combined_file)
