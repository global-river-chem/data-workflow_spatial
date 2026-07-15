suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(readr)
  library(tidyr)
})

# Settings

box_root <- "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions"

era5_folder <- file.path(
  box_root,
  "spatial-data-files",
  "gee",
  "earth-engine-outputs",
  "era5_land_annual_2000_2025"
)

old_driver_file <- file.path(
  box_root,
  "spatial-data-files",
  "appeears-nasa",
  "all-data_si-extract_3_20260629.csv"
)

site_reference_file <- file.path(
  box_root,
  "master-datasets",
  "Site_Reference_Table - WRTDS_Reference_Table_LTER_V3.csv"
)

output_folder <- file.path(
  box_root,
  "qaqc",
  "gee",
  "full_old_vs_era5_annual"
)

dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)

clean_lter_name <- function(x) {
  recode(
    trimws(x),
    "Swedish Goverment" = "Sweden",
    "Swedish Government" = "Sweden",
    .default = trimws(x)
  )
}

# Read the completed ERA5-Land files

era5_files <- list.files(
  era5_folder,
  pattern = "^era5_land_[0-9]{4}_all_sites_fine_scale_watershed_extract[.]csv$",
  full.names = TRUE
)

if (length(era5_files) != 26) {
  stop("Expected 26 annual ERA5-Land files", call. = FALSE)
}

era5 <- era5_files |>
  lapply(read_csv, show_col_types = FALSE) |>
  bind_rows() |>
  mutate(
    lter = clean_lter_name(lter),
    site_id = sub("^swedish_goverment__", "sweden__", site_id),
    lter_key = toupper(trimws(lter)),
    shapefile_key = toupper(trimws(shapefile_name)),
    stream_key = toupper(trimws(stream_name)),
    discharge_key = toupper(trimws(Q_file_name)),
    site_key = paste(lter_key, stream_key, sep = "__"),
    used_fine_scale_fallback = tolower(as.character(used_fine_scale_fallback)) %in% c("true", "1")
  )

# Read the previous spatial-driver data

old_drivers <- read_csv(old_driver_file, show_col_types = FALSE) |>
  mutate(
    LTER = clean_lter_name(LTER),
    lter_key = toupper(trimws(LTER)),
    shapefile_key = toupper(trimws(Shapefile_Name)),
    stream_key = toupper(trimws(Stream_Name))
  )

old_attributes <- old_drivers |>
  transmute(
    lter_key,
    shapefile_key,
    stream_key,
    drainage_area_km2 = suppressWarnings(as.numeric(drainage_area)),
    drainage_area_source,
    major_land,
    elevation_mean_m = suppressWarnings(as.numeric(elevation_mean_m)),
    basin_slope_mean_degree = suppressWarnings(as.numeric(basin_slope_mean_degree))
  )

# Match site coordinates from the current site-reference table

site_reference <- read_csv(
  site_reference_file,
  show_col_types = FALSE,
  name_repair = "unique"
) |>
  transmute(
    lter_key = toupper(clean_lter_name(LTER)),
    stream_key = toupper(trimws(Stream_Name)),
    discharge_key = toupper(trimws(Discharge_File_Name)),
    latitude = suppressWarnings(as.numeric(Latitude)),
    longitude = suppressWarnings(as.numeric(Longitude))
  ) |>
  mutate(
    swap_coordinates = abs(latitude) > 90 & abs(longitude) <= 90,
    original_latitude = latitude,
    latitude = if_else(swap_coordinates, longitude, latitude),
    longitude = if_else(swap_coordinates, original_latitude, longitude),
    coordinate = paste(latitude, longitude)
  ) |>
  filter(
    is.finite(latitude),
    is.finite(longitude),
    between(latitude, -90, 90),
    between(longitude, -180, 180)
  )

stream_coordinates <- site_reference |>
  group_by(lter_key, stream_key) |>
  filter(n_distinct(coordinate) == 1) |>
  slice(1) |>
  ungroup() |>
  select(
    lter_key,
    stream_key,
    stream_latitude = latitude,
    stream_longitude = longitude
  )

discharge_coordinates <- site_reference |>
  group_by(lter_key, discharge_key) |>
  filter(n_distinct(coordinate) == 1) |>
  slice(1) |>
  ungroup() |>
  select(
    lter_key,
    discharge_key,
    discharge_latitude = latitude,
    discharge_longitude = longitude
  )

