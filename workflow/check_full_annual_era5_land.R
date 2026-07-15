suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(googledrive)
  library(readr)
  library(tidyr)
})

# Settings

years <- 2000:2025
run_label <- "all_sites_fine_scale"

drive_account <- "bushsi@oregonstate.edu"
drive_folder_id <- "1qCeiFfg3Y6d5fBKaUxJM5z_N-6vcdi5A"

box_root <- "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions"
export_folder <- file.path(
  box_root,
  "spatial-data-files",
  "gee",
  "earth-engine-outputs",
  "era5_land_annual_2000_2025"
)
source_spatial_file <- file.path(
  box_root,
  "spatial-data-files",
  "appeears-nasa",
  "all-data_si-extract_3_20260629.csv"
)
qa_folder <- file.path(
  box_root,
  "qaqc",
  "gee",
  "full_annual_era5_land_2000_2025"
)

download_missing_files <- TRUE

clean_lter_name <- function(x) {
  recode(
    trimws(x),
    "Swedish Goverment" = "Sweden",
    "Swedish Government" = "Sweden",
    .default = trimws(x)
  )
}

site_match_key <- function(lter, shapefile_name, discharge_file_name) {
  clean_text <- function(x) {
    x <- toupper(trimws(as.character(x)))
    x[is.na(x) | x == ""] <- "<MISSING>"
    gsub("[^A-Z0-9<>]+", "", x)
  }
  paste(
    clean_text(lter),
    clean_text(shapefile_name),
    clean_text(discharge_file_name),
    sep = "__"
  )
}

# Expected files and variables

expected_files <- paste0(
  "era5_land_",
  years,
  "_",
  run_label,
  "_watershed_extract.csv"
)

variables <- tibble(
  variable = c(
    "precip_mm",
    "temp_degC",
    "evapotrans_mm",
    "potential_evap_mm",
    "snow_cover_fraction",
    "snow_water_equiv_mm"
  ),
  label = c(
    "Precipitation",
    "Air temperature",
    "Actual evapotranspiration",
    "Potential evapotranspiration",
    "Snow cover",
    "Snow-water equivalent"
  ),
  units = c("mm yr-1", "deg C", "mm yr-1", "mm yr-1", "fraction", "mm")
)

dir.create(export_folder, recursive = TRUE, showWarnings = FALSE)
dir.create(qa_folder, recursive = TRUE, showWarnings = FALSE)

# Download exports that are not already in Box

if (download_missing_files) {
  drive_auth(email = drive_account)
  drive_files <- drive_ls(as_id(drive_folder_id))

  missing_from_drive <- setdiff(expected_files, drive_files$name)
  if (length(missing_from_drive)) {
    stop(
      "The shared Google Drive folder is missing: ",
      paste(missing_from_drive, collapse = ", "),
      call. = FALSE
    )
  }

  for (file_name in expected_files) {
    local_path <- file.path(export_folder, file_name)
    if (!file.exists(local_path)) {
      drive_download(
        drive_files[drive_files$name == file_name, ],
        path = local_path,
        overwrite = FALSE
      )
    }
  }
}

# Read and combine the annual files

export_paths <- file.path(export_folder, expected_files)
missing_local_files <- export_paths[!file.exists(export_paths)]

if (length(missing_local_files)) {
  stop(
    "The local export folder is missing: ",
    paste(basename(missing_local_files), collapse = ", "),
    call. = FALSE
  )
}

annual_data <- export_paths |>
  lapply(function(path) {
    read_csv(path, show_col_types = FALSE) |>
      mutate(source_file = basename(path))
  }) |>
  bind_rows()

required_columns <- c(
  "site_id",
  "lter",
  "stream_name",
  "year",
  "used_fine_scale_fallback",
  variables$variable
)

missing_columns <- setdiff(required_columns, names(annual_data))
if (length(missing_columns)) {
  stop(
    "The ERA5-Land files are missing required columns: ",
    paste(missing_columns, collapse = ", "),
    call. = FALSE
  )
}

annual_data <- annual_data |>
  mutate(
    lter = clean_lter_name(lter),
    site_id = sub("^swedish_goverment__", "sweden__", site_id),
    source_site_key = site_match_key(lter, shapefile_name, Q_file_name),
    site_key = paste(lter, stream_name, sep = "__"),
    used_fine_scale_fallback = tolower(as.character(used_fine_scale_fallback)) %in% c("true", "1")
  ) |>
  arrange(year, lter, stream_name)

