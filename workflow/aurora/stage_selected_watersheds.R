# ---- setup ----

script_path <- function() {
  argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(argument)) return(normalizePath(sub("^--file=", "", argument[[1]])))
  normalizePath("workflow/aurora/stage_selected_watersheds.R", mustWork = FALSE)
}

repo_root <- normalizePath(file.path(dirname(script_path()), "../.."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

suppressPackageStartupMessages(library(sf))

args <- commandArgs(trailingOnly = TRUE)
selection_path <- require_input_file(
  cli_value(args, "--selection", required = TRUE),
  "Aurora selection table"
)
watershed_paths <- vapply(
  cli_values(args, "--watersheds"),
  require_input_file,
  character(1),
  label = "watershed collection"
)
if (!length(watershed_paths)) {
  stop("Provide at least one --watersheds file", call. = FALSE)
}
output_root <- cli_value(args, "--output-root", required = TRUE)

# ---- inputs ----

selection <- read_workflow_table(selection_path)
require_columns(selection, c("Shapefile_Name", "Spatial_Data_Version"), "Aurora selection")
selection$Shapefile_Name <- trimws(as.character(selection$Shapefile_Name))
version_values <- suppressWarnings(as.numeric(as.character(selection$Spatial_Data_Version)))
if (any(is.na(selection$Shapefile_Name) | !nzchar(selection$Shapefile_Name))) {
  stop("Aurora selection contains blank shapefile names", call. = FALSE)
}
if (any(!is.finite(version_values) | version_values != floor(version_values) | !version_values %in% 1:3)) {
  stop("Aurora selection contains an invalid spatial-data version", call. = FALSE)
}
selection$Spatial_Data_Version <- as.integer(version_values)

version_by_shape <- split(
  selection$Spatial_Data_Version,
  selection$Shapefile_Name
)
conflicts <- names(version_by_shape)[vapply(version_by_shape, function(value) {
  length(unique(value)) != 1L
}, logical(1))]
if (length(conflicts)) {
  stop(
    "Shapefile names appear in multiple spatial-data versions: ",
    paste(conflicts, collapse = ", "),
    call. = FALSE
  )
}
selection <- selection[!duplicated(selection$Shapefile_Name), , drop = FALSE]

read_watersheds <- function(path) {
  data <- st_read(path, quiet = TRUE)
  require_columns(data, "Shapefile_Name", basename(path))
  data$Shapefile_Name <- trimws(as.character(data$Shapefile_Name))
  if (any(is.na(data$Shapefile_Name) | !nzchar(data$Shapefile_Name))) {
    stop("Watershed collection contains blank shapefile names: ", basename(path), call. = FALSE)
  }
  data[, "Shapefile_Name", drop = FALSE]
}

collections <- lapply(watershed_paths, read_watersheds)
watersheds <- do.call(rbind, collections)
watersheds <- watersheds[
  watersheds$Shapefile_Name %in% selection$Shapefile_Name, ,
  drop = FALSE
]

duplicate_shapes <- names(which(table(watersheds$Shapefile_Name) > 1L))
geometry_conflicts <- duplicate_shapes[vapply(duplicate_shapes, function(shape_name) {
  candidates <- watersheds[
    watersheds$Shapefile_Name == shape_name, ,
    drop = FALSE
  ]
  comparisons <- st_equals(
    candidates[1L, , drop = FALSE],
    candidates[-1L, , drop = FALSE],
    sparse = FALSE
  )
  !all(comparisons)
}, logical(1))]
if (length(geometry_conflicts)) {
  stop(
    "Conflicting watershed geometries were supplied for: ",
    paste(geometry_conflicts, collapse = ", "),
    call. = FALSE
  )
}
watersheds <- watersheds[!duplicated(watersheds$Shapefile_Name), , drop = FALSE]

missing_shapes <- setdiff(selection$Shapefile_Name, watersheds$Shapefile_Name)
if (length(missing_shapes)) {
  stop(
    "Selected watershed geometries are missing: ",
    paste(missing_shapes, collapse = ", "),
    call. = FALSE
  )
}
if (is.na(st_crs(watersheds))) {
  stop("Selected watershed geometries have no coordinate system", call. = FALSE)
}
if (any(st_is_empty(watersheds)) || any(!st_is_valid(watersheds))) {
  stop("Selected watershed geometries include an empty or invalid polygon", call. = FALSE)
}

# ---- output ----

if (file.exists(output_root) || dir.exists(output_root)) {
  stop("Aurora output folder already exists: ", output_root, call. = FALSE)
}
dir.create(dirname(output_root), recursive = TRUE, showWarnings = FALSE)
staging_root <- file.path(
  dirname(output_root),
  paste0(".", basename(output_root), "-staging-", Sys.getpid())
)
dir.create(staging_root, recursive = TRUE, showWarnings = FALSE)
on.exit(unlink(staging_root, recursive = TRUE, force = TRUE), add = TRUE)

for (index in seq_len(nrow(selection))) {
  shape_name <- selection$Shapefile_Name[[index]]
  version <- selection$Spatial_Data_Version[[index]]
  feature <- watersheds[watersheds$Shapefile_Name == shape_name, , drop = FALSE]
  destination_dir <- file.path(
    staging_root,
    paste0("data_release_", version),
    shape_name
  )
  dir.create(destination_dir, recursive = TRUE, showWarnings = FALSE)
  st_write(
    feature,
    file.path(destination_dir, paste0(shape_name, ".shp")),
    quiet = TRUE
  )
}

written <- list.files(
  staging_root,
  pattern = "[.]shp$",
  recursive = TRUE,
  full.names = TRUE
)
if (length(written) != nrow(selection)) {
  stop("Aurora watershed staging did not write every selected polygon", call. = FALSE)
}
if (!file.rename(staging_root, output_root)) {
  stop("Could not install the checked Aurora watershed library", call. = FALSE)
}

cat("Staged", nrow(selection), "checked Aurora watershed bundles\n")
cat("Output:", normalizePath(output_root), "\n")