site_coordinates <- era5 |>
  filter(year == min(year)) |>
  distinct(site_key, lter_key, stream_key, discharge_key) |>
  left_join(stream_coordinates, by = c("lter_key", "stream_key")) |>
  left_join(discharge_coordinates, by = c("lter_key", "discharge_key")) |>
  transmute(
    site_key,
    latitude = coalesce(stream_latitude, discharge_latitude),
    longitude = coalesce(stream_longitude, discharge_longitude)
  )

# Put the previous annual drivers in one table

old_evapotrans <- old_drivers |>
  select(lter_key, shapefile_key, stream_key, matches("^evapotrans_[0-9]{4}_kg_m2$")) |>
  pivot_longer(
    cols = matches("^evapotrans_[0-9]{4}_kg_m2$"),
    names_to = "old_column",
    values_to = "old_value"
  ) |>
  mutate(
    comparison = "Actual evapotranspiration",
    old_product = "MODIS evapotranspiration",
    year = as.integer(sub(".*_([0-9]{4})_.*", "\\1", old_column))
  )

old_temperature <- old_drivers |>
  select(lter_key, shapefile_key, stream_key, matches("^temp_[0-9]{4}_degC$")) |>
  pivot_longer(
    cols = matches("^temp_[0-9]{4}_degC$"),
    names_to = "old_column",
    values_to = "old_value"
  ) |>
  mutate(
    comparison = "Air temperature",
    old_product = "NOAA air temperature",
    year = as.integer(sub(".*_([0-9]{4})_.*", "\\1", old_column))
  )

old_precipitation <- old_drivers |>
  select(lter_key, shapefile_key, stream_key, matches("^precip_[0-9]{4}_mm_per_day$")) |>
  pivot_longer(
    cols = matches("^precip_[0-9]{4}_mm_per_day$"),
    names_to = "old_column",
    values_to = "old_value"
  ) |>
  mutate(
    comparison = "Precipitation",
    old_product = "GPCP precipitation",
    year = as.integer(sub(".*_([0-9]{4})_.*", "\\1", old_column)),
    days_in_year = if_else(
      (year %% 4 == 0 & year %% 100 != 0) | year %% 400 == 0,
      366,
      365
    ),
    old_value = old_value * days_in_year
  ) |>
  select(-days_in_year)

old_annual <- bind_rows(old_evapotrans, old_temperature, old_precipitation)

# Join each previous product to the matching ERA5-Land value

match_columns <- c("lter_key", "shapefile_key", "stream_key", "year")

evapotrans_points <- era5 |>
  select(
    all_of(match_columns),
    site_key,
    site_id,
    lter,
    stream_name,
    shapefile_name,
    Q_file_name,
    expected_area_km2,
    polygon_area_km2,
    tiny_watershed,
    used_fine_scale_fallback,
    era5_value = evapotrans_mm
  ) |>
  inner_join(
    old_annual |> filter(comparison == "Actual evapotranspiration"),
    by = match_columns
  )

temperature_points <- era5 |>
  select(
    all_of(match_columns),
    site_key,
    site_id,
    lter,
    stream_name,
    shapefile_name,
    Q_file_name,
    expected_area_km2,
    polygon_area_km2,
    tiny_watershed,
    used_fine_scale_fallback,
    era5_value = temp_degC
  ) |>
  inner_join(
    old_annual |> filter(comparison == "Air temperature"),
    by = match_columns
  )

precipitation_points <- era5 |>
  select(
    all_of(match_columns),
    site_key,
    site_id,
    lter,
    stream_name,
    shapefile_name,
    Q_file_name,
    expected_area_km2,
    polygon_area_km2,
    tiny_watershed,
    used_fine_scale_fallback,
    era5_value = precip_mm
  ) |>
  inner_join(
    old_annual |> filter(comparison == "Precipitation"),
    by = match_columns
  )

