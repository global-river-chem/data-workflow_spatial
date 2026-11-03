# ---- command inputs and saved results ----

vegetation_years <- function(value, first, last) {
  if (grepl(":", value, fixed = TRUE)) {
    bounds <- suppressWarnings(as.integer(strsplit(value, ":", fixed = TRUE)[[1]]))
    if (length(bounds) != 2L || anyNA(bounds) || bounds[1] > bounds[2]) stop("Invalid year range")
    years <- seq.int(bounds[1], bounds[2])
  } else {
    years <- suppressWarnings(as.integer(strsplit(value, ",", fixed = TRUE)[[1]]))
  }
  if (!length(years) || anyNA(years) || any(years < first | years > last)) {
    stop("Provide comma-separated years between ", first, " and ", last)
  }
  sort(unique(years))
}

vegetation_output <- function(path, repo_root) {
  dir.create(path, recursive = TRUE, showWarnings = FALSE)
  path <- normalizePath(path, mustWork = TRUE)
  if (path == repo_root || startsWith(path, paste0(repo_root, "/"))) {
    stop("Keep downloaded data and saved results outside the repository")
  }
  invisible(path)
}

save_vegetation_rds <- function(data, path) {
  temporary <- paste0(path, ".partial")
  saveRDS(data, temporary)
  if (!file.rename(temporary, path)) stop("Could not save ", path)
}

# refuse to reuse results when the inputs, selected years, or code have changed
vegetation_run_record <- function(output, inputs, options, code) {
  paths <- normalizePath(c(inputs, code), mustWork = TRUE)
  record <- list(options = options, files = tools::md5sum(paths))
  path <- file.path(output, "run-inputs.rds")
  if (file.exists(path)) {
    if (!identical(readRDS(path), record)) {
      stop("Saved run inputs differ; use a new output directory")
    }
  } else {
    if (any(file.exists(file.path(output, c("observations.rds", "daily-values.rds", "monthly-checkpoint.rds"))))) {
      stop("This output has an older checkpoint; use a new output directory")
    }
    save_vegetation_rds(record, path)
  }
  record
}

# read every native cell that overlaps a watershed, including outside centers
read_vegetation_points <- function(path, step) {
  if (tolower(tools::file_ext(path)) == "rds") {
    points <- readRDS(path)
    if (!is.data.frame(points) || !identical(attr(points, "crs"), "EPSG:4326") ||
        !isTRUE(all.equal(attr(points, "native_cell_size"), step))) {
      stop("Saved native sample tables need matching grid and coordinate metadata")
    }
    assert_required_columns(points, c("longitude", "latitude"), "sample points")
    coordinates <- as.matrix(points[, c("longitude", "latitude")])
  } else {
    shape <- sf::st_read(path, quiet = TRUE)
    if (!all(sf::st_geometry_type(shape) == "POINT") || sf::st_crs(shape) != sf::st_crs(4326)) {
      stop("Sample points must use longitude and latitude in EPSG:4326")
    }
    points <- sf::st_drop_geometry(shape)
    coordinates <- sf::st_coordinates(shape)
  }
  if (!"site" %in% names(points) && "pilot_site" %in% names(points)) points$site <- points$pilot_site
  if (!"pixel" %in% names(points) && "pixel_id" %in% names(points)) points$pixel <- points$pixel_id
  if (!"pixel" %in% names(points) && "vip_pixel" %in% names(points)) points$pixel <- points$vip_pixel
  if (!"weight" %in% names(points) && "overlap_m2" %in% names(points)) points$weight <- points$overlap_m2
  if (!"watershed_area_m2" %in% names(points) && "watershed_area_km2" %in% names(points)) {
    points$watershed_area_m2 <- points$watershed_area_km2 * 1e6
  }
  assert_required_columns(points, c("site", "pixel", "weight", "watershed_area_m2"), "sample points")
  if (!nrow(points) || anyNA(points[c("site", "pixel", "weight", "watershed_area_m2")]) ||
    any(!nzchar(trimws(points$site))) || anyDuplicated(paste(points$site, points$pixel)) ||
    any(!is.finite(points$weight) | points$weight <= 0) ||
    any(!is.finite(points$watershed_area_m2) | points$watershed_area_m2 <= 0)) {
    stop("Sample points need unique site-cell pairs and positive watershed areas")
  }
  points$longitude <- coordinates[, 1]
  points$latitude <- coordinates[, 2]
  aligned_x <- (points$longitude + 180) / step - 0.5
  aligned_y <- (90 - points$latitude) / step - 0.5
  if (any(abs(aligned_x - round(aligned_x)) > 1e-5) ||
    any(abs(aligned_y - round(aligned_y)) > 1e-5)) {
    stop("Points do not match this product's native cell centers")
  }
  for (site in unique(points$site)) {
    rows <- points$site == site
    area <- unique(points$watershed_area_m2[rows])
    if (length(area) != 1L || abs(sum(points$weight[rows]) / area - 1) > 0.0001) {
      stop("Cell overlap areas do not cover the full watershed: ", site)
    }
  }
  points
}