site_count <- n_distinct(annual_data$site_key)
expected_row_count <- site_count * length(years)

# Compare the GEE asset with the spatial table used to build it

source_sites <- read_csv(source_spatial_file, show_col_types = FALSE) |>
  mutate(
    LTER = clean_lter_name(LTER),
    source_site_key = site_match_key(LTER, Shapefile_Name, Discharge_File_Name)
  ) |>
  distinct(source_site_key, .keep_all = TRUE)

production_sites <- annual_data |>
  filter(year == min(year)) |>
  distinct(source_site_key)

missing_source_sites <- source_sites |>
  anti_join(production_sites, by = "source_site_key") |>
  select(
    LTER,
    Shapefile_Name,
    Stream_Name,
    Discharge_File_Name,
    hydrosheds_used,
    drainage_area,
    drainage_area_source
  ) |>
  arrange(desc(hydrosheds_used), LTER, Shapefile_Name)

source_hydrosheds_sites <- source_sites |>
  filter(hydrosheds_used %in% TRUE)

missing_hydrosheds_sites <- missing_source_sites |>
  filter(hydrosheds_used %in% TRUE)

# Check file and site-year completeness

rows_by_year <- annual_data |>
  count(year, name = "rows")

duplicate_site_years <- annual_data |>
  count(site_key, year, name = "rows") |>
  filter(rows > 1)

site_year_coverage <- annual_data |>
  count(site_key, lter, stream_name, name = "years_present") |>
  mutate(years_missing = length(years) - years_present)

# Check whether site metadata changes among years

metadata_columns <- intersect(
  c(
    "site_id",
    "lter",
    "stream_name",
    "shapefile_name",
    "Q_file_name",
    "hydrosheds_used",
    "hydrosheds_id",
    "expected_area_km2",
    "drainage_area_source",
    "polygon_area_km2",
    "tiny_watershed",
    "source_type"
  ),
  names(annual_data)
)

metadata_review <- annual_data |>
  group_by(site_key) |>
  summarise(
    across(
      all_of(metadata_columns),
      ~ n_distinct(.x, na.rm = FALSE),
      .names = "{.col}"
    ),
    .groups = "drop"
  ) |>
  pivot_longer(
    cols = all_of(metadata_columns),
    names_to = "metadata_column",
    values_to = "number_of_values"
  ) |>
  filter(number_of_values > 1)

# Summarize variables and identify values that need review

long_data <- annual_data |>
  pivot_longer(
    cols = all_of(variables$variable),
    names_to = "variable",
    values_to = "value"
  ) |>
  left_join(variables, by = "variable")

variable_summary <- long_data |>
  group_by(variable, label, units) |>
  summarise(
    rows = n(),
    missing = sum(is.na(value)),
    minimum = min(value, na.rm = TRUE),
    percentile_01 = quantile(value, 0.01, na.rm = TRUE),
    median = median(value, na.rm = TRUE),
    percentile_99 = quantile(value, 0.99, na.rm = TRUE),
    maximum = max(value, na.rm = TRUE),
    .groups = "drop"
  )

