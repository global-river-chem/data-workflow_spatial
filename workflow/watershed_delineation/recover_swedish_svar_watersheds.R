suppressPackageStartupMessages({
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

source_url <- paste0(
  "https://opendata-download.smhi.se/svar/",
  "Avrinningsomraden_2016.zip"
)
source_page <- paste0(
  "https://www.smhi.se/data/sok-oppna-data-i-utforskaren/",
  "huvud-och-delavrinningsomraden-svar2016"
)

args <- commandArgs(trailingOnly = TRUE)
output_dir <- cli_value(args, "--output-root", required = TRUE)
existing_gpkg <- cli_value(args, "--existing-watersheds", "")
sites_path <- cli_value(
  args, "--targets",
  file.path("workflow", "watershed_delineation", "config", "sweden_svar_targets.tsv")
)
zip_path <- cli_value(args, "--archive", "")

sites <- read_workflow_table(sites_path)
require_columns(
  sites,
  c(
    "Stream_Name", "Shapefile_Name", "previous_name", "latitude", "longitude",
    "reported_area_km2", "outlet_aroid", "write_replacement"
  ),
  "SVAR target table"
)
sites$write_replacement <- tolower(sites$write_replacement) %in% c("true", "yes", "1")

if (!nzchar(zip_path)) {
  zip_path <- file.path(tempdir(), "Avrinningsomraden_2016.zip")
  if (!file.exists(zip_path)) {
    download.file(source_url, zip_path, mode = "wb", quiet = FALSE)
  }
}
if (!file.exists(zip_path)) stop("SMHI SVAR archive not found: ", zip_path)

sf_use_s2(FALSE)
svar <- st_read(
  paste0("/vsizip/", normalizePath(zip_path)),
  quiet = TRUE
)

required <- c("AROID", "OMRID_NED", "AREAL", "AAUEB", "AA_ANT_ARO")
missing <- setdiff(required, names(svar))
if (length(missing)) stop("SMHI SVAR file is missing: ", paste(missing, collapse = ", "))

svar$AROID <- as.character(svar$AROID)
svar$OMRID_NED <- as.character(svar$OMRID_NED)
upstream_lookup <- split(svar$AROID, svar$OMRID_NED)

trace_upstream <- function(outlet_aroid) {
  selected_ids <- outlet_aroid
  frontier <- outlet_aroid
  while (length(frontier)) {
    next_ids <- unique(unlist(upstream_lookup[frontier], use.names = FALSE))
    next_ids <- setdiff(next_ids, selected_ids)
    selected_ids <- c(selected_ids, next_ids)
    frontier <- next_ids
  }
  selected <- svar[match(selected_ids, svar$AROID), ]
  if (any(is.na(selected$AROID))) {
    stop("Could not match an upstream SVAR unit for ", outlet_aroid)
  }
  selected
}

existing <- NULL
if (nzchar(existing_gpkg) && file.exists(existing_gpkg)) {
  existing <- st_read(existing_gpkg, quiet = TRUE)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

qa <- lapply(seq_len(nrow(sites)), function(i) {
  site <- sites[i, ]
  focal_index <- match(site$outlet_aroid, svar$AROID)
  if (is.na(focal_index)) stop("Outlet AROID is absent: ", site$outlet_aroid)

  selected <- trace_upstream(site$outlet_aroid)
  expected_count <- as.integer(svar$AA_ANT_ARO[focal_index])
  if (nrow(selected) != expected_count) {
    stop(
      site$Stream_Name, ": traced ", nrow(selected),
      " units but SVAR reports ", expected_count
    )
  }

  union_3006 <- st_union(st_geometry(st_make_valid(selected)))
  watershed <- st_sf(
    site_id = paste0("sweden__", site$Shapefile_Name),
    lter = "Sweden",
    stream = site$Stream_Name,
    shp_name = site$Shapefile_Name,
    source = "SMHI SVAR 2016_8 upstream watershed",
    out_aroid = site$outlet_aroid,
    rep_km2 = site$reported_area_km2,
    svar_km2 = as.numeric(svar$AAUEB[focal_index]),
    n_units = nrow(selected),
    geometry = union_3006
  )
  watershed$poly_km2 <- as.numeric(st_area(watershed)) / 1e6
  watershed <- st_transform(st_make_valid(watershed), 4326)

  station <- st_as_sf(
    data.frame(lon = site$longitude, lat = site$latitude),
    coords = c("lon", "lat"), crs = 4326
  )
  outlet_distance_m <- as.numeric(st_distance(
    st_transform(station, 3006), st_transform(watershed, 3006),
    by_element = TRUE
  ))

  overlap_pct <- NA_real_
  if (!is.null(existing)) {
    old <- existing[existing$Shapefile_Name == site$previous_name, ]
    if (nrow(old) == 1) {
      old_3006 <- st_make_valid(st_transform(old, 3006))
      new_3006 <- st_make_valid(st_transform(watershed, 3006))
      intersection_area <- sum(as.numeric(
        st_area(suppressWarnings(st_intersection(old_3006, new_3006)))
      ))
      old_area <- as.numeric(st_area(old_3006))
      overlap_pct <- 100 * intersection_area / old_area
    }
  }

  if (isTRUE(site$write_replacement)) {
    site_dir <- file.path(output_dir, site$Shapefile_Name)
    dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
    output_path <- file.path(site_dir, paste0(site$Shapefile_Name, ".shp"))
    st_write(watershed, output_path, delete_layer = TRUE, quiet = TRUE)
  } else {
    output_path <- NA_character_
  }

  data.frame(
    Stream_Name = site$Stream_Name,
    previous_name = site$previous_name,
    Shapefile_Name = if (site$write_replacement) site$Shapefile_Name else site$previous_name,
    outlet_aroid = site$outlet_aroid,
    upstream_unit_count = nrow(selected),
    reported_area_km2 = site$reported_area_km2,
    svar_upstream_area_km2 = as.numeric(svar$AAUEB[focal_index]),
    geometry_area_km2 = watershed$poly_km2,
    area_difference_pct = 100 * (
      watershed$poly_km2 - site$reported_area_km2
    ) / site$reported_area_km2,
    station_to_polygon_m = outlet_distance_m,
    old_polygon_overlap_pct = overlap_pct,
    decision = if (site$write_replacement) "replace and rerun" else "retain; no rerun",
    output_path = output_path,
    stringsAsFactors = FALSE
  )
})

qa <- do.call(rbind, qa)
write.table(
  qa, file.path(output_dir, "sweden_svar_qa.tsv"),
  sep = "\t", quote = FALSE, row.names = FALSE, na = ""
)
print(qa, row.names = FALSE)
cat("Source page: ", source_page, "\n", sep = "")
cat("Output folder: ", output_dir, "\n", sep = "")
