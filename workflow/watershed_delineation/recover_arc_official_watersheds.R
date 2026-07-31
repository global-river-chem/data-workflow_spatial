suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(readxl)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

# Recover ARC watersheds from official Arctic LTER, Toolik, UAF, EDI, and
# USGS sources. The script keeps long-term stream sites separate from the
# Kuparuk synoptic sites and does not turn the Tussock soil-water points into
# river watersheds.
#
# The ARC LTER subwatershed archive URL below is kept as provenance, but the
# legacy host currently returns HTTP
# 403 and the current ARC page says the GIS layers are not yet available for
# direct download. Therefore, boundaries generated in this run are explicitly
# labeled either as official Toolik/UAF supplied polygons or as USGS 3DEP
# delineations conditioned on the official Toolik stream network. They must not
# be described as polygons downloaded from the unavailable ARC ZIP.

args <- commandArgs(trailingOnly = TRUE)
site_table_path <- cli_value(args, "--site-table", required = TRUE)
work_dir <- cli_value(args, "--work-root", file.path(tempdir(), "arc-watershed-work"))
output_root <- cli_value(args, "--output-root", required = TRUE)

if (!file.exists(site_table_path)) {
  stop("Missing ARC site table: ", site_table_path, call. = FALSE)
}
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

sources <- list(
  arc_lter_subwatersheds = paste0(
    "https://arc-lter.ecosystems.mbl.edu/sites/default/files/data/GIS/",
    "ARCLTERsubwatersheds.zip"
  ),
  chemistry_csv = paste0(
    "https://pasta.lternet.edu/package/data/eml/knb-lter-arc/20080/2/",
    "34dcec28a58f63947edd334056101d65"
  ),
  chemistry_xlsx = paste0(
    "https://pasta.lternet.edu/package/data/eml/knb-lter-arc/20080/2/",
    "cfc052760805f998aea41d075cdd8cad"
  ),
  kuparuk_synoptic = paste0(
    "https://pasta.lternet.edu/package/data/eml/knb-lter-arc/20125/2/",
    "c8698c78a4527cb04bcc8a1db9f31030"
  ),
  toolik_core_watersheds = paste0(
    "https://lat68.toolik.alaska.edu/ajax/gis/download_gis_file.php?",
    "file=data/data/Watersheds_Research%24data.zip"
  ),
  toolik_rivers = paste0(
    "https://lat68.toolik.alaska.edu/ajax/gis/download_gis_file.php?",
    "file=data/data/hyd_toolik_arc_101111%24data.zip"
  ),
  uaf_hydrology = paste0(
    "https://services.arcgis.com/2j08Y1PuezhQEfCz/arcgis/rest/services/",
    "Upper_Kuparuk_Hydrology___Walker_2008/FeatureServer/0/query?",
    "where=1%3D1&outFields=*&outSR=26906&f=geojson"
  ),
  usgs_dem = paste0(
    "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/",
    "current/n69w150/USGS_13_n69w150.tif"
  )
)

download_once <- function(url, destination) {
  if (!file.exists(destination)) {
    download.file(url, destination, mode = "wb", quiet = FALSE)
  }
  destination
}

source_dir <- file.path(work_dir, "source-data")
dir.create(source_dir, recursive = TRUE, showWarnings = FALSE)
chemistry_csv <- download_once(
  sources$chemistry_csv, file.path(source_dir, "2012-2020_Kling_Akchem.02.csv")
)
chemistry_xlsx <- download_once(
  sources$chemistry_xlsx, file.path(source_dir, "2012-2020_Kling_Akchem.02.xlsx")
)
synoptic_csv <- download_once(
  sources$kuparuk_synoptic, file.path(source_dir, "2016-2018_Abbott_Synoptic.csv")
)
core_zip <- download_once(
  sources$toolik_core_watersheds,
  file.path(source_dir, "Toolik_Core_Research_Watersheds.zip")
)
rivers_zip <- download_once(
  sources$toolik_rivers, file.path(source_dir, "Toolik_Rivers.zip")
)
uaf_hydrology_path <- download_once(
  sources$uaf_hydrology, file.path(source_dir, "Upper_Kuparuk_Hydrology.geojson")
)

