library(sf)
library(dplyr)
library(stringi)

box_root <- Sys.getenv(
  "SISYN_BOX_ROOT",
  unset = "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn"
)

date_tag <- Sys.getenv("GEE_WATERSHED_DATE", unset = "20260629")
spatial_root <- file.path(box_root, "spatial-data-extractions")
wide_file <- Sys.getenv(
  "GEE_WIDE_SPATIAL_FILE",
  unset = file.path(spatial_root, "spatial-data-files", "appeears-nasa", paste0("all-data_si-extract_3_", date_tag, ".csv"))
)
base_watershed_file <- Sys.getenv(
  "GEE_BASE_WATERSHED_FILE",
  unset = file.path(spatial_root, "silica-shapefiles", "site-coordinates", "silica-watersheds_hydrosheds_DR_2.shp")
)
individual_roots <- strsplit(
  Sys.getenv(
    "GEE_INDIVIDUAL_SHAPEFILE_ROOTS",
    unset = paste(
      file.path(spatial_root, "silica-shapefiles", "reprojected"),
      file.path(spatial_root, "silica-shapefiles", "artisanal-shapefiles-2"),
      sep = "|"
    )
  ),
  "[|]",
  fixed = FALSE
)[[1]]
output_dir <- Sys.getenv(
  "GEE_UPLOAD_OUTPUT_DIR",
  unset = file.path(spatial_root, "spatial-data-files", "gee", "earth-engine-input-files", paste0(date_tag, "-gee-watersheds"))
)

norm_key <- function(x) {
  x <- stringi::stri_trans_general(as.character(x), "Latin-ASCII")
  x <- tolower(trimws(x))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  gsub("_+", "_", x)
}

site_key <- function(lter, shapefile_name, discharge_file_name = "") {
  paste(norm_key(lter), norm_key(shapefile_name), norm_key(discharge_file_name), sep = "||")
}

safe_asset_id <- function(lter, shapefile_name) {
  out <- paste(norm_key(lter), norm_key(shapefile_name), sep = "__")
  substr(out, 1, 100)
}

read_watershed <- function(path) {
  x <- st_read(path, quiet = TRUE)
  if (is.na(st_crs(x))) {
    st_crs(x) <- 4326
  }
  x <- st_make_valid(st_transform(x, 4326))
  x
}

standardize_base <- function(x) {
  x %>%
    mutate(
      Shapefile_Name = if ("shp_nm" %in% names(.)) shp_nm else NA_character_,
      Stream_Name = if ("Strm_Nm" %in% names(.)) Strm_Nm else NA_character_,
      Discharge_File_Name = if ("Dsc_F_N" %in% names(.)) Dsc_F_N else NA_character_,
      expected_area_km2 = dplyr::coalesce(
        suppressWarnings(as.numeric(if ("exp_area" %in% names(.)) exp_area else NA_real_)),
        suppressWarnings(as.numeric(if ("exp_are" %in% names(.)) exp_are else NA_real_))
      ),
      polygon_area_km2 = dplyr::coalesce(
        suppressWarnings(as.numeric(if ("real_area" %in% names(.)) real_area else NA_real_)),
        suppressWarnings(as.numeric(if ("real_ar" %in% names(.)) real_ar else NA_real_))
      ),
      hydrosheds_id = if ("hydrshd" %in% names(.)) as.character(hydrshd) else NA_character_,
      source_file = base_watershed_file,
      source_type = "combined_existing"
    ) %>%
    select(
      LTER,
      Shapefile_Name,
      Stream_Name,
      Discharge_File_Name,
      expected_area_km2,
      polygon_area_km2,
      hydrosheds_id,
      source_file,
      source_type,
      geometry
    )
}

