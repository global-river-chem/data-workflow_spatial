# Build deterministic equal-area sample points for large GLC watersheds

suppressPackageStartupMessages({
  library(dplyr)
  library(jsonlite)
  library(openssl)
  library(readr)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

# ---- Options ----

args <- commandArgs(trailingOnly = TRUE)
watershed_path <- cli_value(args, "--watersheds", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
sample_n <- cli_integer(args, "--sample-points", 10000L, minimum = 1000L)
site_ids <- cli_values(args, "--site-id")
expected_sampled_sites <- cli_integer(args, "--expected-sampled-sites")
exact_max_work <- as.numeric(cli_value(
  args,
  "--exact-max-work",
  as.character(sample_n * 26L)
))

if (!is.finite(exact_max_work) || exact_max_work <= 0) {
  stop("--exact-max-work must be a positive number.", call. = FALSE)
}

# ---- Helpers ----

stable_seed <- function(site_id) {
  hash <- as.character(sha256(charToRaw(enc2utf8(site_id))))
  leading <- strtoi(substr(hash, 1, 7), base = 16L)
  trailing <- strtoi(substr(hash, 8, 8), base = 16L)
  value <- leading * 16 + trailing
  as.integer(value %% (2^31 - 2) + 1)
}

raw_file_sha256 <- function(path) {
  size <- file.info(path)$size
  connection <- file(path, open = "rb")
  on.exit(close(connection), add = TRUE)
  paste0(sha256(readBin(connection, what = "raw", n = size)))
}

safe_sample_file <- function(site_id) {
  if (!grepl("^[a-z0-9][a-z0-9_-]*$", site_id)) {
    stop("Unsafe site_id for a sample filename: ", site_id, call. = FALSE)
  }
  paste0(site_id, ".json")
}

# ---- Targets ----

watersheds <- st_read(
  require_input_file(watershed_path, "GLC watershed layer"),
  quiet = TRUE
)
assert_required_columns(
  watersheds,
  c(
    "site_id", "LTER", "Stream_Name", "Shapefile_Name",
    "polygon_area_km2"
  ),
  "GLC watershed layer"
)
if (anyDuplicated(watersheds$site_id)) {
  stop("GLC watershed site_id values must be distinct.", call. = FALSE)
}

watersheds <- watersheds |>
  mutate(polygon_area_km2 = as.numeric(polygon_area_km2))
if (any(!is.finite(watersheds$polygon_area_km2)) ||
    any(watersheds$polygon_area_km2 <= 0)) {
  stop("Every watershed needs a positive polygon_area_km2.", call. = FALSE)
}

if (length(site_ids)) {
  missing_ids <- setdiff(site_ids, watersheds$site_id)
  if (length(missing_ids)) {
    stop(
      "Unknown --site-id values: ", paste(missing_ids, collapse = ", "),
      call. = FALSE
    )
  }
  watersheds <- watersheds |> filter(site_id %in% site_ids)
}

exact_area_limit_km2 <- exact_max_work / 26 * 30^2 / 1e6
targets <- watersheds |>
  filter(polygon_area_km2 > exact_area_limit_km2) |>
  arrange(site_id)
if (!nrow(targets)) {
  stop("No selected watershed requires fixed-point sampling.", call. = FALSE)
}
if (!is.null(expected_sampled_sites) && nrow(targets) != expected_sampled_sites) {
  stop(
    "Selected ", nrow(targets), " sampled watersheds; expected ",
    expected_sampled_sites, ".",
    call. = FALSE
  )
}

# ---- Point files ----

sample_root <- file.path(output_root, "samples")
prepare_output_dir(sample_root)
records <- vector("list", nrow(targets))

for (index in seq_len(nrow(targets))) {
  site <- targets[index, ]
  site_equal_area <- st_transform(site, 6933)
  if (any(!is.finite(st_bbox(site_equal_area)))) {
    stop("Equal-area transformation failed for ", site$site_id, call. = FALSE)
  }

  seed <- stable_seed(site$site_id)
  RNGkind(
    kind = "Mersenne-Twister",
    normal.kind = "Inversion",
    sample.kind = "Rejection"
  )
  set.seed(seed)
  points_equal_area <- st_sample(
    st_geometry(site_equal_area),
    size = sample_n,
    type = "random",
    exact = TRUE
  )
  if (length(points_equal_area) != sample_n) {
    stop(
      "Generated ", length(points_equal_area), "/", sample_n,
      " points for ", site$site_id, ".",
      call. = FALSE
    )
  }
  covered <- lengths(st_covered_by(points_equal_area, st_geometry(site_equal_area))) > 0
  if (!all(covered)) {
    stop("At least one sampled point falls outside ", site$site_id, call. = FALSE)
  }

  points_wgs84 <- st_transform(points_equal_area, 4326)
  coordinates <- unname(st_coordinates(points_wgs84)[, c("X", "Y"), drop = FALSE])
  if (any(!is.finite(coordinates)) ||
      any(coordinates[, 1] < -180 | coordinates[, 1] > 180) ||
      any(coordinates[, 2] < -90 | coordinates[, 2] > 90)) {
    stop("Invalid longitude or latitude for ", site$site_id, call. = FALSE)
  }
  if (anyDuplicated(data.frame(coordinates))) {
    stop("Duplicate sampled coordinates for ", site$site_id, call. = FALSE)
  }

  geometry_raw <- st_as_binary(st_geometry(site), EWKB = TRUE)[[1]]
  source_geometry_sha256 <- paste0(sha256(geometry_raw))
  bounds <- c(
    min(coordinates[, 1]), min(coordinates[, 2]),
    max(coordinates[, 1]), max(coordinates[, 2])
  )
  relative_path <- file.path("samples", safe_sample_file(site$site_id))
  output_path <- file.path(output_root, relative_path)
  payload <- list(
    schema_version = 1L,
    generator = "local_equal_area_points_v1",
    site_id = site$site_id,
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Shapefile_Name = site$Shapefile_Name,
    source_file = if ("source_file" %in% names(site)) site$source_file else NULL,
    Spatial_Data_Version = if ("Spatial_Data_Version" %in% names(site)) {
      site$Spatial_Data_Version
    } else {
      NULL
    },
    sampling_crs = "EPSG:6933",
    sampling_seed = seed,
    requested_sample_n = sample_n,
    polygon_area_km2 = site$polygon_area_km2,
    source_geometry_sha256 = source_geometry_sha256,
    bounds = unname(bounds),
    coordinates = coordinates
  )
  write_json(
    payload,
    output_path,
    auto_unbox = TRUE,
    digits = 10,
    pretty = FALSE,
    null = "null"
  )
  records[[index]] <- tibble(
    site_id = site$site_id,
    path = relative_path,
    sample_n = sample_n,
    sampling_seed = seed,
    sampling_crs = "EPSG:6933",
    polygon_area_km2 = site$polygon_area_km2,
    source_geometry_sha256 = source_geometry_sha256,
    file_sha256 = raw_file_sha256(output_path),
    bytes = file.info(output_path)$size
  )
  message(
    "Sampled ", site$site_id, ": ", sample_n,
    " points, ", round(file.info(output_path)$size / 1024^2, 3), " MB"
  )
}

manifest <- bind_rows(records)
manifest_path <- file.path(output_root, "point_sample_manifest.csv")
write_csv(manifest, manifest_path)

cat("Sampled watersheds:", nrow(manifest), "\n")
cat("Points per watershed:", sample_n, "\n")
cat("Exact-area limit km2:", signif(exact_area_limit_km2, 8), "\n")
cat("Manifest:", manifest_path, "\n")