core_dir <- file.path(source_dir, "toolik-core-watersheds")
rivers_dir <- file.path(source_dir, "toolik-rivers")
if (!dir.exists(core_dir)) unzip(core_zip, exdir = core_dir)
if (!dir.exists(rivers_dir)) unzip(rivers_zip, exdir = rivers_dir)
core_files <- list.files(core_dir, pattern = "[.]shp$", recursive = TRUE, full.names = TRUE)
river_files <- list.files(rivers_dir, pattern = "[.]shp$", recursive = TRUE, full.names = TRUE)
if (!length(core_files) || !length(river_files)) {
  stop("Official Toolik archives did not contain the expected shapefiles.", call. = FALSE)
}

whitebox <- Sys.getenv("WHITEBOX_TOOLS", unset = Sys.which("whitebox_tools"))
if (!nzchar(whitebox) || !file.exists(whitebox)) {
  stop("Set WHITEBOX_TOOLS to the WhiteboxTools executable.", call. = FALSE)
}

run_wbt <- function(tool, arguments) {
  result <- system2(
    whitebox,
    c(paste0("-r=", tool), paste0("--wd=", shQuote(work_dir)), arguments),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(result, "status")
  if (!is.null(status) && status != 0L) {
    stop(tool, " failed:\n", paste(result, collapse = "\n"), call. = FALSE)
  }
  invisible(result)
}

headers <- c(
  "LTER", "Stream_Name", "Country", "State", "Waterbody",
  "Spatial_Data_Release", "Latitude", "Longitude", "drainSqKm",
  "drainSqKm_source", "USGSGageNumber", "Use_WRTDS",
  "Has_Spatial_Data", "Shapefile_Name", "Shapefile_CRS_EPSG",
  "Shapefile_Source", "Shapefile_Link", "River_Network_Context",
  "CQ_Notes", "Spatial_Notes", "Discharge_File_Name", "Units",
  "Original_Stream_Name", "Discharge_Site_Name", "New_Solute_Stream_Name",
  "MDL_P_mgL", "MDL_NOx_mgL", "MDL_NH4_mgL", "MDL_NHX_mgL",
  "MDL_Si_mgL", "Min_Long", "Max_Long", "Min_Lat", "Max_Lat"
)
site_table <- read.delim(
  site_table_path, header = FALSE, sep = "\t", quote = "", fill = TRUE,
  comment.char = "", stringsAsFactors = FALSE
)
if (ncol(site_table) != length(headers)) {
  stop("ARC table has ", ncol(site_table), " columns; expected ", length(headers), ".")
}
names(site_table) <- headers
site_table$Latitude <- suppressWarnings(as.numeric(site_table$Latitude))
site_table$Longitude <- suppressWarnings(as.numeric(site_table$Longitude))

key_name <- function(x) {
  x <- tolower(trimws(x))
  x <- gsub("[[:space:]]+", " ", x)
  x
}
slug_name <- function(x) {
  x <- key_name(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  gsub("(^_|_$)", "", x)
}
site_table$site_key <- key_name(site_table$Stream_Name)

# Count years with measured DSi in the official long-term ARC chemistry data.
chem_names <- names(read.csv(chemistry_csv, nrows = 1, check.names = FALSE))
chemistry <- read.csv(
  chemistry_csv, skip = 4, header = FALSE, check.names = FALSE,
  na.strings = c(".", ""), stringsAsFactors = FALSE
)
names(chemistry) <- chem_names
chemistry$site_key <- key_name(chemistry$Site)
chemistry$year <- suppressWarnings(as.integer(substr(chemistry$Date, 1, 4)))
dsi_years <- aggregate(
  year ~ site_key,
  data = chemistry[is.finite(chemistry$Si_uM) & is.finite(chemistry$year), ],
  FUN = function(x) length(unique(x))
)
names(dsi_years)[2] <- "dsi_years"
site_table <- merge(site_table, dsi_years, by = "site_key", all.x = TRUE, sort = FALSE)
site_table$dsi_years[is.na(site_table$dsi_years)] <- 0L

# The official workbook supplies exact coordinates and identifies TW 01-14 as
# soil-water sampling points. Use its coordinates when they are present.
metadata <- read_excel(chemistry_xlsx, sheet = "Metadata", col_names = FALSE)
first_column <- trimws(as.character(metadata[[1]]))
row_at <- function(label) {
  hit <- which(first_column == label)
  if (!length(hit)) stop("Missing metadata row: ", label, call. = FALSE)
  hit[1]
}
location_names <- unlist(metadata[row_at("Location Name"), -1], use.names = FALSE)
official_lat <- suppressWarnings(as.numeric(unlist(metadata[row_at("Latitude"), -1], use.names = FALSE)))
official_lon <- suppressWarnings(as.numeric(unlist(metadata[row_at("Longitude"), -1], use.names = FALSE)))
official_description <- unlist(
  metadata[row_at("Geographic Description"), -1], use.names = FALSE
)
official_sites <- data.frame(
  site_key = key_name(location_names),
  official_name = as.character(location_names),
  official_latitude = official_lat,
  official_longitude = official_lon,
  official_description = as.character(official_description),
  stringsAsFactors = FALSE
)
official_sites <- official_sites[nzchar(official_sites$site_key), ]
site_table <- merge(site_table, official_sites, by = "site_key", all.x = TRUE, sort = FALSE)
use_official <- is.finite(site_table$official_latitude) & is.finite(site_table$official_longitude)
site_table$Latitude[use_official] <- site_table$official_latitude[use_official]
site_table$Longitude[use_official] <- site_table$official_longitude[use_official]

site_table$decision <- "hold_not_currently_eligible"
site_table$decision[site_table$dsi_years >= 5 | tolower(site_table$Use_WRTDS) == "yes"] <-
  "review_for_watershed"
site_table$decision[!is.finite(site_table$Latitude) | !is.finite(site_table$Longitude)] <-
  "hold_no_coordinates"
site_table$decision[grepl("^tw (0[1-9]|1[0-4])$", site_table$site_key)] <-
  "exclude_soil_water_site"
site_table$decision[tolower(site_table$Waterbody) == "water track"] <-
  "exclude_water_track"
site_table$decision[site_table$site_key == "lter 345 outlet"] <-
  "hold_coordinate_not_in_official_site_table"
site_table$decision[site_table$site_key == "tw weir"] <-
  "hold_exact_one_hectare_boundary_not_recovered"

# Keep one canonical row for repeated labels and case-only duplicates.
site_table$canonical_row <- !duplicated(site_table$site_key)
site_table$decision[!site_table$canonical_row] <- "duplicate_table_row"

current_candidates <- site_table[
  site_table$decision == "review_for_watershed" & site_table$canonical_row,
]

# Prepare the official stream-conditioned USGS 3DEP surface when cached
# products have not already been supplied.
dem_path <- Sys.getenv(
  "ARC_DEM_PATH", unset = file.path(work_dir, "arc_usgs_3dep_10m_utm6.tif")
)
conditioned_dem <- file.path(work_dir, "arc_dem_stream_conditioned.tif")
pointer <- file.path(work_dir, "arc_stream_d8_pointer.tif")
accumulation <- file.path(work_dir, "arc_stream_flow_accum_cells.tif")
stream_mask_path <- file.path(work_dir, "arc_official_stream_mask.tif")

if (!file.exists(dem_path)) {
  remote_dem <- rast(paste0("/vsicurl/", sources$usgs_dem))
  cropped <- crop(remote_dem, ext(-149.90, -149.00, 68.45, 69.05))
  projected <- project(cropped, "EPSG:26906", method = "bilinear", res = 10)
  writeRaster(projected, dem_path, overwrite = TRUE)
}
dem <- rast(dem_path)
rivers <- do.call(rbind, lapply(river_files, st_read, quiet = TRUE))
rivers_utm <- st_transform(rivers, crs(dem))
rivers_utm_path <- file.path(work_dir, "toolik_rivers_utm6.shp")
st_write(rivers_utm, rivers_utm_path, delete_layer = TRUE, quiet = TRUE)

if (!all(file.exists(c(conditioned_dem, pointer, accumulation)))) {
  burned_dem <- file.path(work_dir, "arc_dem_stream_burned.tif")
  run_wbt("FillBurn", c(
    paste0("--dem=", shQuote(dem_path)),
    paste0("--streams=", shQuote(rivers_utm_path)),
    paste0("--output=", shQuote(burned_dem))
  ))
  run_wbt("BreachDepressions", c(
    paste0("--dem=", shQuote(burned_dem)),
    paste0("--output=", shQuote(conditioned_dem)), "--fill_pits"
  ))
  run_wbt("D8Pointer", c(
    paste0("--dem=", shQuote(conditioned_dem)),
    paste0("--output=", shQuote(pointer))
  ))
  run_wbt("D8FlowAccumulation", c(
    paste0("--input=", shQuote(conditioned_dem)),
    paste0("--output=", shQuote(accumulation)), "--out_type=cells"
  ))
}
accumulation_raster <- rast(accumulation)
if (!file.exists(stream_mask_path)) {
  stream_mask <- rasterize(
    vect(rivers_utm), accumulation_raster, field = 1,
    background = NA, touches = TRUE
  )
  writeRaster(stream_mask, stream_mask_path, overwrite = TRUE)
}
stream_mask <- rast(stream_mask_path)

snap_radii <- c(25, 50, 75, 100, 150, 200)
derived_candidates <- current_candidates[
  !current_candidates$site_key %in% c("toolik inlet", "toolik outlet"),
]
candidate_points <- st_as_sf(
  derived_candidates,
  coords = c("Longitude", "Latitude"), crs = 4326, remove = FALSE
)
candidate_points <- st_transform(candidate_points, crs(accumulation_raster))
candidate_points$point_id <- seq_len(nrow(candidate_points))
candidate_points_path <- file.path(work_dir, "arc_current_candidate_points.shp")
st_write(
  candidate_points[, c("point_id", "site_key")], candidate_points_path,
  delete_layer = TRUE, quiet = TRUE
)

snap_audit <- list()
snapped_layers <- list()
for (radius in snap_radii) {
  snapped_path <- file.path(work_dir, paste0("arc_candidates_snap_", radius, ".shp"))
  run_wbt("SnapPourPoints", c(
    paste0("--pour_pts=", shQuote(candidate_points_path)),
    paste0("--flow_accum=", shQuote(accumulation)),
    paste0("--output=", shQuote(snapped_path)),
    paste0("--snap_dist=", radius)
  ))
  snapped <- st_read(snapped_path, quiet = TRUE)
  snapped <- snapped[match(candidate_points$point_id, snapped$point_id), ]
  area_cells <- terra::extract(accumulation_raster, vect(snapped))[[2]]
  snap_audit[[as.character(radius)]] <- data.frame(
    point_id = candidate_points$point_id,
    site_key = candidate_points$site_key,
    radius_m = radius,
    snap_distance_m = as.numeric(st_distance(candidate_points, snapped, by_element = TRUE)),
    area_km2 = area_cells * prod(res(accumulation_raster)) / 1e6,
    stringsAsFactors = FALSE
  )
  snapped_layers[[as.character(radius)]] <- snapped
}
snap_audit <- do.call(rbind, snap_audit)

choose_stable_snap <- function(values) {
  values <- values[order(values$radius_m), ]
  difference <- abs(diff(values$area_km2)) /
    pmax(values$area_km2[-nrow(values)], values$area_km2[-1], 1e-12)
  acceptable <- which(difference <= 0.05 & values$area_km2[-nrow(values)] >= 0.001)
  if (!length(acceptable)) return(values[NA_integer_, ])
  values[acceptable[1], ]
}
selected <- do.call(rbind, lapply(split(snap_audit, snap_audit$point_id), choose_stable_snap))
selected$accepted <- is.finite(selected$area_km2) & selected$snap_distance_m <= 100
selected$hold_reason <- ifelse(
  selected$accepted, "", "No stable stream cell within 100 m across tested snap radii"
)

selected_points <- vector("list", nrow(selected))
for (i in seq_len(nrow(selected))) {
  if (!selected$accepted[i]) next
  layer <- snapped_layers[[as.character(selected$radius_m[i])]]
  selected_points[[i]] <- layer[layer$point_id == selected$point_id[i], ]
}
selected_points <- selected_points[!vapply(selected_points, is.null, logical(1))]
selected_points <- do.call(rbind, selected_points)

# Prevent separate monitoring rows from silently receiving the same raster
# outlet. Only exact duplicate table rows have already been collapsed above.
if (nrow(selected_points)) {
  outlet_xy <- st_coordinates(selected_points)
  outlet_key <- paste(round(outlet_xy[, 1], 3), round(outlet_xy[, 2], 3))
  repeated_outlets <- duplicated(outlet_key) | duplicated(outlet_key, fromLast = TRUE)
  if (any(repeated_outlets)) {
    repeated_ids <- selected_points$point_id[repeated_outlets]
    selected$accepted[selected$point_id %in% repeated_ids] <- FALSE
    selected$hold_reason[selected$point_id %in% repeated_ids] <-
      "Distinct monitoring rows collapse to the same 10 m outlet cell"
    selected_points <- selected_points[!selected_points$point_id %in% repeated_ids, ]
  }
}

write_watershed <- function(
    point, site_name, shapefile_name, source_label,
    destination = output_root) {
  point_path <- file.path(work_dir, paste0(shapefile_name, "_outlet.shp"))
  raster_path <- file.path(work_dir, paste0(shapefile_name, "_watershed.tif"))
  st_write(point[, "point_id"], point_path, delete_layer = TRUE, quiet = TRUE)
  run_wbt("Watershed", c(
    paste0("--d8_pntr=", shQuote(pointer)),
    paste0("--pour_pts=", shQuote(point_path)),
    paste0("--output=", shQuote(raster_path))
  ))
  watershed_raster <- rast(raster_path)
  watershed_raster[!is.finite(watershed_raster)] <- NA
  polygon <- st_as_sf(as.polygons(watershed_raster, dissolve = TRUE, na.rm = TRUE))
  polygon <- st_make_valid(st_simplify(polygon, dTolerance = 10, preserveTopology = TRUE))
  polygon$site_id <- paste0("ARC__", site_name)
  polygon$aoi_name <- shapefile_name
  polygon$source <- source_label
  polygon <- st_transform(polygon[, c("site_id", "aoi_name", "source")], 4326)
  st_write(
    polygon, file.path(destination, paste0(shapefile_name, ".shp")),
    delete_layer = TRUE, quiet = TRUE
  )
  polygon
}

accepted_polygons <- list()
qa_rows <- list()
for (i in seq_len(nrow(selected_points))) {
  point_id <- selected_points$point_id[i]
  site_row <- derived_candidates[derived_candidates$site_key == selected_points$site_key[i], ][1, ]
  snap_row <- selected[selected$point_id == point_id, ][1, ]
  shapefile_name <- paste0("arc_", slug_name(site_row$Stream_Name), "_watershed")
  polygon <- write_watershed(
    selected_points[i, ], site_row$Stream_Name, shapefile_name,
    "USGS 3DEP watershed aligned to the official Toolik stream network"
  )
  accepted_polygons[[site_row$site_key]] <- polygon
  qa_rows[[site_row$site_key]] <- data.frame(
    Stream_Name = site_row$Stream_Name,
    dsi_years = site_row$dsi_years,
    Latitude = site_row$Latitude,
    Longitude = site_row$Longitude,
    drainSqKm = as.numeric(st_area(st_transform(polygon, 3338))) / 1e6,
    drainSqKm_source = "Area calculated from watershed polygon",
    Has_Spatial_Data = "Yes",
    Shapefile_Name = shapefile_name,
    Shapefile_CRS_EPSG = 4326,
    Shapefile_Source = "USGS 3DEP delineation aligned to official Toolik stream network",
    Shapefile_Link = "https://www.uaf.edu/toolik/gis/data/index.php",
    snap_distance_m = snap_row$snap_distance_m,
    stringsAsFactors = FALSE
  )
}

# Toolik Inlet is supplied directly by Toolik. Toolik Outlet uses the UAF
# Toolik Lake tributary basin (hydro code 3), which is the full lake-outlet
# catchment rather than the smaller inlet-only watershed.
core_match <- function(pattern) {
  hit <- core_files[grepl(pattern, basename(core_files), ignore.case = TRUE)]
  if (!length(hit)) stop("Missing Toolik core watershed matching ", pattern)
  hit[1]
}
toolik_inlet <- st_transform(st_read(core_match("Toolik_inlet"), quiet = TRUE), 4326)
toolik_inlet$site_id <- "ARC__Toolik Inlet"
toolik_inlet$aoi_name <- "arc_toolik_inlet_watershed"
toolik_inlet$source <- "Official Toolik core research watershed"
toolik_inlet <- toolik_inlet[, c("site_id", "aoi_name", "source")]
st_write(
  toolik_inlet, file.path(output_root, "arc_toolik_inlet_watershed.shp"),
  delete_layer = TRUE, quiet = TRUE
)
accepted_polygons[["toolik inlet"]] <- toolik_inlet

uaf_hydrology <- st_read(uaf_hydrology_path, quiet = TRUE)
toolik_outlet <- uaf_hydrology[uaf_hydrology$hydro == 3, ]
toolik_outlet <- st_transform(st_make_valid(toolik_outlet), 4326)
toolik_outlet$site_id <- "ARC__Toolik Outlet"
toolik_outlet$aoi_name <- "arc_toolik_outlet_watershed"
toolik_outlet$source <- "Official UAF Upper Kuparuk hydrology map, hydro code 3"
toolik_outlet <- toolik_outlet[, c("site_id", "aoi_name", "source")]
st_write(
  toolik_outlet, file.path(output_root, "arc_toolik_outlet_watershed.shp"),
  delete_layer = TRUE, quiet = TRUE
)
accepted_polygons[["toolik outlet"]] <- toolik_outlet

for (site_key in c("toolik inlet", "toolik outlet")) {
  site_row <- current_candidates[current_candidates$site_key == site_key, ][1, ]
  polygon <- accepted_polygons[[site_key]]
  shapefile_name <- unique(polygon$aoi_name)[1]
  qa_rows[[site_key]] <- data.frame(
    Stream_Name = site_row$Stream_Name,
    dsi_years = site_row$dsi_years,
    Latitude = site_row$Latitude,
    Longitude = site_row$Longitude,
    drainSqKm = as.numeric(st_area(st_transform(polygon, 3338))) / 1e6,
    drainSqKm_source = "Area calculated from watershed polygon",
    Has_Spatial_Data = "Yes",
    Shapefile_Name = shapefile_name,
    Shapefile_CRS_EPSG = 4326,
    Shapefile_Source = unique(polygon$source)[1],
    Shapefile_Link = "https://www.uaf.edu/toolik/gis/data/index.php",
    snap_distance_m = 0,
    stringsAsFactors = FALSE
  )
}

qa <- do.call(rbind, qa_rows)
qa <- qa[order(qa$Stream_Name), ]
write.table(
  qa, file.path(output_root, "arc_watershed_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)

# Audit the 2016-2018 Kuparuk synoptic sites against their published EDI
# drainage areas. These rows have three chemistry years and are not included
# in the current AppEEARS request, but accepted boundaries are retained for
# table metadata and possible later use.
synoptic <- read.csv(synoptic_csv, check.names = FALSE, stringsAsFactors = FALSE)
latest_kup <- unique(synoptic[
  synoptic$Watershed == "KUP" & synoptic$Year == 2018,
  c("Site ID", "Latitude (degrees)", "Longitude (degrees)", "Area (km2)")
])
kup_points <- st_transform(
  st_as_sf(
    latest_kup, coords = c("Longitude (degrees)", "Latitude (degrees)"),
    crs = 4326, remove = FALSE
  ),
  crs(accumulation_raster)
)
target_snap <- function(point, target_area_km2, search_radius_m = 250) {
  xy0 <- st_coordinates(point)[1, ]
  search_extent <- ext(
    xy0[1] - search_radius_m, xy0[1] + search_radius_m,
    xy0[2] - search_radius_m, xy0[2] + search_radius_m
  )
  area_window <- crop(accumulation_raster, search_extent)
  mask_window <- crop(stream_mask, search_extent)
  accumulation_values <- values(area_window)
  usable <- is.finite(accumulation_values) & is.finite(values(mask_window))
  cells <- which(usable)
  xy <- xyFromCell(area_window, cells)
  distance <- sqrt((xy[, 1] - xy0[1])^2 + (xy[, 2] - xy0[2])^2)
  inside <- distance <= search_radius_m
  cells <- cells[inside]
  xy <- xy[inside, , drop = FALSE]
  distance <- distance[inside]
  area <- accumulation_values[cells] * prod(res(accumulation_raster)) / 1e6
  relative_error <- abs(area - target_area_km2) / target_area_km2
  score <- relative_error + distance / 5000
  selected_cell <- which.min(score)
  data.frame(
    x = xy[selected_cell, 1], y = xy[selected_cell, 2],
    polygon_area_km2 = area[selected_cell],
    relative_area_error = relative_error[selected_cell],
    snap_distance_m = distance[selected_cell]
  )
}
kup_audit <- do.call(rbind, lapply(seq_len(nrow(latest_kup)), function(i) {
  result <- target_snap(kup_points[i, ], latest_kup[["Area (km2)"]][i])
  data.frame(
    Stream_Name = sub("^KUP", "KUP ", latest_kup[["Site ID"]][i]),
    reported_area_km2 = latest_kup[["Area (km2)"]][i],
    result,
    accepted = result$relative_area_error <= 0.10 & result$snap_distance_m <= 125,
    stringsAsFactors = FALSE
  )
}))
write.table(
  kup_audit, file.path(output_root, "kuparuk_watershed_audit.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)

# Write the Kuparuk synoptic boundaries that passed the independent EDI-area
# check. The source chemistry record covers only 2016-2018 (three years).
kuparuk_output <- file.path(output_root, "kuparuk-reference-only")
dir.create(kuparuk_output, recursive = TRUE, showWarnings = FALSE)
for (i in which(kup_audit$accepted)) {
  site_name <- kup_audit$Stream_Name[i]
  shapefile_name <- paste0("arc_", slug_name(site_name), "_watershed")
  point <- st_as_sf(
    data.frame(
      point_id = i,
      x = kup_audit$x[i],
      y = kup_audit$y[i]
    ),
    coords = c("x", "y"), crs = crs(accumulation_raster)
  )
  write_watershed(
    point, site_name, shapefile_name,
    paste(
      "USGS 3DEP delineation aligned to the official Toolik stream network;",
      "outlet checked against the EDI-reported drainage area"
    ),
    destination = kuparuk_output
  )
}

full_audit <- site_table[, c(
  "Stream_Name", "Waterbody", "dsi_years", "Latitude", "Longitude",
  "decision", "canonical_row", "official_description"
)]
full_audit$decision[
  key_name(full_audit$Stream_Name) %in% names(accepted_polygons)
] <- "watershed_available"
write.table(
  full_audit, file.path(output_root, "arc_full_site_audit.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)

cat("Accepted current ARC watershed candidates:", length(accepted_polygons), "\n")
cat("Kuparuk site polygons passing the area check:", sum(kup_audit$accepted),
    "of", nrow(kup_audit), "\n")
cat("Output:", output_root, "\n")
