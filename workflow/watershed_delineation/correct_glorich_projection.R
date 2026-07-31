# Correct GLORICH geometries whose raw projected coordinates were assigned the
# wrong coordinate system before being written as WGS84.

suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
source_root <- cli_value(args, "--source-root", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
targets_path <- cli_value(
  args,
  "--targets",
  file.path(
    "workflow", "watershed_delineation", "config",
    "glorich_projection_corrections.tsv"
  )
)

targets <- read_workflow_table(targets_path)
require_columns(
  targets,
  c(
    "LTER", "Stream_Name", "Shapefile_Name", "source_dir", "Latitude",
    "Longitude", "reference_area_km2", "misassigned_crs", "source_crs"
  ),
  "GLORICH correction table"
)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

results <- lapply(seq_len(nrow(targets)), function(index) {
  target <- targets[index, ]
  input_path <- file.path(
    source_root,
    target$source_dir,
    paste0(target$Shapefile_Name, ".shp")
  )
  if (!file.exists(input_path)) stop("Missing source shapefile: ", input_path)

  geometry <- st_read(input_path, quiet = TRUE)
  raw_projected <- st_transform(geometry, target$misassigned_crs)
  st_crs(raw_projected) <- st_crs(target$source_crs)
  corrected <- st_transform(st_make_valid(raw_projected), 4326)

  corrected$site_id <- paste(target$LTER, target$Stream_Name, sep = "__")
  corrected$source <- "GLORICH catchment derived from HydroSHEDS"
  if ("Stat_Id" %in% names(corrected)) {
    corrected$source_id <- as.character(corrected$Stat_Id)
  }

  site_dir <- file.path(output_root, target$Shapefile_Name)
  dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
  output_path <- file.path(site_dir, paste0(target$Shapefile_Name, ".shp"))
  st_write(corrected, output_path, delete_layer = TRUE, quiet = TRUE)

  station <- st_sfc(
    st_point(c(as.numeric(target$Longitude), as.numeric(target$Latitude))),
    crs = 4326
  )
  area_km2 <- as.numeric(sum(st_area(st_transform(corrected, 6933)))) / 1e6
  reference_area <- suppressWarnings(as.numeric(target$reference_area_km2))

  data.frame(
    LTER = target$LTER,
    Stream_Name = target$Stream_Name,
    Shapefile_Name = target$Shapefile_Name,
    reference_area_km2 = reference_area,
    polygon_area_km2 = area_km2,
    area_difference_pct = if (is.finite(reference_area)) {
      100 * (area_km2 - reference_area) / reference_area
    } else {
      NA_real_
    },
    station_to_polygon_m = min(as.numeric(st_distance(
      st_transform(station, 6933), st_transform(corrected, 6933)
    ))),
    valid = all(st_is_valid(corrected)),
    output_file = output_path,
    stringsAsFactors = FALSE
  )
})

qa <- do.call(rbind, results)
write.table(
  qa,
  file.path(output_root, "glorich_projection_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)
if (!all(qa$valid)) stop("At least one corrected GLORICH geometry is invalid.")
print(qa, row.names = FALSE)