find_individual_shapefiles <- function(roots) {
  paths <- unlist(lapply(roots, function(root) {
    if (!dir.exists(root)) {
      return(character())
    }
    list.files(root, pattern = "[.]shp$", recursive = TRUE, full.names = TRUE)
  }))
  data.frame(
    path = paths,
    stem = tools::file_path_sans_ext(basename(paths)),
    stem_key = norm_key(tools::file_path_sans_ext(basename(paths))),
    stringsAsFactors = FALSE
  )
}

preferred_individual_path <- function(matches) {
  if (!nrow(matches)) {
    return(NA_character_)
  }
  reprojected <- grepl("/reprojected/", matches$path, fixed = TRUE)
  matches$path[order(!reprojected, nchar(matches$path))][1]
}

manual_shape_key <- c(
  "amazon__amazon_river_at_itapeua" = "itapeua",
  "amazon__amazon_river_at_santo_antonio_do_ica" = "amazon_santoantonio",
  "amazon__amazon_river_at_vargem_grande" = "amazon_vergemgrande",
  "congo_basin__mbalmayo" = "nyong_mbalmayo",
  "congo_basin__messam" = "awout_messam",
  "congo_basin__olama" = "nyong_olama",
  "congo_basin__pont_so_o" = "soo_pontsoo",
  "seine__paris_12e_arrondissement" = "arrondissement_12",
  "usgs__arkansas_river_at_murray_dam" = "arkansas",
  "usgs__columbia_river_at_port_westward" = "columbia"
)

match_individual_path <- function(row, index) {
  lter_key <- norm_key(row$LTER)
  shape_key <- norm_key(row$Shapefile_Name)
  stream_key <- norm_key(row$Stream_Name)
  manual_key <- paste(lter_key, shape_key, sep = "__")

  candidate_keys <- unique(c(
    shape_key,
    stream_key,
    unname(manual_shape_key[manual_key]),
    gsub("^amazon_river_at_", "amazon_", shape_key),
    gsub("^rio_", "rio_", shape_key)
  ))
  candidate_keys <- candidate_keys[!is.na(candidate_keys) & nzchar(candidate_keys)]

  matches <- index[index$stem_key %in% candidate_keys, , drop = FALSE]
  preferred_individual_path(matches)
}

read_individual_for_row <- function(row, path) {
  x <- read_watershed(path)
  if (nrow(x) > 1) {
    x <- x[1, ]
  }
  st_sf(
    LTER = row$LTER,
    Shapefile_Name = row$Shapefile_Name,
    Stream_Name = row$Stream_Name,
    Discharge_File_Name = row$Discharge_File_Name,
    expected_area_km2 = suppressWarnings(as.numeric(row$drainage_area)),
    polygon_area_km2 = NA_real_,
    hydrosheds_id = NA_character_,
    source_file = path,
    source_type = "individual_shapefile",
    geometry = st_geometry(x),
    crs = st_crs(x)
  )
}

message("Reading current spatial file: ", wide_file)
wide <- read.csv(wide_file, check.names = FALSE, stringsAsFactors = FALSE)
wide$.site_key <- site_key(wide$LTER, wide$Shapefile_Name, wide$Discharge_File_Name)

message("Reading base watershed file: ", base_watershed_file)
base <- standardize_base(read_watershed(base_watershed_file))
base$.site_key <- site_key(base$LTER, base$Shapefile_Name, base$Discharge_File_Name)
base <- base[base$.site_key %in% wide$.site_key, ]

missing_rows <- wide[!wide$.site_key %in% base$.site_key, , drop = FALSE]
shape_index <- find_individual_shapefiles(individual_roots)

if (nrow(missing_rows)) {
  missing_rows$matched_path <- vapply(
    seq_len(nrow(missing_rows)),
    function(i) match_individual_path(missing_rows[i, , drop = FALSE], shape_index),
    character(1)
  )
}

matched_missing <- missing_rows[!is.na(missing_rows$matched_path), , drop = FALSE]
unmatched_missing <- missing_rows[is.na(missing_rows$matched_path), , drop = FALSE]

