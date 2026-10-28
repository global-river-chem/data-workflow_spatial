# build the earth engine watershed collection from the accepted site table
# resolve moved shapes across the supplied versioned watershed libraries

suppressPackageStartupMessages({
  library(dplyr)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
site_table_path <- cli_value(args, "--site-table", required = TRUE)
shapefile_root <- cli_value(args, "--shapefile-root", required = TRUE)
additional_roots_text <- cli_value(
  args,
  "--additional-shapefile-roots",
  ""
)
output_root <- cli_value(args, "--output-root", required = TRUE)
output_name <- cli_value(args, "--output-name", "watersheds")
expected_count <- suppressWarnings(as.integer(cli_value(args, "--expected-count", "")))
overwrite <- cli_boolean(args, "--overwrite", FALSE)
boundary_updates_path <- cli_value(args, "--boundary-updates", "")
download_boundary <- cli_boolean(args, "--download-boundary", TRUE)
shared_area_tolerance_pct <- as.numeric(
  cli_value(args, "--shared-area-tolerance-pct", "2")
)

additional_roots <- trimws(strsplit(
  additional_roots_text,
  ",",
  fixed = TRUE
)[[1]])
additional_roots <- additional_roots[nzchar(additional_roots)]
shapefile_roots <- unique(c(shapefile_root, additional_roots))
missing_roots <- shapefile_roots[!dir.exists(shapefile_roots)]
if (length(missing_roots)) {
  stop(
    "Missing versioned watershed library: ",
    paste(missing_roots, collapse = ", "),
    call. = FALSE
  )
}
shapefile_roots <- vapply(
  shapefile_roots,
  normalizePath,
  character(1),
  mustWork = TRUE
)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
output_root <- normalizePath(output_root)

site_table <- read_workflow_table(site_table_path)
required <- c(
  "LTER", "Stream_Name", "Spatial_Data_Version", "Has_Spatial_Data",
  "Shapefile_Name", "Shapefile_CRS_EPSG", "Shapefile_Source",
  "drainSqKm", "drainSqKm_source"
)
require_columns(site_table, required, "site table")
if (!"Discharge_File_Name" %in% names(site_table)) {
  site_table$Discharge_File_Name <- ""
}

rows <- site_table %>%
  mutate(
    Spatial_Data_Version = suppressWarnings(as.integer(Spatial_Data_Version)),
    drainSqKm = suppressWarnings(as.numeric(drainSqKm)),
    geometry_key = paste(LTER, Shapefile_Name, sep = "::")
  ) %>%
  filter(
    trimws(Has_Spatial_Data) == "Yes",
    nzchar(trimws(Shapefile_Name)),
    Spatial_Data_Version %in% 1:3
  )
if (!nrow(rows)) stop("The site table contains no spatial rows.", call. = FALSE)

# never substitute the old watershed when the corrected file is unavailable
verified <- read_verified_boundary_updates(boundary_updates_path,
  required = any(needs_verified_boundary(rows)), download = download_boundary)
boundary_updates <- if (is.null(verified)) NULL else verified$boundaries
if (!is.null(verified)) boundary_updates_path <- verified$path
if (any(needs_verified_boundary(rows))) {
  if (any(!rows$Shapefile_Name[needs_verified_boundary(rows)] %in% boundary_updates$Shapefile_Name)) {
    stop("Ferguson's shape name does not match the corrected boundary", call. = FALSE)
  }
}

if ("gee_watershed_id" %in% names(rows)) {
  rows$geometry_site_id <- trimws(as.character(rows$gee_watershed_id))
  if (any(!nzchar(rows$geometry_site_id))) {
    stop("The site table contains a blank gee_watershed_id.", call. = FALSE)
  }
} else {
  rows$geometry_site_id <- paste(
    normalize_key(rows$LTER),
    normalize_key(rows$Shapefile_Name),
    sep = "__"
  )
}

geometry_id_conflicts <- rows %>%
  distinct(geometry_key, geometry_site_id) %>%
  count(geometry_key) %>%
  filter(n > 1L)
if (nrow(geometry_id_conflicts)) {
  stop(
    "The same watershed shape has multiple gee_watershed_id values: ",
    paste(geometry_id_conflicts$geometry_key, collapse = ", "),
    call. = FALSE
  )
}

shape_id_conflicts <- rows %>%
  distinct(geometry_key, geometry_site_id) %>%
  count(geometry_site_id) %>%
  filter(n > 1L)
if (nrow(shape_id_conflicts)) {
  stop(
    "A gee_watershed_id points to multiple watershed shapes: ",
    paste(shape_id_conflicts$geometry_site_id, collapse = ", "),
    call. = FALSE
  )
}

version_conflicts <- rows %>%
  distinct(geometry_key, Spatial_Data_Version) %>%
  count(geometry_key) %>%
  filter(n > 1L)
if (nrow(version_conflicts)) {
  stop(
    "The same LTER/shapefile name appears in multiple spatial versions: ",
    paste(version_conflicts$geometry_key, collapse = ", "),
    call. = FALSE
  )
}

first_text <- function(value) {
  value <- trimws(as.character(value))
  value <- value[nzchar(value)]
  if (length(value)) value[[1]] else ""
}

source_id <- function(attributes) {
  candidates <- grep(
    "^(hydro_id|hydrosheds_id|hybas_id|outlet|outlet_id|out_aroid|source_id)$",
    names(attributes),
    ignore.case = TRUE,
    value = TRUE
  )
  if (!length(candidates)) return("")
  first_text(attributes[[candidates[[1]]]])
}

resolve_shape_path <- function(row) {
  exact_candidates <- file.path(
    shapefile_roots,
    paste0("data_release_", row$Spatial_Data_Version),
    row$Shapefile_Name,
    paste0(row$Shapefile_Name, ".shp")
  )
  matches <- exact_candidates[file.exists(exact_candidates)]
  if (length(matches)) {
    selected <- matches[[1]]
  } else {
    selected <- ""
    for (root in shapefile_roots) {
      root_matches <- Sys.glob(file.path(
        root,
        "data_release_*",
        row$Shapefile_Name,
        paste0(row$Shapefile_Name, ".shp")
      ))
      root_matches <- unique(root_matches)
      if (length(root_matches) > 1L) {
        stop(
          "Multiple versions of watershed file found for ", row$geometry_key,
          " in ", root, ".",
          call. = FALSE
        )
      }
      if (length(root_matches) == 1L) {
        selected <- root_matches[[1]]
        break
      }
    }
  }
  if (!nzchar(selected)) {
    stop(
      "Missing watershed file for ", row$geometry_key, ".",
      call. = FALSE
    )
  }
  selected <- normalizePath(selected, mustWork = TRUE)
  source_root <- shapefile_roots[
    startsWith(selected, paste0(shapefile_roots, .Platform$file.sep))
  ]
  source_root <- source_root[[which.max(nchar(source_root))]]
  list(
    path = selected,
    relative = substring(selected, nchar(source_root) + 2L)
  )
}

read_geometry <- function(group) {
  row <- group[1, , drop = FALSE]
  updated <- if (is.null(boundary_updates)) integer() else
    which(boundary_updates$Shapefile_Name == row$Shapefile_Name)
  if (length(updated)) {
    resolved_shape <- list(path = boundary_updates_path, relative = boundary_updates_path)
    watershed <- boundary_updates[updated, ]
    group$Shapefile_Source <- watershed$source_type[1L]
    row$Shapefile_Source <- watershed$source_type[1L]
  } else {
    resolved_shape <- resolve_shape_path(row)
    watershed <- st_read(resolved_shape$path, quiet = TRUE)
  }
  shape_path <- resolved_shape$path
  if (!nrow(watershed) || any(st_is_empty(watershed))) {
    stop("Empty watershed: ", shape_path, call. = FALSE)
  }
  if (is.na(st_crs(watershed))) {
    epsg <- suppressWarnings(as.integer(row$Shapefile_CRS_EPSG))
    if (!is.finite(epsg)) {
      stop("Watershed lacks a CRS and the table has no numeric EPSG: ", shape_path)
    }
    st_crs(watershed) <- epsg
  }
  attributes <- st_drop_geometry(watershed)
  geometry <- st_union(st_geometry(st_make_valid(st_transform(watershed, 4326))))
  feature <- st_sf(geometry = geometry, crs = 4326)
  polygon_area_km2 <- as.numeric(st_area(st_transform(feature, 6933))) / 1e6

  reported_areas <- sort(unique(group$drainSqKm[is.finite(group$drainSqKm)]))
  if (length(reported_areas) > 1L) {
    difference_pct <- 100 * diff(range(reported_areas)) / max(reported_areas)
    if (difference_pct > shared_area_tolerance_pct) {
      stop(
        "Rows sharing ", row$geometry_key,
        " have conflicting drainage areas (", round(difference_pct, 2), "%)."
      )
    }
  }
  expected_area_km2 <- if (length(reported_areas)) reported_areas[[1]] else NA_real_

  feature$site_id <- first_text(group$geometry_site_id)
  feature$run_group <- row$LTER
  feature$LTER <- row$LTER
  feature$Shapefile_Name <- row$Shapefile_Name
  feature$Stream_Name <- first_text(group$Stream_Name)
  feature$Discharge_File_Name <- first_text(group$Discharge_File_Name)
  feature$hydrosheds_used <- grepl(
    "hydrobasins|hydrosheds",
    first_text(group$Shapefile_Source),
    ignore.case = TRUE
  )
  feature$hydrosheds_id <- source_id(attributes)
  feature$expected_area_km2 <- expected_area_km2
  feature$drn_src <- first_text(group$drainSqKm_source)
  feature$polygon_area_km2 <- polygon_area_km2
  feature$tiny_ws <- polygon_area_km2 <= 10
  feature$source_type <- first_text(group$Shapefile_Source)
  feature$source_file <- resolved_shape$relative
  feature$Spatial_Data_Version <- row$Spatial_Data_Version
  feature
}

groups <- split(rows, rows$geometry_key)
watersheds <- do.call(rbind, lapply(groups, read_geometry))
watersheds <- watersheds[order(watersheds$site_id), ]
if (anyDuplicated(watersheds$site_id)) {
  stop("Generated site IDs are not unique.", call. = FALSE)
}
if (any(st_is_empty(watersheds)) || !all(st_is_valid(watersheds))) {
  stop("Generated watershed collection contains invalid geometry.", call. = FALSE)
}
if (is.finite(expected_count) && nrow(watersheds) != expected_count) {
  stop(
    "Generated ", nrow(watersheds), " watersheds; expected ", expected_count, ".",
    call. = FALSE
  )
}

alias_table <- rows %>%
  transmute(
    site_id = geometry_site_id,
    LTER,
    Stream_Name,
    Shapefile_Name,
    Spatial_Data_Version
  ) %>%
  distinct() %>%
  arrange(site_id, LTER, Stream_Name)

gpkg_path <- file.path(output_root, paste0(output_name, ".gpkg"))
shapefile_dir <- file.path(output_root, paste0(output_name, "_shapefile"))
shapefile_path <- file.path(shapefile_dir, paste0(output_name, ".shp"))
zip_path <- file.path(output_root, paste0(output_name, "_shapefile.zip"))
alias_path <- file.path(output_root, paste0(output_name, "_site_aliases.tsv"))
qa_path <- file.path(output_root, paste0(output_name, "_qa.rds"))

existing_outputs <- c(gpkg_path, zip_path, alias_path, qa_path)
if (!overwrite && (any(file.exists(existing_outputs)) || dir.exists(shapefile_dir))) {
  stop("Output already exists. Use --overwrite true to replace it.", call. = FALSE)
}
if (overwrite) {
  unlink(existing_outputs[file.exists(existing_outputs)])
  if (dir.exists(shapefile_dir)) unlink(shapefile_dir, recursive = TRUE)
}
dir.create(shapefile_dir, recursive = TRUE, showWarnings = FALSE)

st_write(watersheds, gpkg_path, quiet = TRUE)
shapefile_out <- watersheds %>%
  transmute(
    site_id,
    run_grp = run_group,
    LTER,
    Shpfl_N = Shapefile_Name,
    Strm_Nm = Stream_Name,
    Dsc_F_N = Discharge_File_Name,
    hydrshds_s = hydrosheds_used,
    hydrshds_d = hydrosheds_id,
    expc__2 = expected_area_km2,
    drn_src,
    plyg__2 = polygon_area_km2,
    tiny_ws,
    src_typ = source_type,
    sorc_fl = source_file
  )
st_write(shapefile_out, shapefile_path, quiet = TRUE)

old_working_directory <- getwd()
on.exit(setwd(old_working_directory), add = TRUE)
setwd(shapefile_dir)
utils::zip(
  zipfile = zip_path,
  files = list.files(shapefile_dir),
  flags = "-q"
)
setwd(old_working_directory)

write.table(
  alias_table,
  alias_path,
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
qa <- list(
  built_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  site_table = normalizePath(site_table_path),
  shapefile_roots = shapefile_roots,
  watershed_count = nrow(watersheds),
  site_row_count = nrow(alias_table),
  version_counts = as.data.frame(table(watersheds$Spatial_Data_Version)),
  outputs = c(gpkg = gpkg_path, shapefile_zip = zip_path, aliases = alias_path)
)
saveRDS(qa, qa_path)

cat("Built", nrow(watersheds), "watersheds for", nrow(alias_table), "site rows.\n")
cat("GeoPackage:", gpkg_path, "\n")
cat("Shapefile ZIP:", zip_path, "\n")
cat("Alias table:", alias_path, "\n")
