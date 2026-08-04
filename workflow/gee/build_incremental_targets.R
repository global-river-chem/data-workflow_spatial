# Build current GEE target layers without rerunning accepted prior coverage.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
watershed_path <- cli_value(args, "--watersheds", required = TRUE)
current_table_path <- cli_value(args, "--current-site-table", required = TRUE)
previous_table_path <- cli_value(args, "--previous-site-table", required = TRUE)
baseline_path <- cli_value(args, "--baseline-watersheds", required = TRUE)
land_cover_path <- cli_value(args, "--land-cover-checkpoint", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
expected_site_count <- cli_integer(args, "--expected-site-count")
expected_gee_targets <- cli_integer(args, "--expected-gee-targets")
expected_glc_targets <- cli_integer(args, "--expected-glc-targets")

watersheds <- st_read(
  require_input_file(watershed_path, "current watershed layer"),
  quiet = TRUE
)
assert_required_columns(watersheds, "site_id", "current watershed layer")
if (anyDuplicated(watersheds$site_id)) {
  stop("Current watershed site_id values must be distinct.", call. = FALSE)
}
if (!is.null(expected_site_count) && nrow(watersheds) != expected_site_count) {
  stop(
    "Current watershed layer has ", nrow(watersheds),
    " rows; expected ", expected_site_count, ".",
    call. = FALSE
  )
}

current <- read_workflow_table(
  require_input_file(current_table_path, "current site-reference table")
)
previous <- read_workflow_table(
  require_input_file(previous_table_path, "previous site-reference table")
)
names(previous) <- make.unique(names(previous))
baseline <- st_read(
  require_input_file(baseline_path, "baseline watershed layer"),
  quiet = TRUE
)
land_cover <- read_workflow_table(
  require_input_file(land_cover_path, "land-cover checkpoint")
)

assert_required_columns(
  current,
  c(
    "LTER", "Stream_Name", "Spatial_Data_Version", "Has_Spatial_Data",
    "Shapefile_Name"
  ),
  "current site-reference table"
)
assert_required_columns(
  previous,
  c("LTER", "Stream_Name", "Data_Release", "Shapefile_Name"),
  "previous site-reference table"
)
assert_required_columns(baseline, "site_id", "baseline watershed layer")
assert_required_columns(land_cover, "Stream_Name", "land-cover checkpoint")

current_aliases <- current |>
  filter(
    trimws(Has_Spatial_Data) == "Yes",
    !is.na(Shapefile_Name),
    nzchar(trimws(Shapefile_Name))
  ) |>
  mutate(
    Spatial_Data_Version = suppressWarnings(as.integer(Spatial_Data_Version)),
    site_id = paste(normalize_key(LTER), normalize_key(Shapefile_Name), sep = "__")
  )
if (!setequal(current_aliases$site_id, watersheds$site_id)) {
  stop(
    "Current site-reference geometry IDs do not match the watershed layer.",
    call. = FALSE
  )
}

previous_aliases <- previous |>
  transmute(
    LTER,
    Stream_Name,
    previous_shapefile_name = Shapefile_Name,
    previous_spatial_version = suppressWarnings(as.integer(Data_Release))
  ) |>
  distinct()

land_cover_streams <- unique(as.character(land_cover$Stream_Name))
baseline_ids <- unique(as.character(baseline$site_id))
alias_audit <- current_aliases |>
  left_join(previous_aliases, by = c("LTER", "Stream_Name")) |>
  mutate(
    same_previous_geometry = coalesce(
      Shapefile_Name == previous_shapefile_name &
        Spatial_Data_Version == previous_spatial_version,
      FALSE
    ),
    in_baseline_gee_asset = site_id %in% baseline_ids,
    in_land_cover_checkpoint = Stream_Name %in% land_cover_streams,
    reusable_gee_alias = in_baseline_gee_asset & same_previous_geometry,
    reusable_glc_alias = in_land_cover_checkpoint & same_previous_geometry
  )

geometry_audit <- alias_audit |>
  group_by(site_id) |>
  summarise(
    LTER = first(LTER),
    Shapefile_Name = first(Shapefile_Name),
    Spatial_Data_Version = first(Spatial_Data_Version),
    alias_rows = n_distinct(paste(LTER, Stream_Name, sep = "::")),
    reusable_gee = any(reusable_gee_alias),
    reusable_glc = any(reusable_glc_alias),
    gee_target = !reusable_gee,
    glc_target = !reusable_glc,
    .groups = "drop"
  ) |>
  arrange(site_id)

gee_target_count <- sum(geometry_audit$gee_target)
glc_target_count <- sum(geometry_audit$glc_target)
if (!is.null(expected_gee_targets) && gee_target_count != expected_gee_targets) {
  stop(
    "Computed ", gee_target_count, " ERA5/human-impact targets; expected ",
    expected_gee_targets, ".",
    call. = FALSE
  )
}
if (!is.null(expected_glc_targets) && glc_target_count != expected_glc_targets) {
  stop(
    "Computed ", glc_target_count, " GLC targets; expected ",
    expected_glc_targets, ".",
    call. = FALSE
  )
}

target_flags <- geometry_audit |>
  select(site_id, gee_target, glc_target)
watersheds <- watersheds |>
  left_join(target_flags, by = "site_id")
if (any(is.na(watersheds$gee_target)) || any(is.na(watersheds$glc_target))) {
  stop("At least one watershed lacks an incremental target decision.", call. = FALSE)
}

prepare_output_dir(output_root)
output_root <- normalizePath(output_root)
gee_path <- file.path(output_root, "era5_human_incremental_targets.gpkg")
glc_path <- file.path(output_root, "glc_incremental_targets.gpkg")
geometry_audit_path <- file.path(output_root, "incremental_geometry_audit.csv")
alias_audit_path <- file.path(output_root, "incremental_alias_audit.csv")

st_write(
  watersheds |> filter(gee_target) |> select(-gee_target, -glc_target),
  gee_path,
  delete_dsn = TRUE,
  quiet = TRUE
)
st_write(
  watersheds |> filter(glc_target) |> select(-gee_target, -glc_target),
  glc_path,
  delete_dsn = TRUE,
  quiet = TRUE
)
write_csv(geometry_audit, geometry_audit_path)
write_csv(st_drop_geometry(alias_audit), alias_audit_path)

cat("Current watersheds:", nrow(watersheds), "\n")
cat("Reusable ERA5/human-impact watersheds:", sum(geometry_audit$reusable_gee), "\n")
cat("ERA5/human-impact targets:", gee_target_count, "\n")
cat("Reusable GLC watersheds:", sum(geometry_audit$reusable_glc), "\n")
cat("GLC targets:", glc_target_count, "\n")
cat("Audit:", geometry_audit_path, "\n")