individual <- lapply(seq_len(nrow(matched_missing)), function(i) {
  read_individual_for_row(matched_missing[i, , drop = FALSE], matched_missing$matched_path[[i]])
})
individual <- if (length(individual)) do.call(rbind, individual) else base[0, ]
individual$.site_key <- site_key(individual$LTER, individual$Shapefile_Name, individual$Discharge_File_Name)

out <- rbind(base, individual)
out <- out[!duplicated(out$.site_key), ]

computed_polygon_area_km2 <- as.numeric(st_area(st_transform(out, 5070))) / 1e6
out$polygon_area_km2 <- dplyr::coalesce(
  suppressWarnings(as.numeric(out$polygon_area_km2)),
  computed_polygon_area_km2
)

wide_order <- match(out$.site_key, wide$.site_key)
out <- out[order(wide_order), ]
out$site_id <- safe_asset_id(out$LTER, out$Shapefile_Name)
out$hydrosheds_used <- !is.na(out$hydrosheds_id) & trimws(out$hydrosheds_id) != ""
area_for_group <- suppressWarnings(as.numeric(out$expected_area_km2))
large_site <- !is.na(area_for_group) & area_for_group >= 500000
out$run_group <- NA_character_
out$run_group[large_site] <- paste0("large_", sprintf("%03d", seq_len(sum(large_site))))
out$run_group[!large_site] <- paste0("batch_", sprintf("%03d", ceiling(seq_len(sum(!large_site)) / 35)))

out <- out %>%
  select(
    .site_key,
    site_id,
    run_group,
    LTER,
    Shapefile_Name,
    Stream_Name,
    Discharge_File_Name,
    hydrosheds_used,
    hydrosheds_id,
    expected_area_km2,
    polygon_area_km2,
    source_type,
    source_file,
    geometry
  )

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
geojson_file <- file.path(output_dir, paste0("silica_gee_watersheds_", date_tag, ".geojson"))
gpkg_file <- file.path(output_dir, paste0("silica_gee_watersheds_", date_tag, ".gpkg"))
shp_dir <- file.path(output_dir, paste0("silica_gee_watersheds_", date_tag, "_shapefile"))
shp_file <- file.path(shp_dir, paste0("silica_gee_watersheds_", date_tag, ".shp"))
zip_file <- file.path(output_dir, paste0("silica_gee_watersheds_", date_tag, "_shapefile.zip"))
match_file <- file.path(output_dir, paste0("watershed-geometry-check_", date_tag, ".csv"))

out_for_write <- out %>% select(-.site_key)
st_write(out_for_write, geojson_file, quiet = TRUE, delete_dsn = TRUE)
st_write(out_for_write, gpkg_file, quiet = TRUE, delete_dsn = TRUE)
dir.create(shp_dir, recursive = TRUE, showWarnings = FALSE)
st_write(out_for_write, shp_file, quiet = TRUE, delete_layer = TRUE)
old_wd <- getwd()
setwd(shp_dir)
utils::zip(zipfile = zip_file, files = list.files(shp_dir), flags = "-q")
setwd(old_wd)

match_report <- wide %>%
  select(LTER, Shapefile_Name, Stream_Name, Discharge_File_Name, drainage_area) %>%
  mutate(.site_key = site_key(LTER, Shapefile_Name, Discharge_File_Name)) %>%
  left_join(st_drop_geometry(out) %>% select(.site_key, site_id, run_group, source_type, source_file), by = ".site_key") %>%
  mutate(match_status = ifelse(is.na(site_id), "missing_geometry", "matched")) %>%
  select(-.site_key)
write.csv(match_report, match_file, row.names = FALSE, na = "")

message("Wrote: ", geojson_file)
message("Wrote: ", gpkg_file)
message("Wrote: ", zip_file)
message("Wrote: ", match_file)
message("Matched features: ", nrow(out))
message("Missing geometry rows: ", sum(match_report$match_status == "missing_geometry"))
