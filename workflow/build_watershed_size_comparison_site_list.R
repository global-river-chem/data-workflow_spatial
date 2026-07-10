suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tidyr)
})

args <- commandArgs(trailingOnly = TRUE)

get_arg <- function(flag, default = NULL) {
  hit <- which(args == flag)
  if (!length(hit)) {
    return(default)
  }
  if (hit[1] == length(args)) {
    stop("Missing value for ", flag, call. = FALSE)
  }
  args[hit[1] + 1]
}

parse_int_arg <- function(flag, default) {
  value <- get_arg(flag, as.character(default))
  out <- suppressWarnings(as.integer(value))
  if (is.na(out) || out < 0) {
    stop(flag, " must be a non-negative integer.", call. = FALSE)
  }
  out
}

norm_key <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  gsub("_+", "_", x)
}

latest_matching_path <- function(pattern) {
  hits <- Sys.glob(pattern)
  if (!length(hits)) {
    return(NA_character_)
  }
  hits[order(file.info(hits)$mtime, decreasing = TRUE)][[1]]
}

default_combined_path <- latest_matching_path(
  "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions/spatial-data-files/appeears-nasa/all-data_si-extract_3_*.csv"
)

combined_path <- get_arg(
  "--combined",
  Sys.getenv("SILICA_COMPARISON_COMBINED_PATH", unset = default_combined_path)
)
if (is.na(combined_path) || !file.exists(combined_path)) {
  stop("Could not find combined spatial-driver file: ", combined_path, call. = FALSE)
}

today_tag <- format(Sys.Date(), "%Y%m%d")
box_gee_input_folder <- "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions/spatial-data-files/gee/earth-engine-input-files"
outdir <- get_arg(
  "--outdir",
  file.path(box_gee_input_folder, paste0("watershed_size_comparison_sites_", today_tag))
)
per_size_class <- parse_int_arg("--per-size-class", 10)
missing_area_count <- parse_int_arg("--missing-area-count", 5)

dir.create(outdir, recursive = TRUE, showWarnings = FALSE)

required_cols <- c(
  "LTER",
  "Stream_Name",
  "Shapefile_Name",
  "Discharge_File_Name",
  "drainage_area",
  "drainage_area_source"
)

combined <- read_csv(combined_path, show_col_types = FALSE)
missing_cols <- setdiff(required_cols, names(combined))
if (length(missing_cols)) {
  stop(
    "Combined spatial-driver file is missing required columns: ",
    paste(missing_cols, collapse = ", "),
    call. = FALSE
  )
}

clean_sites <- combined %>%
  transmute(
    LTER = trimws(as.character(LTER)),
    Stream_Name = trimws(as.character(Stream_Name)),
    Shapefile_Name = trimws(as.character(Shapefile_Name)),
    Discharge_File_Name = trimws(as.character(Discharge_File_Name)),
    drainage_area_km2 = suppressWarnings(as.numeric(drainage_area)),
    drainage_area_source = trimws(as.character(drainage_area_source)),
    gee_site_id_guess = paste(norm_key(LTER), norm_key(Shapefile_Name), sep = "__"),
    site_label = paste(LTER, Stream_Name, Shapefile_Name, sep = " | "),
    size_class = case_when(
      is.na(drainage_area_km2) ~ "missing_area",
      drainage_area_km2 < 1 ~ "tiny_lt_1_km2",
      drainage_area_km2 < 10 ~ "small_1_10_km2",
      drainage_area_km2 < 100 ~ "medium_10_100_km2",
      TRUE ~ "large_ge_100_km2"
    )
  ) %>%
  distinct(
    LTER,
    Stream_Name,
    Shapefile_Name,
    Discharge_File_Name,
    .keep_all = TRUE
  )

