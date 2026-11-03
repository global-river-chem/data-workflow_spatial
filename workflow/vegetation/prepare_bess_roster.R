# ---- current analysis sites and reviewed watershed inputs ----

script <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]))
repo_root <- normalizePath(file.path(dirname(script), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
source(file.path(dirname(script), "vegetation_helpers.R"))
args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% args) {
  cat("Use --metadata FILE --watersheds FILE --shapefile-root DIR --boundary-updates FILE --output-dir DIR\nOptional: --expected-sites N --expected-spatial N\n")
  quit(status = 0)
}
metadata_path <- require_input_file(cli_value(args, "--metadata", required = TRUE))
watershed_path <- require_input_file(cli_value(args, "--watersheds", required = TRUE))
root <- normalizePath(cli_value(args, "--shapefile-root", required = TRUE), mustWork = TRUE)
boundary_path <- require_input_file(cli_value(args, "--boundary-updates", required = TRUE))
output <- vegetation_output(cli_value(args, "--output-dir", required = TRUE), repo_root)
if (any(file.exists(file.path(output, c("watersheds.gpkg", "site-roster.rds"))))) stop("Prepared outputs already exist")
metadata <- read_workflow_table(metadata_path)
if ("Record_Type" %in% names(metadata)) metadata <- metadata[metadata$Record_Type == "site", ]
assert_required_columns(metadata, c("LTER", "Stream_Name", "Has_Spatial_Data", "Watershed_File_Name"), "analysis metadata")
roster <- metadata
roster$Shapefile_Name <- roster$Watershed_File_Name
roster$site <- NA_character_
key <- function(lter, shape) paste(lter, shape, sep = "\r")
if (anyDuplicated(key(roster$LTER, roster$Stream_Name)) ||
    any(!roster$Has_Spatial_Data %in% c("Yes", "No"))) stop("Invalid analysis site roster")
eligible <- roster$Has_Spatial_Data == "Yes"
if (anyNA(roster$Shapefile_Name[eligible]) || any(!nzchar(roster$Shapefile_Name[eligible]))) stop("Spatial sites need a reviewed watershed name")
expected_sites <- cli_integer(args, "--expected-sites")
expected_spatial <- cli_integer(args, "--expected-spatial")
if (!is.null(expected_sites) && nrow(roster) != expected_sites) stop("Unexpected analysis site count")
if (!is.null(expected_spatial) && sum(eligible) != expected_spatial) stop("Unexpected spatial site count")

# ---- match named geometries and apply the reviewed boundary update ----

saved <- sf::st_read(watershed_path, quiet = TRUE)
assert_required_columns(saved, c("LTER", "Shapefile_Name"), "saved watersheds")
saved_keys <- key(saved$LTER, saved$Shapefile_Name)
if (anyDuplicated(saved_keys)) stop("Saved watershed names are ambiguous")
reviewed <- read_verified_boundary_updates(boundary_path, required = TRUE, download = FALSE)$boundaries
used <- c(metadata_path, watershed_path, boundary_path)
keys <- sort(unique(key(roster$LTER[eligible], roster$Shapefile_Name[eligible])))
features <- list()
for (i in seq_along(keys)) {
  rows <- which(eligible & key(roster$LTER, roster$Shapefile_Name) == keys[i])
  row <- roster[rows[1], , drop = FALSE]
  site <- sprintf("watershed_%05d", i)
  roster$site[rows] <- site
  if (needs_verified_boundary(row)) {
    shape <- reviewed[reviewed$Shapefile_Name == row$Shapefile_Name, ]
    if (nrow(shape) != 1L) stop("The reviewed Ferguson boundary does not match")
  } else if (keys[i] %in% saved_keys) {
    shape <- saved[match(keys[i], saved_keys), ]
  } else {
    paths <- file.path(root, paste0("data_release_", 1:3), row$Shapefile_Name, paste0(row$Shapefile_Name, ".shp"))
    paths <- paths[file.exists(paths)]
    if (length(paths) != 1L) stop("Missing or ambiguous reviewed watershed: ", keys[i])
    shape <- sf::st_read(paths[1], quiet = TRUE)
    components <- list.files(dirname(paths[1]), full.names = TRUE)
    used <- c(used, components[startsWith(basename(components), paste0(row$Shapefile_Name, "."))])
  }
  if (is.na(sf::st_crs(shape))) stop("Watershed has no coordinate reference: ", keys[i])
  shape <- sf::st_transform(shape, 4326)
  if (!all(sf::st_is_valid(shape))) shape <- sf::st_make_valid(shape)
  geometry <- if (nrow(shape) == 1L) sf::st_geometry(shape) else sf::st_union(sf::st_geometry(shape))
  feature <- sf::st_sf(site = site, geometry = geometry)
  if (any(sf::st_is_empty(feature)) || any(!sf::st_geometry_type(feature) %in% c("POLYGON", "MULTIPOLYGON"))) {
    stop("The reviewed watershed is not a usable polygon: ", keys[i])
  }
  features[[i]] <- feature
}
watersheds <- do.call(rbind, features)
stopifnot(all(!is.na(roster$site[eligible])), nrow(watersheds) == length(keys))
attr(roster, "source_files") <- tools::md5sum(unique(used))
attr(roster, "preparation_code") <- tools::md5sum(c(script, file.path(dirname(script), "vegetation_helpers.R")))
sf::st_write(watersheds, file.path(output, "watersheds.gpkg"), quiet = TRUE)
save_vegetation_rds(roster, file.path(output, "site-roster.rds"))
cat("Prepared", nrow(watersheds), "watersheds for", sum(eligible), "spatial sites;", sum(!eligible), "sites retained without spatial data\n")