range_errors <- long_data |>
  mutate(
    review_reason = case_when(
      variable == "precip_mm" & value < -0.01 ~ "Negative precipitation",
      variable == "snow_cover_fraction" & (value < -0.000001 | value > 1.000001) ~ "Snow cover outside 0 to 1",
      variable == "snow_water_equiv_mm" & value < -0.001 ~ "Negative snow-water equivalent",
      variable == "temp_degC" & (value < -90 | value > 60) ~ "Temperature outside review range",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(review_reason)) |>
  select(
    review_reason,
    lter,
    stream_name,
    site_id,
    year,
    variable,
    label,
    units,
    value,
    source_file
  )

product_review_flags <- long_data |>
  mutate(
    review_reason = case_when(
      variable == "evapotrans_mm" & value < -0.01 ~ "Annual net condensation after evaporation sign conversion",
      variable == "potential_evap_mm" & value < -0.01 ~ "Annual net condensation after potential evaporation sign conversion",
      variable == "snow_water_equiv_mm" & value >= 9999 ~ "Snow-water equivalent at 10000 mm",
      TRUE ~ NA_character_
    )
  ) |>
  filter(!is.na(review_reason)) |>
  select(
    review_reason,
    lter,
    stream_name,
    site_id,
    year,
    variable,
    label,
    units,
    value,
    source_file
  )

extreme_values <- long_data |>
  filter(!is.na(value)) |>
  group_by(variable) |>
  arrange(value, .by_group = TRUE) |>
  slice(c(1:3, (n() - 2):n())) |>
  ungroup() |>
  mutate(review_reason = "Lowest or highest three values") |>
  select(
    review_reason,
    lter,
    stream_name,
    site_id,
    year,
    variable,
    label,
    units,
    value,
    source_file
  )

values_to_review <- bind_rows(range_errors, product_review_flags, extreme_values) |>
  distinct() |>
  arrange(variable, value)

# Summarize fallback use and sites that need review

review_flags_by_site <- bind_rows(range_errors, product_review_flags) |>
  mutate(site_key = paste(lter, stream_name, sep = "__")) |>
  count(site_key, name = "flagged_values")

sites_to_review <- annual_data |>
  group_by(site_key, lter, stream_name, site_id) |>
  summarise(
    years_present = n_distinct(year),
    years_missing = length(years) - years_present,
    fine_scale_fallback_years = sum(used_fine_scale_fallback, na.rm = TRUE),
    tiny_watershed = if ("tiny_watershed" %in% names(annual_data)) {
      any(tiny_watershed %in% TRUE, na.rm = TRUE)
    } else {
      NA
    },
    polygon_area_km2 = if ("polygon_area_km2" %in% names(annual_data)) {
      first(polygon_area_km2)
    } else {
      NA_real_
    },
    .groups = "drop"
  ) |>
  left_join(
    metadata_review |>
      count(site_key, name = "metadata_fields_that_change"),
    by = "site_key"
  ) |>
  left_join(review_flags_by_site, by = "site_key") |>
  mutate(
    metadata_fields_that_change = coalesce(metadata_fields_that_change, 0L),
    flagged_values = coalesce(flagged_values, 0L)
  ) |>
  filter(
    years_missing > 0 |
      fine_scale_fallback_years > 0 |
      metadata_fields_that_change > 0 |
      flagged_values > 0
  ) |>
  arrange(desc(years_missing), desc(metadata_fields_that_change), desc(flagged_values), desc(fine_scale_fallback_years), lter, stream_name)

# Record the main checks in one table

qa_summary <- tibble(
  check = c(
    "Annual CSV files",
    "Years represented",
    "Rows per year",
    "Unique site-year rows",
    "Complete site records",
    "Source spatial-table sites represented",
    "Source HydroSHEDS sites represented",
    "Expected total rows",
    "Missing ERA5-Land values",
    "Stable site metadata",
    "Values outside expected bounds",
    "ERA5-Land values needing interpretation",
    "Fine-scale fallback rows"
  ),
  status = c(
    if (length(export_paths) == length(years)) "PASS" else "FAIL",
    if (setequal(sort(unique(annual_data$year)), years)) "PASS" else "FAIL",
    if (n_distinct(rows_by_year$rows) == 1) "PASS" else "FAIL",
    if (nrow(duplicate_site_years) == 0) "PASS" else "FAIL",
    if (all(site_year_coverage$years_present == length(years))) "PASS" else "FAIL",
    if (nrow(missing_source_sites) == 0) "PASS" else "FAIL",
    if (nrow(missing_hydrosheds_sites) == 0) "PASS" else "FAIL",
    if (nrow(annual_data) == expected_row_count) "PASS" else "FAIL",
    if (sum(is.na(long_data$value)) == 0) "PASS" else "FAIL",
    if (nrow(metadata_review) == 0) "PASS" else "FAIL",
    if (nrow(range_errors) == 0) "PASS" else "FAIL",
    if (nrow(product_review_flags) == 0) "PASS" else "REVIEW",
    if (sum(annual_data$used_fine_scale_fallback) == 0) "PASS" else "REVIEW"
  ),
  result = c(
    paste(length(export_paths), "files"),
    paste(min(annual_data$year), "to", max(annual_data$year)),
    paste(min(rows_by_year$rows), "to", max(rows_by_year$rows), "rows"),
    paste(nrow(duplicate_site_years), "duplicates"),
    paste(sum(site_year_coverage$years_present == length(years)), "of", site_count, "sites"),
    paste(nrow(source_sites) - nrow(missing_source_sites), "of", nrow(source_sites), "sites"),
    paste(nrow(source_hydrosheds_sites) - nrow(missing_hydrosheds_sites), "of", nrow(source_hydrosheds_sites), "sites"),
    paste(nrow(annual_data), "of", expected_row_count, "rows"),
    paste(sum(is.na(long_data$value)), "missing values"),
    paste(nrow(metadata_review), "site-field changes"),
    paste(nrow(range_errors), "rows"),
    paste(nrow(product_review_flags), "rows"),
    paste(sum(annual_data$used_fine_scale_fallback), "rows")
  )
)

# Write tables

write_csv(qa_summary, file.path(qa_folder, "full_annual_qa_summary.csv"), na = "")
write_csv(variable_summary, file.path(qa_folder, "full_annual_variable_summary.csv"), na = "")
write_csv(sites_to_review, file.path(qa_folder, "full_annual_sites_to_review.csv"), na = "")
write_csv(values_to_review, file.path(qa_folder, "full_annual_values_to_review.csv"), na = "")
write_csv(missing_source_sites, file.path(qa_folder, "full_annual_missing_source_sites.csv"), na = "")

# Write one PDF with overview and LTER plots

annual_summary <- long_data |>
  group_by(year, variable, label, units) |>
  summarise(
    percentile_05 = quantile(value, 0.05, na.rm = TRUE),
    median = median(value, na.rm = TRUE),
    percentile_95 = quantile(value, 0.95, na.rm = TRUE),
    .groups = "drop"
  )

annual_plot <- ggplot(annual_summary, aes(year, median)) +
  geom_ribbon(aes(ymin = percentile_05, ymax = percentile_95), fill = "#9ecae1", alpha = 0.45) +
  geom_line(color = "#08519c", linewidth = 0.6) +
  facet_wrap(~ label, scales = "free_y", ncol = 2) +
  labs(
    title = "Annual ERA5-Land values across all sites",
    subtitle = "Median and 5th to 95th percentile",
    x = NULL,
    y = NULL
  ) +
  theme_bw(base_size = 10)

fallback_by_year <- annual_data |>
  count(year, used_fine_scale_fallback) |>
  mutate(fallback = if_else(used_fine_scale_fallback, "Fine-scale retry", "Native scale"))

fallback_plot <- ggplot(fallback_by_year, aes(year, n, fill = fallback)) +
  geom_col() +
  scale_fill_manual(values = c("Fine-scale retry" = "#d95f02", "Native scale" = "#bdbdbd")) +
  labs(
    title = "Fine-scale fallback use by year",
    x = NULL,
    y = "Site rows",
    fill = NULL
  ) +
  theme_bw(base_size = 10) +
  theme(legend.position = "bottom")

fallback_site_plot <- sites_to_review |>
  filter(fine_scale_fallback_years > 0) |>
  mutate(site_label = paste(lter, stream_name, sep = ": ")) |>
  ggplot(aes(polygon_area_km2, reorder(site_label, polygon_area_km2))) +
  geom_point(size = 2.2, color = "#d95f02") +
  scale_x_log10() +
  labs(
    title = "Watersheds using the fine-scale fallback in all 26 years",
    x = "Polygon area (km2, log scale)",
    y = NULL
  ) +
  theme_bw(base_size = 10)

pdf(file.path(qa_folder, "full_annual_qa_plots.pdf"), width = 11, height = 8.5)
print(annual_plot)
print(fallback_plot)
print(fallback_site_plot)

for (lter_name in sort(unique(long_data$lter))) {
  lter_plot <- long_data |>
    filter(lter == lter_name) |>
    ggplot(aes(year, value, group = site_key)) +
    geom_line(alpha = 0.55, linewidth = 0.35, color = "#2b2b2b") +
    facet_wrap(~ label, scales = "free_y", ncol = 2) +
    labs(
      title = paste("ERA5-Land annual time series:", lter_name),
      x = NULL,
      y = NULL
    ) +
    theme_bw(base_size = 10)

  print(lter_plot)
}

dev.off()

message("QA complete")
message("Production CSVs: ", normalizePath(export_folder))
message("QA outputs: ", normalizePath(qa_folder))
print(qa_summary)
