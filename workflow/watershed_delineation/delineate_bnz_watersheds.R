suppressPackageStartupMessages({
  library(sf)
  library(terra)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
work_dir <- cli_value(args, "--work-root", file.path(tempdir(), "bnz-watershed-work"))
source_root <- cli_value(args, "--source-root", file.path(work_dir, "source-data"))
whitebox <- Sys.getenv("WHITEBOX_TOOLS", unset = "")

if (!nzchar(whitebox)) {
  whitebox <- Sys.which("whitebox_tools")
}
if (!nzchar(whitebox) && requireNamespace("whitebox", quietly = TRUE)) {
  whitebox <- whitebox::wbt_exe_path(shell_quote = FALSE)
}
if (!nzchar(whitebox) || !file.exists(whitebox)) {
  stop(
    "WhiteboxTools is required. Install it with whitebox::wbt_install() or set ",
    "WHITEBOX_TOOLS to the whitebox_tools executable.",
    call. = FALSE
  )
}

dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(source_root, recursive = TRUE, showWarnings = FALSE)

source_archives <- data.frame(
  folder = c("sites", "streams", "dem", "boundary"),
  filename = c(
    "141_bnz_sites.zip", "432_cpcrw_stream.zip",
    "435_cpcrw_dem.zip", "436_cpcrw_boundary.zip"
  ),
  url = c(
    "https://pasta.lternet.edu/package/data/eml/knb-lter-bnz/125/20/3ead78809f91f14119db693b923bbb57",
    "https://pasta.lternet.edu/package/data/eml/knb-lter-bnz/432/18/b4ccefbff733b07a8a2ef9db5184dca6",
    "https://pasta.lternet.edu/package/data/eml/knb-lter-bnz/435/18/6add185e7d4250610488b16a9ff03bd4",
    "https://pasta.lternet.edu/package/data/eml/knb-lter-bnz/436/18/bf390c571d0aca08314dc0f83f9e89cc"
  ),
  stringsAsFactors = FALSE
)

expected_sources <- c(
  file.path(source_root, "sites", "BNZ_Sites.shp"),
  file.path(source_root, "streams", "cpcrw_stream.shp"),
  file.path(source_root, "dem", "cpcrw_dem.tif"),
  file.path(source_root, "boundary", "cpcrw_bound_nad83.shp")
)
for (i in seq_len(nrow(source_archives))) {
  if (file.exists(expected_sources[i])) next
  archive_path <- file.path(source_root, source_archives$filename[i])
  if (!file.exists(archive_path)) {
    download.file(source_archives$url[i], archive_path, mode = "wb", quiet = FALSE)
  }
  extraction_dir <- file.path(source_root, source_archives$folder[i])
  dir.create(extraction_dir, recursive = TRUE, showWarnings = FALSE)
  unzip(archive_path, exdir = extraction_dir)
}

dem_path <- file.path(source_root, "dem", "cpcrw_dem.tif")
stream_path <- file.path(source_root, "streams", "cpcrw_stream.shp")
boundary_path <- file.path(source_root, "boundary", "cpcrw_bound_nad83.shp")

required <- c(dem_path, stream_path, boundary_path, whitebox)
if (any(!file.exists(required))) {
  stop("Missing BNZ source file or WhiteboxTools binary: ",
       paste(required[!file.exists(required)], collapse = ", "), call. = FALSE)
}

dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
watershed_dir <- output_root
qa_dir <- file.path(output_root, "qa")
dir.create(watershed_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(qa_dir, recursive = TRUE, showWarnings = FALSE)

dem <- rast(dem_path)
streams <- st_read(stream_path, quiet = TRUE)
boundary <- st_read(boundary_path, quiet = TRUE)
streams_dem <- st_transform(streams, crs(dem))
boundary_dem <- st_transform(boundary, crs(dem))
streams_dem$row_id <- seq_len(nrow(streams_dem))

streams_dem_path <- file.path(work_dir, "cpcrw_stream_dem_crs.shp")
st_write(streams_dem, streams_dem_path, delete_layer = TRUE, quiet = TRUE)

# Coordinates are from the current BNZ stream-chemistry package (EDI package
# knb-lter-bnz.152.24), not the displaced coordinates in the living table.
sites <- data.frame(
  site = c("C2", "C3", "C4", "CB", "CJ", "P6", "PC", "PJ"),
  latitude = c(
    65.15876438, 65.14329713, 65.16304593, 65.15000000,
    65.15147902, 65.18479100, 65.15101230, 65.15154566
  ),
  longitude = c(
    -147.6039280, -147.5713145, -147.4986663, -147.5600000,
    -147.4856181, -147.3889390, -147.4823850, -147.4841681
  ),
  # The legacy BNZ site GIS is aligned to the companion stream network and is
  # therefore used to place C2-C4 on that network. The other outlets are set by
  # their documented positions relative to stream junctions below.
  outlet_latitude = c(
    65.16015, 65.14468, 65.16443, NA, NA, NA, NA, NA
  ),
  outlet_longitude = c(
    -147.6065, -147.5739, -147.5013, NA, NA, NA, NA, NA
  ),
  # Official stream-line row selected for each monitoring location. CJ and PJ
  # are intentionally snapped to different upstream branches of the junction;
  # PC is snapped to the downstream branch.
  stream_row = c(93L, 32L, 126L, 27L, 124L, 128L, 196L, 180L),
  # Fraction along the selected official stream line when the monitoring-site
  # description identifies a junction or when no point exists in the site GIS.
  # CB is kept above the C3 confluence. CJ, PJ, and PC are placed on the three
  # separate branches around the Caribou-Poker junction. The EDI coordinate for
  # P6 is inside the named basin rather than at its outlet; its outlet is placed
  # on the official Poker network where the upstream area matches the published
  # P6 drainage area of 2.7 mi2 (6.99 km2).
  stream_fraction = c(NA, NA, NA, 0.09, 0.75, 0.90, 0.03, 0.98),
  snap_search_m = c(30, 30, 30, 30, 30, 30, 30, 60),
  reference_area_km2 = c(5.18, 5.70, 10.00, NA, 42.73, 6.99, 105.67, 62.94),
  reference_area_basis = c(
    "Slaughter et al. 1971 basin table",
    "Slaughter et al. 1971 basin table",
    "Petrone et al. 2006 basin description",
    "No published site-specific area; validate against stream topology",
    "Slaughter et al. 1971 Caribou total",
    "Slaughter et al. 1971 basin table",
    "Slaughter et al. 1971 Caribou-Poker total",
    "Slaughter et al. 1971 Poker total"
  ),
  stringsAsFactors = FALSE
)

raw_points <- st_as_sf(sites, coords = c("longitude", "latitude"), crs = 4326)
raw_points_dem <- st_transform(raw_points, crs(dem))
outlet_source <- sites
outlet_source$outlet_latitude[is.na(outlet_source$outlet_latitude)] <-
  outlet_source$latitude[is.na(outlet_source$outlet_latitude)]
outlet_source$outlet_longitude[is.na(outlet_source$outlet_longitude)] <-
  outlet_source$longitude[is.na(outlet_source$outlet_longitude)]
outlet_source_points <- st_as_sf(
  outlet_source,
  coords = c("outlet_longitude", "outlet_latitude"),
  crs = 4326
)
outlet_source_points_dem <- st_transform(outlet_source_points, crs(dem))

snap_to_line <- function(point, line) {
  connector <- st_nearest_points(st_geometry(point), st_geometry(line))
  coordinates <- st_coordinates(connector)
  st_sfc(st_point(coordinates[nrow(coordinates), c("X", "Y")]), crs = st_crs(line))
}

line_points <- vector("list", nrow(sites))
for (i in seq_len(nrow(sites))) {
  selected_line <- st_cast(
    st_geometry(streams_dem[sites$stream_row[i], ]),
    "LINESTRING"
  )
  if (is.na(sites$stream_fraction[i])) {
    line_points[[i]] <- snap_to_line(
      outlet_source_points_dem[i, ], streams_dem[sites$stream_row[i], ]
    )[[1]]
  } else {
    line_points[[i]] <- st_cast(
      st_line_sample(selected_line, sample = sites$stream_fraction[i]),
      "POINT"
    )[[1]]
  }
}
line_points <- st_sf(
  sites,
  point_to_stream_m = as.numeric(st_distance(
    outlet_source_points_dem,
    st_sf(geometry = st_sfc(line_points, crs = st_crs(streams_dem))),
    by_element = TRUE
  )),
  geometry = st_sfc(line_points, crs = st_crs(streams_dem))
)
sites$point_to_stream_m <- line_points$point_to_stream_m

line_points_path <- file.path(work_dir, "bnz_outlets_on_official_streams.shp")
st_write(line_points, line_points_path, delete_layer = TRUE, quiet = TRUE)

run_wbt <- function(tool, arguments) {
  result <- system2(
    whitebox,
    c(paste0("-r=", tool), "-v", paste0("--wd=", shQuote(work_dir)), arguments),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(result, "status")
  if (!is.null(status) && status != 0L) {
    stop(tool, " failed:\n", paste(result, collapse = "\n"), call. = FALSE)
  }
  invisible(result)
}

burned_dem <- file.path(work_dir, "cpcrw_dem_stream_burned.tif")
conditioned_dem <- file.path(work_dir, "cpcrw_dem_conditioned.tif")
pointer <- file.path(work_dir, "cpcrw_d8_pointer.tif")
accumulation <- file.path(work_dir, "cpcrw_d8_accumulation_cells.tif")

if (!file.exists(burned_dem)) {
  run_wbt("FillBurn", c(
    paste0("--dem=", shQuote(dem_path)),
    paste0("--streams=", shQuote(streams_dem_path)),
    paste0("--output=", shQuote(burned_dem))
  ))
}
if (!all(file.exists(c(conditioned_dem, pointer, accumulation)))) {
  run_wbt("FlowAccumulationFullWorkflow", c(
    paste0("--dem=", shQuote(burned_dem)),
    paste0("--out_dem=", shQuote(conditioned_dem)),
    paste0("--out_pntr=", shQuote(pointer)),
    paste0("--out_accum=", shQuote(accumulation)),
    "--out_type=cells", "--correct_pntr"
  ))
}

watersheds <- vector("list", nrow(sites))
snapped_outlets <- vector("list", nrow(sites))
for (i in seq_len(nrow(sites))) {
  site_slug <- tolower(sites$site[i])
  point_path <- file.path(work_dir, paste0("bnz_", site_slug, "_line_point.shp"))
  snapped_path <- file.path(work_dir, paste0("bnz_", site_slug, "_snapped_point.shp"))
  raster_path <- file.path(work_dir, paste0("bnz_", site_slug, "_watershed.tif"))

  one_point <- line_points[i, c("site")]
  one_point$outlet_id <- 1L
  st_write(one_point, point_path, delete_layer = TRUE, quiet = TRUE)

  run_wbt("SnapPourPoints", c(
    paste0("--pour_pts=", shQuote(point_path)),
    paste0("--flow_accum=", shQuote(accumulation)),
    paste0("--output=", shQuote(snapped_path)),
    paste0("--snap_dist=", sites$snap_search_m[i])
  ))
  run_wbt("Watershed", c(
    paste0("--d8_pntr=", shQuote(pointer)),
    paste0("--pour_pts=", shQuote(snapped_path)),
    paste0("--output=", shQuote(raster_path))
  ))

  snapped <- st_read(snapped_path, quiet = TRUE)
  snapped <- st_transform(snapped, crs(dem))
  snapped_outlets[[i]] <- st_geometry(snapped)[[1]]

  basin_raster <- rast(raster_path)
  basin_raster[basin_raster <= 0] <- NA
  polygon <- as.polygons(basin_raster, dissolve = TRUE, na.rm = TRUE)
  if (nrow(polygon) != 1L) {
    stop("Unexpected watershed raster for ", sites$site[i], call. = FALSE)
  }
  polygon <- st_as_sf(polygon)
  polygon <- st_make_valid(polygon)
  polygon <- st_sf(
    site_id = paste("BNZ", sites$site[i], sep = "__"),
    LTER = "BNZ",
    Stream_Name = sites$site[i],
    Shapefile_Name = paste0("bnz_", site_slug, "_watershed"),
    source = "BNZ official 30 m DEM and stream network",
    geometry = st_geometry(polygon)
  )
  watersheds[[i]] <- polygon
}

watersheds_dem <- do.call(rbind, watersheds)
snapped_outlets_dem <- st_sf(
  sites[c("site", "latitude", "longitude", "stream_row")],
  geometry = st_sfc(snapped_outlets, crs = st_crs(streams_dem))
)
snapped_outlets_wgs84 <- st_transform(snapped_outlets_dem, 4326)
snapped_xy <- st_coordinates(snapped_outlets_wgs84)
sites$derived_outlet_longitude <- snapped_xy[, "X"]
sites$derived_outlet_latitude <- snapped_xy[, "Y"]

watersheds_equal_area <- st_transform(watersheds_dem, 3338)
sites$polygon_area_km2 <- as.numeric(st_area(watersheds_equal_area)) / 1e6
sites$area_difference_pct <- 100 * (
  sites$polygon_area_km2 - sites$reference_area_km2
) / sites$reference_area_km2
sites$snap_distance_m <- as.numeric(st_distance(
  line_points,
  snapped_outlets_dem,
  by_element = TRUE
))

# Pairwise containment/union checks test the known Caribou-Poker topology.
contains_fraction <- function(container, member) {
  intersection <- suppressWarnings(st_intersection(
    st_geometry(watersheds_equal_area[container, ]),
    st_geometry(watersheds_equal_area[member, ])
  ))
  if (length(intersection) == 0L) return(0)
  as.numeric(sum(st_area(intersection)) / st_area(watersheds_equal_area[member, ]))
}

qa_relationships <- data.frame(
  test = c(
    "CB contains C2", "CB excludes C3",
    "CJ contains C2", "CJ contains C3", "CJ contains C4", "CJ contains CB",
    "PJ contains P6", "PC contains CJ", "PC contains PJ",
    "CJ and PJ do not overlap"
  ),
  rule = c(
    ">= 0.99", "<= 0.01",
    rep(">= 0.99", 7), "<= 0.01"
  ),
  fraction_contained = c(
    contains_fraction(4, 1), contains_fraction(4, 2),
    contains_fraction(5, 1), contains_fraction(5, 2),
    contains_fraction(5, 3), contains_fraction(5, 4),
    contains_fraction(8, 6), contains_fraction(7, 5),
    contains_fraction(7, 8), contains_fraction(5, 8)
  )
)
qa_relationships$passed <- c(
  qa_relationships$fraction_contained[1] >= 0.99,
  qa_relationships$fraction_contained[2] <= 0.01,
  qa_relationships$fraction_contained[3:9] >= 0.99,
  qa_relationships$fraction_contained[10] <= 0.01
)

sites$accepted <- is.na(sites$reference_area_km2) |
  abs(sites$area_difference_pct) <= 15
if (any(!qa_relationships$passed)) {
  sites$accepted <- FALSE
}

watersheds_wgs84 <- st_transform(watersheds_dem, 4326)
watersheds_wgs84$polygon_area_km2 <- sites$polygon_area_km2
watersheds_wgs84$reference_area_km2 <- sites$reference_area_km2
watersheds_wgs84$area_difference_pct <- sites$area_difference_pct
watersheds_wgs84$accepted <- sites$accepted

print(sites[c(
  "site", "point_to_stream_m", "snap_distance_m", "reference_area_km2",
  "polygon_area_km2", "area_difference_pct", "accepted"
)], row.names = FALSE)
print(qa_relationships, row.names = FALSE)

if (!all(sites$accepted)) {
  stop("One or more BNZ watershed polygons failed QA; none should be copied to Box or submitted.",
       call. = FALSE)
}

gpkg_path <- file.path(qa_dir, "bnz_watersheds.gpkg")
st_write(watersheds_wgs84, gpkg_path, delete_dsn = TRUE, quiet = TRUE)
for (i in seq_len(nrow(sites))) {
  site_dir <- file.path(watershed_dir, watersheds_wgs84$Shapefile_Name[i])
  dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
  st_write(
    watersheds_wgs84[i, ],
    file.path(site_dir, paste0(watersheds_wgs84$Shapefile_Name[i], ".shp")),
    delete_layer = TRUE,
    quiet = TRUE
  )
}

st_write(
  snapped_outlets_wgs84,
  file.path(qa_dir, "bnz_snapped_outlets.gpkg"),
  delete_dsn = TRUE,
  quiet = TRUE
)
write.table(
  sites,
  file.path(qa_dir, "bnz_watershed_area_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)
write.table(
  qa_relationships,
  file.path(qa_dir, "bnz_watershed_relationship_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)

plot_order <- c(7, 8, 5, 4, 3, 2, 1, 6)
plot_colors <- c(
  PC = "#303030", PJ = "#0072B2", CJ = "#D55E00", CB = "#009E73",
  C4 = "#CC79A7", C3 = "#E69F00", C2 = "#56B4E9", P6 = "#F0E442"
)
png(
  file.path(qa_dir, "bnz_watershed_map.png"),
  width = 1800, height = 1600, res = 200
)
par(mar = c(1, 1, 3, 1))
plot(st_geometry(boundary_dem), col = "grey96", border = "grey50", lwd = 1.5)
plot(st_geometry(streams_dem), add = TRUE, col = "#6BAED6", lwd = 0.7)
for (i in plot_order) {
  plot(
    st_geometry(watersheds_dem[i, ]), add = TRUE,
    border = plot_colors[sites$site[i]], lwd = 2
  )
}
plot(
  st_geometry(snapped_outlets_dem), add = TRUE,
  pch = 21, bg = plot_colors[sites$site], col = "white", cex = 1.2
)
outlet_xy <- st_coordinates(snapped_outlets_dem)
label_offset <- rbind(
  C2 = c(0, 150), C3 = c(0, -180), C4 = c(0, 150), CB = c(0, 160),
  CJ = c(-220, 110), P6 = c(0, 150), PC = c(210, -100), PJ = c(210, 130)
)
text(
  outlet_xy[, 1] + label_offset[sites$site, 1],
  outlet_xy[, 2] + label_offset[sites$site, 2],
  labels = sites$site,
  cex = 0.85
)
title("BNZ watershed delineation QA")
legend(
  "bottomleft", legend = names(plot_colors), col = plot_colors,
  lwd = 2, bty = "n", ncol = 2, cex = 0.8
)
dev.off()

cat("All eight BNZ watershed polygons passed area and topology QA.\n")
cat("WROTE: ", gpkg_path, "\n", sep = "")
