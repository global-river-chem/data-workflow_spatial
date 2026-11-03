# ---- explicit watershed inputs ----

script <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]))
repo_root <- normalizePath(file.path(dirname(script), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
source(file.path(dirname(script), "vegetation_helpers.R"))
args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% args) {
  cat("Use --watersheds FILE --id-column COLUMN --product bess --output FILE.geojson\n")
  quit(status = 0)
}
path <- require_input_file(cli_value(args, "--watersheds", required = TRUE))
id <- cli_value(args, "--id-column", required = TRUE)
product <- cli_value(args, "--product", required = TRUE)
output <- cli_value(args, "--output", required = TRUE)
status_path <- cli_value(args, "--status-file")
if (product != "bess") stop("Product must be bess")
step <- 0.05
table_output <- tolower(tools::file_ext(output)) == "rds"
if (file.exists(output)) stop("Output already exists: ", output)
vegetation_output(dirname(output), repo_root)
shapes <- sf::st_transform(sf::st_read(path, quiet = TRUE), 4326)
assert_required_columns(shapes, id, "watersheds")
if (!nrow(shapes) || anyNA(shapes[[id]]) || any(!nzchar(trimws(shapes[[id]]))) ||
  anyDuplicated(shapes[[id]]) || any(sf::st_is_empty(shapes)) ||
  any(!sf::st_is_valid(shapes)) ||
  any(!sf::st_geometry_type(shapes) %in% c("POLYGON", "MULTIPOLYGON"))) {
  stop("Use valid reviewed polygons with one nonblank, unique site ID per watershed")
}

# ---- native cell centers and exact watershed overlap weights ----

rows <- list()
input_hash <- unname(tools::md5sum(path))
for (i in seq_len(nrow(shapes))) {
  if (!is.null(status_path) && (i == 1L || i %% 50L == 0L)) {
    writeLines(paste("preparing native sample cells:", i, "of", nrow(shapes), "watersheds"), status_path)
  }
  shape <- shapes[i, ]
  bounds <- sf::st_bbox(shape)
  origin <- c(
    -180 + floor((bounds["xmin"] + 180) / step) * step,
    -90 + floor((bounds["ymin"] + 90) / step) * step
  )
  cells <- sf::st_make_grid(shape, cellsize = step, offset = origin)
  cells <- sf::st_sf(pixel = seq_along(cells), geometry = cells)
  overlap <- suppressWarnings(sf::st_intersection(
    sf::st_transform(cells, 6933),
    sf::st_geometry(sf::st_transform(shape, 6933))
  ))
  overlap$weight <- as.numeric(sf::st_area(overlap))
  overlap <- overlap[overlap$weight > 0, ]
  # native cells run west to east, then south to north
  grid_box <- sf::st_bbox(cells)
  columns <- round(as.numeric((grid_box["xmax"] - grid_box["xmin"]) / step))
  longitude <- as.numeric(grid_box["xmin"]) + ((overlap$pixel - 1L) %% columns + .5) * step
  latitude <- as.numeric(grid_box["ymin"]) + ((overlap$pixel - 1L) %/% columns + .5) * step
  for (j in unique(c(1L, nrow(overlap)))) {
    box <- sf::st_bbox(cells[overlap$pixel[j], ])
    stopifnot(abs(longitude[j] - mean(box[c("xmin", "xmax")])) < 1e-7,
      abs(latitude[j] - mean(box[c("ymin", "ymax")])) < 1e-7)
  }
  values <- sf::st_drop_geometry(shape)[rep(1L, nrow(overlap)), , drop = FALSE]
  values$site <- as.character(shape[[id]])
  values$pixel <- overlap$pixel
  values$weight <- overlap$weight
  values$watershed_area_m2 <- as.numeric(sf::st_area(sf::st_transform(shape, 6933)))
  values$watershed_input_md5 <- input_hash
  if (table_output) {
    values$longitude <- longitude
    values$latitude <- latitude
    rows[[i]] <- values
  } else {
    centers <- lapply(seq_along(longitude), function(j) sf::st_point(c(longitude[j], latitude[j])))
    rows[[i]] <- sf::st_sf(values, geometry = sf::st_sfc(centers, crs = 4326))
  }
  rm(cells, overlap)
}
points <- if (table_output) do.call(rbind, c(rows, list(make.row.names = FALSE))) else do.call(rbind, rows)
if (table_output) {
  attr(points, "crs") <- "EPSG:4326"
  attr(points, "native_cell_size") <- step
  save_vegetation_rds(points, output)
} else sf::st_write(points, output, quiet = TRUE)
invisible(read_vegetation_points(output, step))
if (!is.null(status_path)) writeLines(paste("prepared:", nrow(points), "native sample cells for", nrow(shapes), "watersheds"), status_path)
