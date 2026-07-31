
# Combine downloaded daily ERA5-Land CSVs and derive calendar-month summaries.
# Weekly summaries are optional and use Monday-through-Sunday ISO-style weeks.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
})

source(file.path("tools", "cli_helpers.R"))
source(file.path("tools", "workflow_paths.R"))

args <- commandArgs(trailingOnly = TRUE)
repo_root <- silica_find_repo_root()
input_path <- cli_value(args, "--daily-input", required = TRUE)
output_root <- cli_value(
  args,
  "--output-root",
  file.path(repo_root, "generated_outputs", "gee", "era5-land-rollups")
)
write_weekly <- cli_boolean(args, "--write-weekly", FALSE)

input_path <- normalizePath(input_path, mustWork = TRUE)
input_files <- if (dir.exists(input_path)) {
  sort(list.files(input_path, pattern = "[.]csv$", recursive = TRUE, full.names = TRUE))
} else {
  input_path
}
if (!length(input_files)) {
  stop("No daily ERA5-Land CSV files were found.", call. = FALSE)
}

daily <- bind_rows(lapply(input_files, read_csv, show_col_types = FALSE))
metadata_columns <- c("site_id", "LTER", "Stream_Name", "Shapefile_Name")
value_columns <- c(
  "precip_mm",
  "temp_degC",
  "evapotrans_mm",
  "snow_cover_fraction",
  "snow_water_equiv_mm"
)
assert_required_columns(
  daily,
  c(metadata_columns, "date", value_columns),
  "daily ERA5-Land data"
)
daily <- daily |>
  mutate(date = as.Date(date)) |>
  arrange(site_id, date)
if (any(is.na(daily$date))) {
  stop("At least one daily ERA5-Land date could not be parsed.", call. = FALSE)
}
duplicate_dates <- daily |>
  count(site_id, date, name = "records") |>
  filter(records != 1)
if (nrow(duplicate_dates)) {
  stop(
    "Daily inputs contain duplicate site_id/date rows; remove duplicate downloads ",
    "before aggregation.",
    call. = FALSE
  )
}

complete_sum <- function(values, complete) {
  if (complete && all(!is.na(values))) sum(values) else NA_real_
}

complete_mean <- function(values, complete) {
  if (complete && all(!is.na(values))) mean(values) else NA_real_
}

available_max <- function(values) {
  if (all(is.na(values))) NA_real_ else max(values, na.rm = TRUE)
}

monthly <- daily |>
  mutate(
    year = as.integer(format(date, "%Y")),
    month = as.integer(format(date, "%m")),
    month_start = as.Date(format(date, "%Y-%m-01")),
    next_month_start = as.Date(format(month_start + 32, "%Y-%m-01")),
    expected_days = as.integer(
      next_month_start - month_start
    )
  ) |>
  group_by(across(all_of(metadata_columns)), year, month) |>
  summarise(
    expected_days = first(expected_days),
    days_observed = n_distinct(date),
    complete_period = days_observed == expected_days,
    precip_mm = complete_sum(precip_mm, complete_period),
    temp_degC = complete_mean(temp_degC, complete_period),
    evapotrans_mm = complete_sum(evapotrans_mm, complete_period),
    snow_cover_fraction = complete_mean(snow_cover_fraction, complete_period),
    snow_water_equiv_mm = complete_mean(snow_water_equiv_mm, complete_period),
    used_centroid_fallback = if ("used_centroid_fallback" %in% names(daily)) {
      available_max(used_centroid_fallback)
    } else {
      NA_real_
    },
    .groups = "drop"
  ) |>
  arrange(site_id, year, month)

prepare_output_dir(output_root)
write_csv(daily, file.path(output_root, "era5_land_daily.csv"))
write_csv(monthly, file.path(output_root, "era5_land_monthly_from_daily.csv"))

if (write_weekly) {
  weekly <- daily |>
    mutate(
      week_start = date - (as.integer(format(date, "%u")) - 1L),
      week_end = week_start + 6L
    ) |>
    group_by(across(all_of(metadata_columns)), week_start, week_end) |>
    summarise(
      days_observed = n_distinct(date),
      complete_period = days_observed == 7L,
      precip_mm = complete_sum(precip_mm, complete_period),
      temp_degC = complete_mean(temp_degC, complete_period),
      evapotrans_mm = complete_sum(evapotrans_mm, complete_period),
      snow_cover_fraction = complete_mean(snow_cover_fraction, complete_period),
      snow_water_equiv_mm = complete_mean(snow_water_equiv_mm, complete_period),
      used_centroid_fallback = if ("used_centroid_fallback" %in% names(daily)) {
        available_max(used_centroid_fallback)
      } else {
        NA_real_
      },
      .groups = "drop"
    ) |>
    arrange(site_id, week_start)
  write_csv(weekly, file.path(output_root, "era5_land_weekly_from_daily.csv"))
}

message("Daily rows: ", nrow(daily))
message("Monthly rows: ", nrow(monthly))
message("Incomplete site-months: ", sum(!monthly$complete_period))
if (write_weekly) message("Weekly output written using Monday-Sunday weeks.")
