# Extract configured Finnish watersheds from the national SYKE level-2 basin
# layer and check that each station lies in its selected basin.

suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
syke_path <- cli_value(args, "--syke-level2", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
targets_path <- cli_value(
  args,
  "--targets",
  file.path("workflow", "watershed_delineation", "config", "syke_level2_targets.tsv")
)

targets <- read_workflow_table(targets_path)
require_columns(
  targets,
  c(
    "LTER", "Stream_Name", "Shapefile_Name", "taso2_id", "Latitude",
    "Longitude", "reference_area_km2"
  ),
  "SYKE target table"
)
if (!file.exists(syke_path)) stop("Missing SYKE level-2 layer: ", syke_path)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

basins <- st_read(syke_path, quiet = TRUE)
require_columns(basins, "taso2_id", "SYKE level-2 layer")

results <- lapply(seq_len(nrow(targets)), function(index) {
  target <- targets[index, ]
  basin <- basins[as.character(basins$taso2_id) == as.character(target$taso2_id), ]
  if (nrow(basin) != 1L) {
    stop(target$Stream_Name, " matched ", nrow(basin), " SYKE basins; expected one.")
  }

  station <- st_transform(
    st_sfc(
      st_point(c(as.numeric(target$Longitude), as.numeric(target$Latitude))),
      crs = 4326
    ),
    st_crs(basin)
  )
  if (lengths(st_intersects(station, basin)) != 1L) {
    stop(target$Stream_Name, " station is outside the selected SYKE basin.")
  }

  basin$site_id <- paste(target$LTER, target$Stream_Name, sep = "__")
  basin$source <- "Finnish Environment Institute national catchment division"
  basin$source_id <- as.character(target$taso2_id)
  watershed <- st_transform(st_make_valid(basin), 4326)

  site_dir <- file.path(output_root, target$Shapefile_Name)
  dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
  output_path <- file.path(site_dir, paste0(target$Shapefile_Name, ".shp"))
  st_write(watershed, output_path, delete_layer = TRUE, quiet = TRUE)

  polygon_area <- if ("ylavalu_pa" %in% names(basin)) {
    as.numeric(basin$ylavalu_pa[[1]])
  } else {
    as.numeric(st_area(st_transform(watershed, 6933))) / 1e6
  }
  reference_area <- suppressWarnings(as.numeric(target$reference_area_km2))

  data.frame(
    LTER = target$LTER,
    Stream_Name = target$Stream_Name,
    Shapefile_Name = target$Shapefile_Name,
    source_id = as.character(target$taso2_id),
    reference_area_km2 = reference_area,
    polygon_area_km2 = polygon_area,
    area_difference_pct = if (is.finite(reference_area)) {
      100 * (polygon_area - reference_area) / reference_area
    } else {
      NA_real_
    },
    valid = all(st_is_valid(watershed)),
    output_file = output_path,
    stringsAsFactors = FALSE
  )
})

qa <- do.call(rbind, results)
write.table(
  qa,
  file.path(output_root, "syke_level2_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)
if (!all(qa$valid)) stop("At least one SYKE watershed is invalid.")
print(qa, row.names = FALSE)