comparison_points <- bind_rows(
  evapotrans_points,
  temperature_points,
  precipitation_points
) |>
  left_join(old_attributes, by = c("lter_key", "shapefile_key", "stream_key")) |>
  left_join(site_coordinates, by = "site_key") |>
  mutate(
    drainage_area_km2 = coalesce(drainage_area_km2, expected_area_km2, polygon_area_km2),
    watershed_size = case_when(
      drainage_area_km2 <= 10 ~ "10 km2 or less",
      drainage_area_km2 <= 100 ~ "10 to 100 km2",
      drainage_area_km2 <= 1000 ~ "100 to 1,000 km2",
      drainage_area_km2 <= 10000 ~ "1,000 to 10,000 km2",
      drainage_area_km2 > 10000 ~ "More than 10,000 km2",
      TRUE ~ "Area missing"
    ),
    watershed_size = factor(
      watershed_size,
      levels = c(
        "10 km2 or less",
        "10 to 100 km2",
        "100 to 1,000 km2",
        "1,000 to 10,000 km2",
        "More than 10,000 km2",
        "Area missing"
      )
    ),
    difference = era5_value - old_value,
    absolute_difference = abs(difference),
    percent_difference = if_else(abs(old_value) > 0.001, 100 * difference / old_value, NA_real_)
  ) |>
  filter(!is.na(old_value), !is.na(era5_value))

# Mark sites that have the same full time series in either product

old_histories <- comparison_points |>
  arrange(comparison, site_key, year) |>
  group_by(comparison, site_key) |>
  summarise(
    old_history = paste(year, format(round(old_value, 6), nsmall = 6), sep = ":", collapse = "|"),
    .groups = "drop"
  ) |>
  add_count(comparison, old_history, name = "sites_sharing_old_history") |>
  mutate(shared_old_history = sites_sharing_old_history > 1) |>
  select(-old_history)

era5_histories <- comparison_points |>
  arrange(comparison, site_key, year) |>
  group_by(comparison, site_key) |>
  summarise(
    era5_history = paste(year, format(round(era5_value, 6), nsmall = 6), sep = ":", collapse = "|"),
    .groups = "drop"
  ) |>
  add_count(comparison, era5_history, name = "sites_sharing_era5_history") |>
  mutate(shared_era5_history = sites_sharing_era5_history > 1) |>
  select(-era5_history)

comparison_points <- comparison_points |>
  left_join(old_histories, by = c("comparison", "site_key")) |>
  left_join(era5_histories, by = c("comparison", "site_key")) |>
  arrange(comparison, lter, stream_name, year)

# Summarize differences by site and across all sites

site_summary <- comparison_points |>
  group_by(
    comparison,
    old_product,
    site_key,
    site_id,
    lter,
    stream_name,
    shapefile_name,
    drainage_area_km2,
    watershed_size,
    latitude,
    longitude,
    major_land,
    elevation_mean_m,
    basin_slope_mean_degree,
    shared_old_history,
    sites_sharing_old_history,
    shared_era5_history,
    sites_sharing_era5_history
  ) |>
  summarise(
    years_compared = n(),
    first_year = min(year),
    last_year = max(year),
    old_mean = mean(old_value),
    era5_mean = mean(era5_value),
    mean_difference = mean(difference),
    mean_absolute_difference = mean(absolute_difference),
    root_mean_square_difference = sqrt(mean(difference^2)),
    correlation = if (n() >= 3 && n_distinct(old_value) > 1 && n_distinct(era5_value) > 1) {
      cor(old_value, era5_value)
    } else {
      NA_real_
    },
    .groups = "drop"
  )

overall_summary <- comparison_points |>
  group_by(comparison, old_product) |>
  summarise(
    sites_compared = n_distinct(site_key),
    years_compared = n_distinct(year),
    site_years_compared = n(),
    first_year = min(year),
    last_year = max(year),
    mean_difference = mean(difference),
    median_difference = median(difference),
    mean_absolute_difference = mean(absolute_difference),
    root_mean_square_difference = sqrt(mean(difference^2)),
    correlation = cor(old_value, era5_value),
    r_squared = correlation^2,
    slope = unname(coef(lm(era5_value ~ old_value))[2]),
    sites_sharing_old_history = n_distinct(site_key[shared_old_history]),
    sites_sharing_era5_history = n_distinct(site_key[shared_era5_history]),
    sites_with_coordinates = n_distinct(site_key[is.finite(latitude)]),
    .groups = "drop"
  ) |>
  mutate(group = "All sites", .before = comparison)

