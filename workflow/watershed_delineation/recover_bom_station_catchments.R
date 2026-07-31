suppressPackageStartupMessages({
  library(data.table)
  library(httr2)
  library(jsonlite)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
sites_path <- cli_value(args, "--sites", required = TRUE)
targets_path <- cli_value(
  args, "--targets",
  file.path("workflow", "watershed_delineation", "config", "bom_geofabric_targets.tsv")
)
output_dir <- cli_value(args, "--output-root", required = TRUE)
shapefile_root <- cli_value(args, "--shapefile-root", required = TRUE)

sites <- as.data.table(read_workflow_table(sites_path))
targets <- as.data.table(read_workflow_table(targets_path))
require_columns(sites, c("LTER", "Stream_Name", "Latitude", "Longitude"), "site table")
require_columns(
  targets,
  c("LTER", "Stream_Name", "station_number", "Shapefile_Name", "extraction_method"),
  "BoM target table"
)
targets <- merge(targets, sites, by = c("LTER", "Stream_Name"), all.x = TRUE, sort = FALSE)
if (anyNA(targets$Latitude) || anyNA(targets$Longitude)) {
  stop("Every BoM target needs a latitude and longitude in the site table.", call. = FALSE)
}
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(shapefile_root, recursive = TRUE, showWarnings = FALSE)

service <- paste0(
  "https://hosting.wsapi.cloud.bom.gov.au/arcgis/rest/services/ahgf/",
  "Geofabric_V3x_All_Products/FeatureServer"
)

perform_query <- function(layer, params, as_geojson = FALSE) {
  request <- request(paste0(service, "/", layer, "/query"))
  request <- do.call(req_url_query, c(list(request), params)) |>
    req_retry(max_tries = 3) |>
    req_timeout(180)
  response <- req_perform(request)
  if (as_geojson) {
    temp_file <- tempfile(fileext = ".geojson")
    writeBin(resp_body_raw(response), temp_file)
    return(st_read(temp_file, quiet = TRUE))
  }
  fromJSON(resp_body_string(response), simplifyVector = TRUE)
}

attributes_table <- function(response) {
  if (is.null(response$features) || !length(response$features)) return(data.table())
  attributes <- response$features$attributes
  if (is.null(attributes) || !length(attributes)) return(data.table())
  as.data.table(attributes)
}

query_attributes_in_batches <- function(layer, field, values, out_fields = "*") {
  batches <- split(values, ceiling(seq_along(values) / 100L))
  rbindlist(lapply(batches, function(batch) {
    response <- perform_query(layer, list(
      where = paste0(field, " IN (", paste(batch, collapse = ","), ")"),
      outFields = out_fields,
      returnGeometry = "false",
      f = "json"
    ))
    attributes_table(response)
  }), fill = TRUE)
}

query_geometries_in_batches <- function(layer, field, values) {
  batches <- split(values, ceiling(seq_along(values) / 75L))
  do.call(rbind, lapply(batches, function(batch) {
    perform_query(layer, list(
      where = paste0(field, " IN (", paste(batch, collapse = ","), ")"),
      outFields = "*",
      returnGeometry = "true",
      outSR = "4326",
      f = "geojson"
    ), as_geojson = TRUE)
  }))
}

trace_contracted_catchment <- function(site, station_number) {
  gauge <- perform_query(2, list(
    where = paste0("stationno = '", station_number, "'"),
    outFields = "stationno,stnname,upstrdarea,confidence,near_dist,hydroid,netwstrmid",
    returnGeometry = "true",
    outSR = "4326",
    f = "geojson"
  ), as_geojson = TRUE)
  if (nrow(gauge) != 1L) stop("Expected one gauge node for station ", station_number)

  network_response <- perform_query(6, list(
    where = paste0("hydroid = ", gauge$netwstrmid[[1]]),
    outFields = "hydroid,name,upstrdarea,concatid",
    returnGeometry = "false",
    f = "json"
  ))
  network_stream <- attributes_table(network_response)
  if (nrow(network_stream) != 1L || !is.finite(network_stream$concatid[[1]])) {
    stop("No Geofabric stream catchment link for ", site$Stream_Name)
  }

  seed_response <- perform_query(31, list(
    where = paste0("concatid = ", network_stream$concatid[[1]]),
    outFields = "hydroid,nextdownid,concatid,albersarea",
    returnGeometry = "false",
    f = "json"
  ))
  seed <- attributes_table(seed_response)
  if (!nrow(seed)) stop("No contracted catchment seed for ", site$Stream_Name)

  visited <- unique(seed$hydroid)
  frontier <- visited
  repeat {
    upstream <- query_attributes_in_batches(
      31, "nextdownid", frontier,
      "hydroid,nextdownid,concatid,albersarea"
    )
    if (!nrow(upstream)) break
    new_ids <- setdiff(unique(upstream$hydroid), visited)
    if (!length(new_ids)) break
    visited <- c(visited, new_ids)
    frontier <- new_ids
  }

  pieces <- query_geometries_in_batches(31, "hydroid", visited)
  pieces <- st_make_valid(st_transform(pieces, 3577))
  polygon <- st_sf(geometry = st_union(st_geometry(pieces)))
  polygon <- st_transform(polygon, 4326)

  polygon$source_id <- station_number
  polygon$official_area_km2 <- gauge$upstrdarea[[1]] / 1e6
  polygon$source_feature_count <- length(visited)
  polygon$source_confidence <- gauge$confidence[[1]]
  polygon$source_near_distance_m <- gauge$near_dist[[1]]
  gauge_coordinates <- st_coordinates(gauge)
  polygon$official_station_longitude <- gauge_coordinates[1, 1]
  polygon$official_station_latitude <- gauge_coordinates[1, 2]
  polygon
}

polygon_list <- vector("list", nrow(targets))
for (i in seq_len(nrow(targets))) {
  site <- targets[i]
  if (site$extraction_method == "station_catchment") {
    polygon <- perform_query(49, list(
      where = paste0("stationno = '", site$station_number, "'"),
      outFields = "*",
      returnGeometry = "true",
      outSR = "4326",
      f = "geojson"
    ), as_geojson = TRUE)
    if (nrow(polygon) != 1L) {
      stop("Expected one station-catchment feature for ", site$station_number)
    }
    official_area <- polygon$albersareakm2[[1]]
    source_id <- polygon$stationno[[1]]
    source_count <- 1L
    confidence <- polygon$confidence[[1]]
    near_distance <- NA_real_
    gauge <- perform_query(2, list(
      where = paste0("stationno = '", site$station_number, "'"),
      outFields = "stationno,stnname,upstrdarea,confidence,near_dist,hydroid,netwstrmid",
      returnGeometry = "true",
      outSR = "4326",
      f = "geojson"
    ), as_geojson = TRUE)
    if (nrow(gauge) != 1L) stop("Expected one gauge node for ", site$station_number)
    gauge_coordinates <- st_coordinates(gauge)
    polygon <- st_make_valid(st_transform(polygon, 3577))
    polygon <- st_sf(geometry = st_union(st_geometry(polygon)))
    polygon <- st_transform(polygon, 4326)
    polygon$source_id <- source_id
    polygon$official_area_km2 <- official_area
    polygon$source_feature_count <- source_count
    polygon$source_confidence <- confidence
    polygon$source_near_distance_m <- near_distance
    polygon$official_station_longitude <- gauge_coordinates[1, 1]
    polygon$official_station_latitude <- gauge_coordinates[1, 2]
  } else {
    polygon <- trace_contracted_catchment(site, site$station_number)
  }

  reference_point <- st_sfc(st_point(c(site$Longitude, site$Latitude)), crs = 4326)
  official_point <- st_sfc(st_point(c(
    polygon$official_station_longitude, polygon$official_station_latitude
  )), crs = 4326)
  polygon$LTER <- site$LTER
  polygon$Stream_Name <- site$Stream_Name
  polygon$Shapefile_Name <- site$Shapefile_Name
  polygon$polygon_source <- "Bureau of Meteorology Geofabric V3.3"
  polygon$source_url <- paste0(service, "/layers")
  polygon$area_km2 <- as.numeric(st_area(st_transform(polygon, 3577))) / 1e6
  polygon$official_area_error_pct <-
    100 * (polygon$area_km2 - polygon$official_area_km2) / polygon$official_area_km2
  reference_point_projected <- st_transform(reference_point, 3577)
  official_point_projected <- st_transform(official_point, 3577)
  polygon_projected <- st_transform(polygon, 3577)
  polygon$outlet_inside <- lengths(st_intersects(official_point_projected, polygon_projected)) > 0L
  polygon$outlet_to_polygon_m <- as.numeric(st_distance(official_point_projected, polygon_projected))
  polygon$reference_outlet_to_polygon_m <-
    as.numeric(st_distance(reference_point_projected, polygon_projected))
  polygon$reference_coordinate_to_official_m <-
    as.numeric(st_distance(reference_point_projected, official_point_projected))
  polygon$coordinate_status <- if (polygon$reference_coordinate_to_official_m > 1000) {
    "reference coordinate needs correction"
  } else {
    "reference coordinate aligns with official gauge"
  }
  polygon$qa_status <- if (
    abs(polygon$official_area_error_pct) <= 5 && polygon$outlet_to_polygon_m <= 500
  ) {
    if (polygon$reference_coordinate_to_official_m > 1000) {
      "candidate polygon passes; reference coordinate correction required"
    } else {
      "candidate passes official Geofabric area and outlet checks"
    }
  } else {
    "hold: official Geofabric area or outlet check failed"
  }
  polygon_list[[i]] <- polygon[, c(
    "LTER", "Stream_Name", "Shapefile_Name", "polygon_source", "source_id",
    "source_url", "area_km2", "official_area_km2", "official_area_error_pct",
    "source_feature_count", "source_confidence", "source_near_distance_m",
    "official_station_longitude", "official_station_latitude", "outlet_inside",
    "outlet_to_polygon_m", "reference_outlet_to_polygon_m",
    "reference_coordinate_to_official_m", "coordinate_status", "qa_status", "geometry"
  )]
}

polygons <- do.call(rbind, polygon_list)
gpkg_path <- file.path(output_dir, "bom_geofabric_watersheds.gpkg")
layers <- if (file.exists(gpkg_path)) st_layers(gpkg_path)$name else character()
if ("bom_station_catchments" %in% layers) {
  st_delete(gpkg_path, layer = "bom_station_catchments", quiet = TRUE)
}
st_write(polygons, gpkg_path, layer = "bom_station_catchments", quiet = TRUE)

for (i in seq_len(nrow(polygons))) {
  if (!startsWith(polygons$qa_status[i], "candidate")) next
  name <- polygons$Shapefile_Name[i]
  destination_dir <- file.path(shapefile_root, name)
  dir.create(destination_dir, recursive = TRUE, showWarnings = FALSE)
  destination <- file.path(destination_dir, paste0(name, ".shp"))
  shapefile_feature <- st_sf(
    LTER = polygons$LTER[i],
    Strm_Nm = polygons$Stream_Name[i],
    shp_nm = polygons$Shapefile_Name[i],
    source_id = polygons$source_id[i],
    area_km2 = polygons$area_km2[i],
    off_area = polygons$official_area_km2[i],
    out_inside = polygons$outlet_inside[i],
    geometry = st_geometry(polygons[i, ])
  )
  st_write(shapefile_feature, destination, delete_layer = TRUE, quiet = TRUE)
}

polygon_status <- st_drop_geometry(polygons)
fwrite(
  polygon_status,
  file.path(output_dir, "bom_geofabric_qa.tsv"),
  sep = "\t", na = ""
)

print(st_drop_geometry(polygons)[, c(
  "LTER", "Stream_Name", "Shapefile_Name", "area_km2", "official_area_km2",
  "official_area_error_pct", "source_feature_count", "outlet_inside",
  "outlet_to_polygon_m", "reference_coordinate_to_official_m", "coordinate_status",
  "qa_status"
)])
