suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

sf_use_s2(FALSE)

args <- commandArgs(trailingOnly = TRUE)
catchment_archive <- cli_value(args, "--catchment-archive", required = TRUE)
network_archive <- cli_value(args, "--network-archive", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
old_geometry <- cli_value(args, "--old-geometry", "")

if (!file.exists(catchment_archive)) {
  stop("Missing SYKE catchment archive: ", catchment_archive, call. = FALSE)
}
if (!file.exists(network_archive)) {
  stop("Missing SYKE river-network archive: ", network_archive, call. = FALSE)
}

sites <- data.frame(
  Stream_Name = c(
    "Kymijoki Huruksela",
    "Kymijoki Kokonkoski",
    "Kymijoki Ahvenkoski"
  ),
  shapefile_name = c(
    "kymijoki_huruksela_syke",
    "kymijoki_kokonkoski_syke",
    "kymijoki_ahvenkoski_syke"
  ),
  Latitude = c(60.67526, 60.50865, 60.49358),
  Longitude = c(26.76723, 26.87836, 26.45088),
  preliminary_area_km2 = c(35552.7, 35721.9, 36347.2),
  stringsAsFactors = FALSE
)

sites_sf <- st_as_sf(
  sites,
  coords = c("Longitude", "Latitude"),
  crs = 4326,
  remove = FALSE
)
sites_3067 <- st_transform(sites_sf, 3067)

# These archives are official SYKE products. The source CRS is EPSG:3067;
# AppEEARS/GEE copies are written as EPSG:4326 below.
network <- st_read(
  paste0("/vsizip/", network_archive),
  layer = "Uoma10",
  quiet = TRUE
)
catchments <- st_read(
  paste0("/vsizip/", catchment_archive),
  layer = "Valumaaluejako_taso5",
  quiet = TRUE
)
outlets <- st_read(
  paste0("/vsizip/", catchment_archive),
  layer = "Valumaaluejako_purkupiste",
  quiet = TRUE
)

required_network <- c("uomapistei", "uomapist00")
required_catchments <- c("taso5_id", "osavalu_pa", "ylavalu_pa")
if (!all(required_network %in% names(network))) {
  stop("SYKE Uoma10 is missing required flow fields.", call. = FALSE)
}
if (!all(required_catchments %in% names(catchments))) {
  stop("SYKE level-5 catchments are missing required fields.", call. = FALSE)
}

# Restrict the expensive spatial matching to Kymijoki and its headwaters.
# When the old shared geometry is available, use only its bounding box as a
# search index. The old geometry is never used as a watershed result.
if (nzchar(old_geometry) && file.exists(old_geometry)) {
  old <- st_read(old_geometry, quiet = TRUE)
  old <- old[old$shp_nm == "Kymijoen vesistoalue", ]
  search_box <- st_buffer(st_as_sfc(st_bbox(st_transform(old, 3067))), 20000)
} else {
  search_box <- st_as_sfc(
    st_bbox(c(xmin = 350000, ymin = 6650000, xmax = 650000, ymax = 7100000), crs = 3067)
  )
}
catchments <- catchments[
  st_intersects(catchments, search_box, sparse = FALSE)[, 1],
]
outlets <- outlets[
  st_intersects(outlets, search_box, sparse = FALSE)[, 1],
]

# Uoma10 stores the upstream node in uomapistei and the downstream node in
# uomapist00. This direction is checked by the node elevations in the SYKE
# data and is used to walk upstream from each monitoring location.
upstream_by_downstream <- split(
  as.character(network$uomapistei),
  as.character(network$uomapist00)
)

trace_upstream <- function(line_index) {
  selected <- line_index
  frontier <- as.character(network$uomapistei[[line_index]])
  repeat {
    predecessors <- which(as.character(network$uomapist00) %in% frontier)
    predecessors <- setdiff(predecessors, selected)
    if (!length(predecessors)) break
    selected <- c(selected, predecessors)
    frontier <- unique(as.character(network$uomapistei[predecessors]))
  }
  unique(selected)
}

write_one_shapefile <- function(watershed, site) {
  out_dir <- file.path(output_root, site$shapefile_name)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  st_write(
    watershed,
    dsn = out_dir,
    layer = site$shapefile_name,
    driver = "ESRI Shapefile",
    delete_layer = TRUE,
    quiet = TRUE
  )
  file.path(out_dir, paste0(site$shapefile_name, ".shp"))
}

results <- vector("list", nrow(sites))
for (i in seq_len(nrow(sites))) {
  station <- sites_3067[i, ]
  nearest_line <- st_nearest_feature(station, network)
  station_distance_m <- as.numeric(
    st_distance(station, network[nearest_line, ], by_element = TRUE)
  )
  if (!is.finite(station_distance_m) || station_distance_m > 100) {
    stop(
      "Station is more than 100 m from the SYKE river network: ",
      sites$Stream_Name[[i]], call. = FALSE
    )
  }

  upstream_lines <- network[trace_upstream(nearest_line), ]
  line_geometry <- st_cast(st_geometry(upstream_lines), "LINESTRING")
  midpoint <- st_line_sample(line_geometry, sample = 0.5)
  midpoint_index <- st_nearest_feature(midpoint, catchments)
  midpoint_ids <- unique(catchments$taso5_id[midpoint_index])

  outlet_line <- st_nearest_feature(outlets, upstream_lines)
  outlet_distance_m <- as.numeric(
    st_distance(outlets, upstream_lines[outlet_line, ], by_element = TRUE)
  )
  outlet_ids <- unique(outlets$taso5_id[outlet_distance_m <= 100])
  containing_ids <- catchments$taso5_id[
    st_intersects(station, catchments)[[1]]
  ]
  selected_ids <- unique(c(midpoint_ids, outlet_ids, containing_ids))
  selected <- catchments[catchments$taso5_id %in% selected_ids, ]
  if (!nrow(selected)) {
    stop("No SYKE level-5 catchments matched ", sites$Stream_Name[[i]], call. = FALSE)
  }

  union_3067 <- st_union(st_geometry(selected))
  if (!all(st_is_valid(st_sf(geometry = union_3067, crs = 3067)))) {
    stop(
      "The SYKE upstream union is invalid for ", sites$Stream_Name[[i]],
      "; inspect source catchments before repairing it.",
      call. = FALSE
    )
  }
  polygon_area_km2 <- as.numeric(st_area(st_transform(
    st_sf(geometry = union_3067, crs = 3067), 6933
  ))) / 1e6
  relative_difference <- abs(polygon_area_km2 - sites$preliminary_area_km2[[i]]) /
    sites$preliminary_area_km2[[i]]
  if (relative_difference > 0.001) {
    stop(
      "SYKE polygon area does not reproduce the preliminary area for ",
      sites$Stream_Name[[i]], ": ", round(polygon_area_km2, 2), " km2",
      call. = FALSE
    )
  }

  station_wgs84 <- st_transform(station, 4326)
  watershed <- st_sf(
    site_id = paste("Finnish Environmental Institute", sites$Stream_Name[[i]], sep = "__"),
    LTER = "Finnish Environmental Institute",
    Stream_Name = sites$Stream_Name[[i]],
    source = "SYKE FEO Valuma-aluejako + Uomaverkosto",
    source_url = "https://ckan.ymparisto.fi/dataset/valuma-aluejako",
    network_url = "https://ckan.ymparisto.fi/dataset/uomaverkosto",
    source_crs = "EPSG:3067",
    polygon_area_km2 = polygon_area_km2,
    geometry = st_transform(union_3067, 4326)
  )
  station_inside <- length(st_intersects(station_wgs84, watershed)[[1]]) == 1L
  if (!station_inside) {
    stop("Station is outside the reconstructed SYKE watershed: ", sites$Stream_Name[[i]], call. = FALSE)
  }

  output_file <- write_one_shapefile(watershed, sites[i, ])
  results[[i]] <- data.frame(
    Stream_Name = sites$Stream_Name[[i]],
    Shapefile_Name = sites$shapefile_name[[i]],
    source = "SYKE FEO Valuma-aluejako + Uomaverkosto",
    source_crs = "EPSG:3067",
    output_crs = "EPSG:4326",
    preliminary_area_km2 = sites$preliminary_area_km2[[i]],
    polygon_area_km2 = polygon_area_km2,
    station_distance_m = station_distance_m,
    upstream_line_count = nrow(upstream_lines),
    selected_level5_catchments = nrow(selected),
    output_file = output_file,
    stringsAsFactors = FALSE
  )
}

summary <- do.call(rbind, results)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
write.table(
  summary,
  file.path(output_root, "kymijoki_syke_watershed_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)
print(summary, row.names = FALSE)