lter_summary <- comparison_points |>
  group_by(lter, comparison, old_product) |>
  summarise(
    sites_compared = n_distinct(site_key),
    years_compared = n_distinct(year),
    site_years_compared = n(),
    first_year = min(year),
    last_year = max(year),
    mean_difference = mean(difference),
    median_difference = median(difference),
    mean_absolute_difference = mean(absolute_difference),
    root_mean_square_difference = sqrt(mean(difference^2)),
    correlation = if (n() >= 3 && n_distinct(old_value) > 1 && n_distinct(era5_value) > 1) {
      cor(old_value, era5_value)
    } else {
      NA_real_
    },
    r_squared = correlation^2,
    slope = if (n() >= 3 && n_distinct(old_value) > 1 && n_distinct(era5_value) > 1) {
      unname(coef(lm(era5_value ~ old_value))[2])
    } else {
      NA_real_
    },
    sites_sharing_old_history = n_distinct(site_key[shared_old_history]),
    sites_sharing_era5_history = n_distinct(site_key[shared_era5_history]),
    sites_with_coordinates = n_distinct(site_key[is.finite(latitude)]),
    .groups = "drop"
  ) |>
  rename(group = lter)

comparison_summary <- bind_rows(overall_summary, lter_summary) |>
  arrange(comparison, desc(group == "All sites"), group)

plot_stats <- comparison_summary |>
  mutate(
    units = if_else(comparison == "Air temperature", "deg C", "mm yr-1"),
    r_squared_text = if_else(is.na(r_squared), "NA", sprintf("%.2f", r_squared)),
    rmse_text = if_else(
      comparison == "Air temperature",
      sprintf("%.2f", root_mean_square_difference),
      sprintf("%.1f", root_mean_square_difference)
    ),
    bias_text = if_else(
      comparison == "Air temperature",
      sprintf("%.2f", mean_difference),
      sprintf("%.1f", mean_difference)
    ),
    mae_text = if_else(
      comparison == "Air temperature",
      sprintf("%.2f", mean_absolute_difference),
      sprintf("%.1f", mean_absolute_difference)
    ),
    stats_label = paste0(
      "R2 = ", r_squared_text,
      "\nRMSE = ", rmse_text, " ", units,
      "\nMean difference = ", bias_text, " ", units,
      "\nMAE = ", mae_text, " ", units,
      "\n", sites_compared, " sites; ",
      format(site_years_compared, big.mark = ",", scientific = FALSE),
      " site-years"
    )
  )

area_stats <- site_summary |>
  filter(is.finite(drainage_area_km2), drainage_area_km2 > 0) |>
  group_by(comparison) |>
  summarise(
    spearman_rho = cor(log10(drainage_area_km2), mean_difference, method = "spearman"),
    sites = n(),
    label_x = min(drainage_area_km2),
    label_y = max(mean_difference),
    .groups = "drop"
  ) |>
  mutate(stats_label = paste0("Spearman rho = ", sprintf("%.2f", spearman_rho), "\n", sites, " sites"))

latitude_stats <- site_summary |>
  filter(is.finite(latitude)) |>
  group_by(comparison) |>
  summarise(
    spearman_rho = cor(latitude, mean_difference, method = "spearman"),
    sites = n(),
    .groups = "drop"
  ) |>
  mutate(stats_label = paste0("Spearman rho = ", sprintf("%.2f", spearman_rho), "\n", sites, " sites"))

# Write the three review tables

write_csv(
  comparison_points,
  file.path(output_folder, "full_old_vs_era5_points.csv"),
  na = ""
)
write_csv(
  site_summary,
  file.path(output_folder, "full_old_vs_era5_site_summary.csv"),
  na = ""
)
write_csv(
  comparison_summary,
  file.path(output_folder, "full_old_vs_era5_summary.csv"),
  na = ""
)

# Build one PDF with overall and per-LTER plots

comparison_plot <- ggplot(comparison_points, aes(old_value, era5_value)) +
  geom_abline(slope = 1, intercept = 0, color = "#636363", linewidth = 0.5) +
  geom_point(alpha = 0.12, size = 0.7, color = "#2166ac") +
  geom_label(
    data = plot_stats |> filter(group == "All sites"),
    aes(x = -Inf, y = Inf, label = stats_label),
    hjust = -0.05,
    vjust = 1.05,
    size = 3,
    linewidth = 0.2,
    fill = "white",
    alpha = 0.9,
    inherit.aes = FALSE
  ) +
  facet_wrap(~ comparison, scales = "free", ncol = 2) +
  labs(
    title = "Previous spatial drivers compared with ERA5-Land",
    x = "Previous spatial-driver value",
    y = "ERA5-Land value"
  ) +
  theme_bw(base_size = 10)

