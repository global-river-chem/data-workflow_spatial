# Delineate upstream HydroBASINS watersheds from selected site-table rows.
# Site-specific outlet choices belong in the small override table, not here.

suppressPackageStartupMessages(library(sf))

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
sites_path <- cli_value(args, "--sites", required = TRUE)
hydrobasins_path <- cli_value(args, "--hydrobasins", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
override_path <- cli_value(
  args,
  "--outlet-overrides",
  file.path("workflow", "watershed_delineation", "config", "hydrobasins_outlet_overrides.tsv")
)
minimum_area_km2 <- as.numeric(cli_value(args, "--minimum-area-km2", "0"))
maximum_area_difference_pct <- as.numeric(
  cli_value(args, "--maximum-area-difference-pct", "25")
)
strict_area_check <- cli_boolean(args, "--strict-area-check", FALSE)

if (!file.exists(hydrobasins_path)) {
  stop("Missing HydroBASINS level-12 file: ", hydrobasins_path, call. = FALSE)
}
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

sites <- read_workflow_table(sites_path)
require_columns(
  sites,
  c("LTER", "Stream_Name", "Shapefile_Name", "Latitude", "Longitude", "drainSqKm"),
  "site table"
)
sites <- select_site_rows(sites, args)
sites$Reference_Area_km2 <- independent_reference_area(sites)
sites$HydroBASINS_ID <- ""

if (nzchar(override_path) && file.exists(override_path)) {
  overrides <- read_workflow_table(override_path)
  require_columns(overrides, c("LTER", "Stream_Name", "HydroBASINS_ID"), "outlet overrides")
  override_key <- paste(overrides$LTER, overrides$Stream_Name, sep = "::")
  site_key <- paste(sites$LTER, sites$Stream_Name, sep = "::")
  matched <- match(site_key, override_key)
  use_override <- !is.na(matched)
  sites$HydroBASINS_ID[use_override] <- as.character(
    overrides$HydroBASINS_ID[matched[use_override]]
  )
}

sf_use_s2(FALSE)
basins <- st_read(hydrobasins_path, quiet = TRUE)
require_columns(basins, c("HYBAS_ID", "NEXT_DOWN", "SUB_AREA", "UP_AREA"), "HydroBASINS")
if (is.na(st_crs(basins))) stop("HydroBASINS input has no CRS.", call. = FALSE)

basin_ids <- as.character(basins$HYBAS_ID)
upstream_lookup <- split(basin_ids, as.character(basins$NEXT_DOWN))

trace_upstream <- function(outlet_id) {
  selected_ids <- outlet_id
  frontier <- outlet_id
  while (length(frontier)) {
    next_ids <- unique(unlist(upstream_lookup[frontier], use.names = FALSE))
    next_ids <- setdiff(next_ids, selected_ids)
    selected_ids <- c(selected_ids, next_ids)
    frontier <- next_ids
  }
  selected <- basins[match(selected_ids, basin_ids), , drop = FALSE]
  if (any(is.na(selected$HYBAS_ID))) {
    stop("An upstream HydroBASINS ID could not be matched for ", outlet_id, call. = FALSE)
  }
  selected
}

build_one <- function(site) {
  longitude <- suppressWarnings(as.numeric(site$Longitude))
  latitude <- suppressWarnings(as.numeric(site$Latitude))
  point_available <- is.finite(longitude) && is.finite(latitude)
  point <- if (point_available) {
    st_sfc(st_point(c(longitude, latitude)), crs = 4326)
  } else {
    NULL
  }

  outlet_id <- trimws(as.character(site$HydroBASINS_ID))
  if (!nzchar(outlet_id)) {
    if (!point_available) {
      stop("No coordinates or outlet override for ", site$LTER, " / ", site$Stream_Name)
    }
    focal <- st_intersects(st_transform(point, st_crs(basins)), basins)[[1]]
    if (length(focal) != 1L) {
      stop("Expected one focal basin for ", site$LTER, " / ", site$Stream_Name)
    }
    outlet_id <- basin_ids[[focal]]
  }

  focal <- match(outlet_id, basin_ids)
  if (is.na(focal)) stop("Outlet is absent from HydroBASINS: ", outlet_id, call. = FALSE)
  selected <- trace_upstream(outlet_id)
  union <- st_union(st_geometry(st_make_valid(st_transform(selected, 6933))))
  watershed <- st_transform(st_sf(geometry = union, crs = 6933), 4326)
  area_km2 <- sum(as.numeric(selected$SUB_AREA), na.rm = TRUE)
  geometry_area_km2 <- as.numeric(st_area(st_transform(watershed, 6933))) / 1e6
  reference_area_km2 <- suppressWarnings(as.numeric(site$Reference_Area_km2))
  area_difference_pct <- if (is.finite(reference_area_km2) && reference_area_km2 > 0) {
    100 * (area_km2 - reference_area_km2) / reference_area_km2
  } else {
    NA_real_
  }
  outlet_distance_m <- if (point_available) {
    as.numeric(st_distance(st_transform(point, 6933), st_transform(watershed, 6933)))
  } else {
    NA_real_
  }

  status <- if (area_km2 < minimum_area_km2) {
    "below_minimum_area"
  } else if (is.finite(area_difference_pct) &&
      abs(area_difference_pct) > maximum_area_difference_pct) {
    "reference_area_mismatch"
  } else if (!is.finite(reference_area_km2)) {
    "no_independent_area_check"
  } else {
    "passed"
  }
  if (strict_area_check && status == "reference_area_mismatch") {
    stop(site$LTER, " / ", site$Stream_Name, " failed the drainage-area check.")
  }

  output_path <- ""
  if (status != "below_minimum_area") {
    output_dir <- file.path(output_root, site$Shapefile_Name)
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    output_path <- file.path(output_dir, paste0(site$Shapefile_Name, ".shp"))
    watershed$site_id <- paste(normalize_key(site$LTER), normalize_key(site$Stream_Name), sep = "__")
    watershed$LTER <- site$LTER
    watershed$stream <- site$Stream_Name
    watershed$shp_name <- site$Shapefile_Name
    watershed$hydro_id <- outlet_id
    watershed$area_km2 <- area_km2
    st_write(watershed, output_path, delete_layer = TRUE, quiet = TRUE)
  }

  data.frame(
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Shapefile_Name = site$Shapefile_Name,
    HydroBASINS_ID = outlet_id,
    upstream_polygon_count = nrow(selected),
    hydrobasins_area_km2 = area_km2,
    focal_up_area_km2 = as.numeric(basins$UP_AREA[[focal]]),
    geometry_area_km2 = geometry_area_km2,
    reference_area_km2 = reference_area_km2,
    area_difference_pct = area_difference_pct,
    outlet_distance_m = outlet_distance_m,
    status = status,
    output_path = output_path,
    stringsAsFactors = FALSE
  )
}

qa <- do.call(rbind, lapply(seq_len(nrow(sites)), function(index) build_one(sites[index, ])))
write.table(
  qa,
  file.path(output_root, "hydrobasins_delineation_qa.tsv"),
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
saveRDS(qa, file.path(output_root, "hydrobasins_delineation_qa.rds"))
print(qa, row.names = FALSE)