choose_area_samples <- function(data, n_to_keep) {
  data <- data %>%
    filter(!is.na(drainage_area_km2), drainage_area_km2 > 0) %>%
    arrange(drainage_area_km2, LTER, Stream_Name, Shapefile_Name)

  if (!nrow(data) || n_to_keep == 0) {
    return(data[0, ])
  }
  if (nrow(data) <= n_to_keep) {
    return(data)
  }

  data %>%
    mutate(
      log_area = log10(drainage_area_km2),
      area_bin = ntile(log_area, n_to_keep)
    ) %>%
    group_by(area_bin) %>%
    mutate(bin_median_log_area = median(log_area)) %>%
    arrange(abs(log_area - bin_median_log_area), LTER, Stream_Name, Shapefile_Name) %>%
    slice(1) %>%
    ungroup() %>%
    select(-log_area, -area_bin, -bin_median_log_area)
}

and_sites <- clean_sites %>%
  filter(toupper(LTER) == "AND") %>%
  mutate(
    comparison_group = "AND reference check",
    selection_reason = "Keep all AND watersheds from the first corrected small-watershed run."
  )

area_samples <- clean_sites %>%
  filter(toupper(LTER) != "AND", size_class != "missing_area") %>%
  group_by(size_class) %>%
  group_modify(~ choose_area_samples(.x, per_size_class)) %>%
  ungroup() %>%
  mutate(
    comparison_group = "Size-class comparison",
    selection_reason = paste0(
      "Representative non-AND ",
      size_class,
      " watershed selected across the log-area range."
    )
  )

missing_area_sites <- clean_sites %>%
  filter(toupper(LTER) != "AND", size_class == "missing_area") %>%
  arrange(LTER, Stream_Name, Shapefile_Name) %>%
  slice_head(n = missing_area_count) %>%
  mutate(
    comparison_group = "Missing-area check",
    selection_reason = "Drainage area is missing in the current combined spatial-driver file."
  )

comparison_sites <- bind_rows(and_sites, area_samples, missing_area_sites) %>%
  distinct(
    LTER,
    Stream_Name,
    Shapefile_Name,
    Discharge_File_Name,
    .keep_all = TRUE
  ) %>%
  arrange(
    factor(
      comparison_group,
      levels = c("AND reference check", "Size-class comparison", "Missing-area check")
    ),
    factor(
      size_class,
      levels = c(
        "tiny_lt_1_km2",
        "small_1_10_km2",
        "medium_10_100_km2",
        "large_ge_100_km2",
        "missing_area"
      )
    ),
    drainage_area_km2,
    LTER,
    Stream_Name,
    Shapefile_Name
  ) %>%
  mutate(
    comparison_site_number = row_number(),
    run_label = "annual_comparison_sites"
  ) %>%
  select(
    comparison_site_number,
    run_label,
    comparison_group,
    size_class,
    selection_reason,
    LTER,
    Stream_Name,
    Shapefile_Name,
    Discharge_File_Name,
    drainage_area_km2,
    drainage_area_source,
    gee_site_id_guess,
    site_label
  )

size_summary <- clean_sites %>%
  count(size_class, name = "all_sites_n") %>%
  left_join(
    comparison_sites %>%
      count(size_class, name = "comparison_sites_n"),
    by = "size_class"
  ) %>%
  mutate(comparison_sites_n = replace_na(comparison_sites_n, 0L)) %>%
  arrange(
    factor(
      size_class,
      levels = c(
        "tiny_lt_1_km2",
        "small_1_10_km2",
        "medium_10_100_km2",
        "large_ge_100_km2",
        "missing_area"
      )
    )
  )

site_list_path <- file.path(outdir, paste0("gee_annual_comparison_site_list_", today_tag, ".csv"))
summary_path <- file.path(outdir, paste0("gee_annual_comparison_site_summary_", today_tag, ".csv"))

write_csv(comparison_sites, site_list_path, na = "")
write_csv(size_summary, summary_path, na = "")

message("Combined spatial-driver file: ", combined_path)
message("Wrote comparison site list: ", normalizePath(site_list_path))
message("Wrote site-size summary: ", normalizePath(summary_path))
message("Comparison sites: ", nrow(comparison_sites))
message("Size classes:")
print(size_summary)