area_plot <- ggplot(site_summary, aes(drainage_area_km2, mean_difference)) +
  geom_hline(yintercept = 0, color = "#636363", linewidth = 0.4) +
  geom_point(aes(color = watershed_size), alpha = 0.65, size = 1.5) +
  geom_smooth(method = "loess", se = FALSE, color = "black", linewidth = 0.7) +
  geom_label(
    data = area_stats,
    aes(x = label_x, y = label_y, label = stats_label),
    hjust = 0,
    vjust = 1,
    size = 3,
    linewidth = 0.2,
    fill = "white",
    alpha = 0.9,
    inherit.aes = FALSE
  ) +
  scale_x_log10() +
  facet_wrap(~ comparison, scales = "free_y", ncol = 2) +
  labs(
    title = "Mean difference by watershed area",
    subtitle = "Difference is ERA5-Land minus the previous product",
    x = "Drainage area (km2, log scale)",
    y = "Mean difference",
    color = "Watershed area"
  ) +
  theme_bw(base_size = 10) +
  theme(legend.position = "bottom")

latitude_plot <- site_summary |>
  filter(is.finite(latitude)) |>
  ggplot(aes(latitude, mean_difference)) +
  geom_hline(yintercept = 0, color = "#636363", linewidth = 0.4) +
  geom_point(alpha = 0.55, size = 1.4, color = "#1b9e77") +
  geom_smooth(method = "loess", se = FALSE, color = "black", linewidth = 0.7) +
  geom_label(
    data = latitude_stats,
    aes(x = -Inf, y = Inf, label = stats_label),
    hjust = -0.05,
    vjust = 1.05,
    size = 3,
    linewidth = 0.2,
    fill = "white",
    alpha = 0.9,
    inherit.aes = FALSE
  ) +
  facet_wrap(~ comparison, scales = "free_y", ncol = 2) +
  labs(
    title = "Mean difference by latitude",
    subtitle = "Coordinates were available for a subset of sites",
    x = "Latitude",
    y = "Mean difference"
  ) +
  theme_bw(base_size = 10)

land_cover_plot <- site_summary |>
  filter(!is.na(major_land), nzchar(major_land)) |>
  add_count(comparison, major_land, name = "sites_in_class") |>
  filter(sites_in_class >= 5) |>
  ggplot(aes(reorder(major_land, mean_difference, FUN = median), mean_difference)) +
  geom_hline(yintercept = 0, color = "#636363", linewidth = 0.4) +
  geom_boxplot(outlier.shape = NA, fill = "#d9d9d9") +
  geom_point(alpha = 0.35, size = 0.9, color = "#7b3294", position = position_jitter(width = 0.12)) +
  coord_flip() +
  facet_wrap(~ comparison, scales = "free", ncol = 2) +
  labs(
    title = "Mean difference by major land-cover class",
    subtitle = "Classes with at least five matched sites",
    x = NULL,
    y = "Mean difference"
  ) +
  theme_bw(base_size = 10)

pdf(file.path(output_folder, "full_old_vs_era5_plots.pdf"), width = 11, height = 8.5)
print(comparison_plot)
print(area_plot)
print(latitude_plot)
print(land_cover_plot)

for (lter_name in sort(unique(comparison_points$lter))) {
  lter_plot_stats <- plot_stats |>
    filter(group == lter_name)

  lter_plot <- comparison_points |>
    filter(lter == lter_name) |>
    ggplot(aes(old_value, era5_value)) +
    geom_abline(slope = 1, intercept = 0, color = "#636363", linewidth = 0.5) +
    geom_point(
      aes(color = watershed_size, shape = shared_old_history),
      alpha = 0.6,
      size = 1.4
    ) +
    geom_label(
      data = lter_plot_stats,
      aes(x = -Inf, y = Inf, label = stats_label),
      hjust = -0.05,
      vjust = 1.05,
      size = 2.6,
      linewidth = 0.2,
      fill = "white",
      alpha = 0.9,
      inherit.aes = FALSE
    ) +
    scale_shape_manual(values = c("FALSE" = 16, "TRUE" = 17)) +
    facet_wrap(~ comparison, scales = "free", ncol = 2) +
    labs(
      title = paste("Previous drivers compared with ERA5-Land:", lter_name),
      x = "Previous spatial-driver value",
      y = "ERA5-Land value",
      color = "Watershed area",
      shape = "Same old history"
    ) +
    theme_bw(base_size = 10) +
    theme(legend.position = "bottom")

  print(lter_plot)
}

dev.off()

message("Full old-vs-ERA5 comparison complete")
message("Outputs: ", normalizePath(output_folder))
print(comparison_summary)
