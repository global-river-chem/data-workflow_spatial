# Watershed-size ERA5-Land vs old spatial-driver QA.

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
  library(readr)
  library(tidyr)
})

env_bool <- function(name, default) {
  value <- Sys.getenv(name, unset = if (default) "TRUE" else "FALSE")
  toupper(value) %in% c("TRUE", "T", "1", "YES", "Y")
}

# Settings ---------------------------------------------------------------

run_label <- "comparison_sites_fine_scale"
start_year <- 2001
end_year <- 2023

drive_account <- Sys.getenv("SILICA_DRIVE_ACCOUNT", unset = "bushsi@oregonstate.edu")
drive_export_folder_id <- Sys.getenv("SILICA_DRIVE_EXPORT_ROOT_ID", unset = "1Y4Hz9_vZsar61jjhYOrQXG4AR1oQWNAX")
drive_output_folder_id <- Sys.getenv("SILICA_DRIVE_QA_OUTPUT_ROOT_ID", unset = "1hYedMgoR1907nwtOjjjqYFzjG28gk3-T")
direct_drive_export_folder_id <- Sys.getenv("SILICA_DIRECT_DRIVE_EXPORT_FOLDER_ID", unset = "")

drive_export_subfolder <- "gee_exports_era5_land_watershed_size_comparison_sites_2001_2023"
drive_qa_subfolder <- "watershed_size_qa"
drive_plot_folder <- "plots"
drive_csv_folder <- "tables"

previous_drive_export_subfolders <- c(
  "gee_exports_era5_land_watershed_size_comparison_sites_2001_2023"
)
previous_drive_export_folder_ids <- c(
  "19eYZLEfCtNAxJvQv1-9y53XU6emaUh3F"
)

download_from_drive <- env_bool("SILICA_DOWNLOAD_FROM_DRIVE", TRUE)
upload_to_drive <- env_bool("SILICA_UPLOAD_TO_DRIVE", TRUE)
download_overwrite <- env_bool("SILICA_DOWNLOAD_OVERWRITE", FALSE)
drive_overwrite <- env_bool("SILICA_GOOGLE_DRIVE_OVERWRITE", TRUE)
write_site_plots <- env_bool("SILICA_WRITE_SITE_PLOTS", TRUE)

reference_driver_path <- Sys.getenv(
  "SILICA_REFERENCE_DRIVER_PATH",
  unset = "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions/spatial-data-files/appeears-nasa/all-data_si-extract_3_20260629.csv"
)

# Repo setup -------------------------------------------------------------

script_path_from_source <- function() {
  frames <- sys.frames()
  paths <- vapply(
    frames,
    function(frame) {
      if (is.null(frame$ofile)) {
        return(NA_character_)
      }
      frame$ofile
    },
    character(1)
  )
  paths <- paths[!is.na(paths) & nzchar(paths)]
  if (!length(paths)) {
    return(NA_character_)
  }
  normalizePath(paths[[length(paths)]], mustWork = TRUE)
}

script_path_from_rstudio <- function() {
  if (!requireNamespace("rstudioapi", quietly = TRUE) || !rstudioapi::isAvailable()) {
    return(NA_character_)
  }

  path <- tryCatch(
    rstudioapi::getActiveDocumentContext()$path,
    error = function(error) NA_character_
  )
  if (is.na(path) || !nzchar(path)) {
    return(NA_character_)
  }
  normalizePath(path, mustWork = TRUE)
}

script_path <- script_path_from_source()
if (is.na(script_path)) {
  script_path <- script_path_from_rstudio()
}

candidate_roots <- c(
  if (!is.na(script_path)) normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE),
  getwd()
)

matching_roots <- candidate_roots[
  file.exists(file.path(candidate_roots, "config", "driver-products.yml")) &
    file.exists(file.path(candidate_roots, "workflow", "run_watershed_size_comparison_qa.R"))
]

if (!length(matching_roots)) {
  stop("Could not find the data-workflow_spatial repo root from this script location.", call. = FALSE)
}

repo_root <- matching_roots[[1]]
setwd(repo_root)
message("Working directory: ", repo_root)

if (!file.exists(reference_driver_path)) {
  stop("Reference driver file was not found: ", reference_driver_path, call. = FALSE)
}

today_tag <- format(Sys.Date(), "%Y%m%d")
box_spatial_root <- "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions"
box_gee_output_root <- file.path(
  box_spatial_root,
  "spatial-data-files",
  "gee",
  "earth-engine-outputs"
)
box_qa_root <- file.path(box_spatial_root, "qaqc", "gee")
expected_years <- seq.int(start_year, end_year)
expected_csv_names <- paste0(
  "era5_land_",
  expected_years,
  "_",
  run_label,
  "_watershed_extract.csv"
)
local_export_folder <- Sys.getenv(
  "SILICA_BASE_ERA5_EXPORT_FOLDER",
  unset = file.path(
    box_gee_output_root,
    "gee_exports_watershed_size_20260710",
    paste0("era5_", start_year, "_", end_year)
  )
)
download_folder <- file.path(
  box_gee_output_root,
  paste0("gee_exports_watershed_size_base_", today_tag),
  paste0("era5_", start_year, "_", end_year)
)
output_folder <- file.path(
  box_qa_root,
  paste0("watershed_size_qa_", today_tag)
)
dir.create(download_folder, recursive = TRUE, showWarnings = FALSE)
dir.create(output_folder, recursive = TRUE, showWarnings = FALSE)

# General helpers --------------------------------------------------------

regex_escape <- function(x) {
  gsub("([][{}()+*^$|\\\\?.])", "\\\\\\1", x)
}

exact_pattern <- function(file_name) {
  paste0("^", regex_escape(file_name), "$")
}

parse_year <- function(x) {
  as.integer(sub(".*_(\\d{4})(_|$).*", "\\1", x))
}

days_in_year <- function(year) {
  ifelse((year %% 4 == 0 & year %% 100 != 0) | year %% 400 == 0, 366, 365)
}

is_true_flag <- function(x) {
  tolower(as.character(x)) %in% c("true", "1")
}

nice_number <- function(x) {
  if (is.na(x)) {
    return(NA_character_)
  }
  if (x != 0 && abs(x) < 0.01) {
    return(format(signif(x, 2), scientific = FALSE, trim = TRUE))
  }
  format(round(x, 2), trim = TRUE)
}

year_breaks <- function(years) {
  years <- sort(unique(years[!is.na(years)]))
  if (length(years) <= 8) {
    return(years)
  }
  pretty(years, n = 6)
}

first_existing_dir <- function(paths) {
  paths <- unique(paths[nzchar(paths)])
  paths[dir.exists(paths)]
}

# Google Drive helpers ---------------------------------------------------

authenticate_drive <- function() {
  if (!requireNamespace("googledrive", quietly = TRUE)) {
    stop("Install the googledrive package before using Google Drive steps.", call. = FALSE)
  }

  if (nzchar(drive_account)) {
    googledrive::drive_auth(email = drive_account)
  } else {
    googledrive::drive_auth()
  }

  invisible(TRUE)
}

drive_child_folder <- function(folder_name, parent) {
  folder_name <- as.character(folder_name[[1]])
  folder_contents <- googledrive::drive_ls(parent)
  folder_matches <- folder_contents[
    as.character(folder_contents$name) == folder_name,
    ,
    drop = FALSE
  ]

  if (nrow(folder_matches) > 0) {
    return(folder_matches[1, ])
  }

  googledrive::drive_mkdir(folder_name, path = parent)
}

find_drive_file_in_folder <- function(file_name, folder_id) {
  tryCatch(
    googledrive::drive_ls(
      googledrive::as_id(folder_id),
      pattern = exact_pattern(file_name)
    ),
    error = function(error) {
      message("Skipping Drive folder that could not be read: ", folder_id)
      data.frame(name = character(), id = character())
    }
  )
}

drive_modified_time <- function(files) {
  as.POSIXct(
    vapply(
      files$drive_resource,
      function(resource) {
        if (is.null(resource$modifiedTime)) {
          return(NA_character_)
        }
        resource$modifiedTime
      },
      character(1)
    ),
    format = "%Y-%m-%dT%H:%M:%OSZ",
    tz = "UTC"
  )
}

latest_drive_match <- function(files) {
  if (!nrow(files)) {
    return(files)
  }

  files[order(drive_modified_time(files), decreasing = TRUE, na.last = TRUE), , drop = FALSE][1, , drop = FALSE]
}

find_latest_drive_export <- function(file_name, folder_ids) {
  folder_matches <- lapply(unique(folder_ids), function(folder_id) {
    find_drive_file_in_folder(file_name, folder_id)
  })
  matches <- bind_rows(folder_matches)

  if (!nrow(matches)) {
    matches <- googledrive::drive_find(pattern = exact_pattern(file_name), n_max = 25)
  }

  latest_drive_match(matches)
}

find_drive_child_folder <- function(folder_name, parent) {
  folder_name <- as.character(folder_name[[1]])
  folder_contents <- googledrive::drive_ls(parent)
  folder_matches <- folder_contents[
    as.character(folder_contents$name) == folder_name,
    ,
    drop = FALSE
  ]

  if (!nrow(folder_matches)) {
    return(NULL)
  }

  folder_matches[1, ]
}

find_previous_drive_export_folders <- function(
  export_root,
  previous_subfolders = character(),
  previous_folder_ids = character()
) {
  named_folders <- lapply(
    previous_subfolders,
    find_drive_child_folder,
    parent = export_root
  )
  named_folder_ids <- vapply(
    named_folders[!vapply(named_folders, is.null, logical(1))],
    function(folder) folder$id[[1]],
    character(1)
  )

  unique(c(
    previous_folder_ids[nzchar(previous_folder_ids)],
    named_folder_ids
  ))
}

organize_drive_exports <- function(
  drive_export_subfolder,
  expected_csv_names,
  previous_subfolders = character(),
  previous_folder_ids = character()
) {
  authenticate_drive()

  if (nzchar(direct_drive_export_folder_id)) {
    run_folder <- googledrive::drive_get(googledrive::as_id(direct_drive_export_folder_id))
    message("Using direct GEE Drive export folder ID: ", direct_drive_export_folder_id)
    message("Run folder: ", run_folder$name[[1]])
    message("Run folder URL: https://drive.google.com/drive/folders/", run_folder$id[[1]])
    return(run_folder)
  }

  export_root <- googledrive::as_id(drive_export_folder_id)
  run_folder <- drive_child_folder(drive_export_subfolder, export_root)
  source_folder_ids <- unique(c(
    run_folder$id[[1]],
    find_previous_drive_export_folders(
      export_root,
      previous_subfolders = previous_subfolders,
      previous_folder_ids = previous_folder_ids
    ),
    drive_export_folder_id
  ))

  message("Shared GEE Drive folder ID: ", drive_export_folder_id)
  message("Run folder: ", drive_export_subfolder)
  message("Run folder URL: https://drive.google.com/drive/folders/", run_folder$id[[1]])

  missing <- character(0)

  for (file_name in expected_csv_names) {
    match <- find_latest_drive_export(file_name, source_folder_ids)
    if (nrow(match)) {
      parent_ids <- as.character(unlist(match$drive_resource[[1]]$parents))
      if (run_folder$id[[1]] %in% parent_ids) {
        message("Already in run folder: ", file_name)
      } else {
        googledrive::drive_mv(match[1, ], path = googledrive::as_id(run_folder))
        message("Moved latest matching export to run folder: ", file_name)
      }
      next
    }

    missing <- c(missing, file_name)
  }

  message("CSV files organized/found in run folder: ", length(expected_csv_names) - length(missing))
  message("CSV files not found yet: ", length(missing))

  if (length(missing)) {
    stop("Missing expected GEE exports: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  invisible(run_folder)
}

download_drive_exports <- function(run_folder_id, expected_csv_names, local_export_folder) {
  authenticate_drive()

  downloaded <- character(0)
  missing <- character(0)

  for (file_name in expected_csv_names) {
    local_path <- file.path(local_export_folder, file_name)
    if (file.exists(local_path) && !download_overwrite) {
      downloaded <- c(downloaded, local_path)
      next
    }

    matches <- latest_drive_match(find_drive_file_in_folder(file_name, run_folder_id))
    if (!nrow(matches)) {
      missing <- c(missing, file_name)
      next
    }

    googledrive::drive_download(matches[1, ], path = local_path, overwrite = TRUE)
    message("Downloaded from Google Drive: ", file_name)
    downloaded <- c(downloaded, local_path)
  }

  if (length(missing)) {
    stop("Could not download expected exports: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  invisible(downloaded)
}

upload_output_to_drive <- function(path, drive_folder) {
  uploaded <- googledrive::drive_upload(
    media = path,
    path = googledrive::as_id(drive_folder),
    name = basename(path),
    overwrite = drive_overwrite
  )
  message("Uploaded to Google Drive: ", uploaded$name)
  invisible(uploaded)
}

local_export_set_complete <- function(folder, expected_csv_names) {
  dir.exists(folder) && all(file.exists(file.path(folder, expected_csv_names)))
}

# Step 1: organize and download GEE exports -----------------------------

exports_are_local <- local_export_set_complete(local_export_folder, expected_csv_names)

if (download_from_drive || upload_to_drive) {
  if (exports_are_local) {
    message("Step 1: using complete local ERA5-Land CSV exports: ", local_export_folder)
    run_folder <- NULL
  } else {
    message("Step 1: organizing completed ERA5-Land CSV exports in Google Drive.")
    run_folder <- organize_drive_exports(
      drive_export_subfolder = drive_export_subfolder,
      expected_csv_names = expected_csv_names,
      previous_subfolders = previous_drive_export_subfolders,
      previous_folder_ids = previous_drive_export_folder_ids
    )
  }
} else {
  message("Step 1: using local GEE CSV exports.")
  run_folder <- NULL
}

if (download_from_drive) {
  if (!exports_are_local) {
    download_drive_exports(
      run_folder_id = run_folder$id[[1]],
      expected_csv_names = expected_csv_names,
      local_export_folder = download_folder
    )
  }
}

box_output_dirs <- if (dir.exists(box_gee_output_root)) {
  list.dirs(box_gee_output_root, recursive = TRUE, full.names = TRUE)
} else {
  character(0)
}

find_export_files <- function(label, preferred_local_folders, expected_years, export_label) {
  era5_pattern <- paste0(
    "^era5_land_[0-9]{4}_",
    regex_escape(label),
    "_watershed_extract\\.csv$"
  )

  candidate_dirs <- first_existing_dir(c(
    preferred_local_folders,
    box_output_dirs,
    "/Users/sidneybush/Downloads",
    box_gee_output_root
  ))

  files_by_dir <- lapply(candidate_dirs, function(folder) {
    list.files(folder, pattern = era5_pattern, full.names = TRUE)
  })

  folder_summary <- tibble(
    folder = candidate_dirs,
    n_files = lengths(files_by_dir),
    latest_file_time = as.POSIXct(vapply(
      files_by_dir,
      function(files) {
        if (!length(files)) {
          return(NA_real_)
        }
        max(file.info(files)$mtime)
      },
      numeric(1)
    ), origin = "1970-01-01")
  ) %>%
    filter(n_files > 0) %>%
    arrange(desc(n_files), desc(latest_file_time))

  if (!nrow(folder_summary)) {
    stop("Could not find the expected local ", export_label, " export CSVs.", call. = FALSE)
  }

  export_folder <- folder_summary$folder[[1]]
  export_files <- sort(list.files(export_folder, pattern = era5_pattern, full.names = TRUE))
  export_years <- as.integer(sub("^era5_land_([0-9]{4})_.*$", "\\1", basename(export_files)))
  missing_years <- setdiff(expected_years, export_years)

  message("Using ", export_label, " export folder: ", normalizePath(export_folder))
  message("Found ", export_label, " export files: ", length(export_files))

  if (length(missing_years)) {
    stop(
      "Missing expected ",
      export_label,
      " export years: ",
      paste(missing_years, collapse = ", "),
      call. = FALSE
    )
  }

  list(folder = export_folder, files = export_files)
}

era5_export <- find_export_files(
  label = run_label,
  preferred_local_folders = c(download_folder, local_export_folder),
  expected_years = expected_years,
  export_label = "ERA5-Land"
)

# Step 2: compare ERA5-Land with old spatial-driver products -------------

message("Step 2: running watershed-size old-vs-GEE QA.")

era5_raw <- era5_export$files %>%
  lapply(read_csv, show_col_types = FALSE) %>%
  bind_rows() %>%
  mutate(
    lter_key = toupper(lter),
    shapefile_key = toupper(shapefile_name)
  )

if (!"used_centroid_fallback" %in% names(era5_raw)) {
  era5_raw$used_centroid_fallback <- NA
}

missing_era5_columns <- setdiff(
  c("used_fine_scale_fallback", "precip_mm", "temp_degC", "evapotrans_mm"),
  names(era5_raw)
)

if (length(missing_era5_columns)) {
  stop(
    "The base ERA5-Land files are missing required columns: ",
    paste(missing_era5_columns, collapse = ", "),
    ".",
    call. = FALSE
  )
}

era5 <- era5_raw %>%
  mutate(
    stream_name = toupper(stream_name),
    used_centroid_fallback = if_else(
      is.na(used_centroid_fallback),
      NA_character_,
      as.character(used_centroid_fallback)
    ),
    used_fine_scale_fallback = if_else(
      is.na(used_fine_scale_fallback),
      NA_character_,
      as.character(used_fine_scale_fallback)
    ),
    era5_fallback_method = case_when(
      is_true_flag(used_fine_scale_fallback) ~ "Fine-scale polygon retry",
      is_true_flag(used_centroid_fallback) ~ "Centroid fill",
      TRUE ~ "Native-scale polygon mean"
    )
  )

reference_drivers <- read_csv(reference_driver_path, show_col_types = FALSE) %>%
  mutate(
    lter_key = toupper(LTER),
    shapefile_key = toupper(Shapefile_Name),
    Stream_Name = toupper(Stream_Name)
  )

modis_et_cols <- grep("^evapotrans_[0-9]{4}_kg_m2$", names(reference_drivers), value = TRUE)
noaa_temp_cols <- grep("^temp_[0-9]{4}_degC$", names(reference_drivers), value = TRUE)
gpcp_precip_cols <- grep("^precip_[0-9]{4}_mm_per_day$", names(reference_drivers), value = TRUE)

modis_et <- reference_drivers %>%
  select(LTER, lter_key, Shapefile_Name, Stream_Name, shapefile_key, all_of(modis_et_cols)) %>%
  pivot_longer(all_of(modis_et_cols), names_to = "reference_variable", values_to = "reference_value") %>%
  mutate(year = parse_year(reference_variable))

noaa_temp <- reference_drivers %>%
  select(LTER, lter_key, Shapefile_Name, Stream_Name, shapefile_key, all_of(noaa_temp_cols)) %>%
  pivot_longer(all_of(noaa_temp_cols), names_to = "reference_variable", values_to = "reference_value") %>%
  mutate(year = parse_year(reference_variable))

gpcp_precip <- reference_drivers %>%
  select(LTER, lter_key, Shapefile_Name, Stream_Name, shapefile_key, all_of(gpcp_precip_cols)) %>%
  pivot_longer(all_of(gpcp_precip_cols), names_to = "reference_variable", values_to = "reference_value") %>%
  mutate(
    year = parse_year(reference_variable),
    reference_value = reference_value * days_in_year(year)
  )

et_points <- era5 %>%
  inner_join(modis_et, by = c("lter_key", "shapefile_key", "year"), suffix = c("_era5", "_modis")) %>%
  transmute(
    comparison = "Evapotranspiration",
    reference_product = "MODIS ET driver",
    reference_variable,
    metric_note = NA_character_,
    lter,
    site_id,
    shapefile_name,
    stream_name,
    year,
    tiny_watershed,
    used_fine_scale_fallback,
    used_centroid_fallback,
    era5_fallback_method,
    polygon_area_km2,
    era5_value = evapotrans_mm,
    reference_value
  )

temp_points <- era5 %>%
  inner_join(noaa_temp, by = c("lter_key", "shapefile_key", "year"), suffix = c("_era5", "_noaa")) %>%
  transmute(
    comparison = "Air temperature",
    reference_product = "NOAA temperature driver",
    reference_variable,
    metric_note = NA_character_,
    lter,
    site_id,
    shapefile_name,
    stream_name,
    year,
    tiny_watershed,
    used_fine_scale_fallback,
    used_centroid_fallback,
    era5_fallback_method,
    polygon_area_km2,
    era5_value = temp_degC,
    reference_value
  )

precip_points <- era5 %>%
  inner_join(gpcp_precip, by = c("lter_key", "shapefile_key", "year"), suffix = c("_era5", "_gpcp")) %>%
  transmute(
    comparison = "Precipitation",
    reference_product = "GPCP precipitation driver",
    reference_variable,
    metric_note = NA_character_,
    lter,
    site_id,
    shapefile_name,
    stream_name,
    year,
    tiny_watershed,
    used_fine_scale_fallback,
    used_centroid_fallback,
    era5_fallback_method,
    polygon_area_km2,
    era5_value = precip_mm,
    reference_value
  )

comparison_points <- bind_rows(et_points, temp_points, precip_points)

if (!nrow(comparison_points)) {
  stop("No matching rows were found between the ERA5-Land and reference driver file.", call. = FALSE)
}

comparison_points <- comparison_points %>%
  mutate(site_panel = paste0(lter, ": ", stream_name, "\n", shapefile_name))

summarize_fit <- function(data, group_columns) {
  data %>%
    filter(!is.na(reference_value), !is.na(era5_value)) %>%
    group_by(across(all_of(group_columns))) %>%
    summarise(
      n = n(),
      reference_min = min(reference_value),
      reference_max = max(reference_value),
      era5_min = min(era5_value),
      era5_max = max(era5_value),
      r_squared = if (
        n() >= 3 &&
          length(unique(reference_value)) >= 2 &&
          length(unique(era5_value)) >= 2
      ) {
        summary(lm(era5_value ~ reference_value))$r.squared
      } else {
        NA_real_
      },
      slope = if (
        n() >= 3 &&
          length(unique(reference_value)) >= 2 &&
          length(unique(era5_value)) >= 2
      ) {
        unname(coef(lm(era5_value ~ reference_value))[2])
      } else {
        NA_real_
      },
      intercept = if (
        n() >= 3 &&
          length(unique(reference_value)) >= 2 &&
          length(unique(era5_value)) >= 2
      ) {
        unname(coef(lm(era5_value ~ reference_value))[1])
      } else {
        NA_real_
      },
      .groups = "drop"
    ) %>%
    mutate(label = if_else(is.na(r_squared), "R2 = NA", paste0("R2 = ", vapply(r_squared, nice_number, character(1)))))
}

find_sites_with_same_values <- function(data, value_column, source_label) {
  value_column <- rlang::ensym(value_column)
  value_history_column <- paste0(source_label, "_value_history")
  shared_values_column <- paste0("shared_", source_label, "_values")
  n_sites_column <- paste0("n_sites_sharing_", source_label)
  shared_sites_column <- paste0("shared_", source_label, "_sites")
  shared_group_column <- paste0("shared_", source_label, "_group")

  data %>%
    filter(!is.na(!!value_column)) %>%
    mutate(
      value_for_match = format(round(!!value_column, 6), nsmall = 6, trim = TRUE),
      year_value = paste(year, value_for_match, sep = ":")
    ) %>%
    arrange(comparison, site_panel, year) %>%
    group_by(comparison, site_panel) %>%
    summarise(!!value_history_column := paste(year_value, collapse = "|"), .groups = "drop") %>%
    add_count(comparison, .data[[value_history_column]], name = n_sites_column) %>%
    group_by(comparison, .data[[value_history_column]]) %>%
    mutate(
      !!shared_sites_column := paste(site_panel, collapse = "; "),
      !!shared_group_column := paste(sub("\\n.*", "", site_panel), collapse = ", ")
    ) %>%
    ungroup() %>%
    mutate(
      !!shared_values_column := .data[[n_sites_column]] > 1,
      !!shared_sites_column := if_else(.data[[shared_values_column]], .data[[shared_sites_column]], NA_character_),
      !!shared_group_column := if_else(.data[[shared_values_column]], .data[[shared_group_column]], NA_character_)
    ) %>%
    select(
      comparison,
      site_panel,
      all_of(c(shared_values_column, n_sites_column, shared_sites_column, shared_group_column))
    )
}

same_era5_notes <- find_sites_with_same_values(comparison_points, era5_value, "era5")
same_reference_notes <- find_sites_with_same_values(comparison_points, reference_value, "reference")

comparison_points <- comparison_points %>%
  left_join(same_era5_notes, by = c("comparison", "site_panel")) %>%
  left_join(same_reference_notes, by = c("comparison", "site_panel"))

site_stats <- summarize_fit(comparison_points, c("comparison", "site_panel")) %>%
  left_join(same_era5_notes, by = c("comparison", "site_panel")) %>%
  left_join(same_reference_notes, by = c("comparison", "site_panel"))

# Plotting ---------------------------------------------------------------

make_site_plot <- function(data, title, x_label, y_label, caption_note = NULL) {
  complete <- data %>%
    filter(!is.na(reference_value), !is.na(era5_value)) %>%
    mutate(site_panel = paste0(stream_name, "\n", shapefile_name))

  fit_labels <- summarize_fit(complete, c("comparison", "site_panel")) %>%
    left_join(
      complete %>%
        distinct(
          comparison,
          site_panel,
          shared_era5_values,
          n_sites_sharing_era5,
          shared_era5_sites,
          shared_era5_group,
          shared_reference_values,
          n_sites_sharing_reference,
          shared_reference_sites,
          shared_reference_group
        ),
      by = c("comparison", "site_panel")
    ) %>%
    mutate(x = -Inf, y = Inf)

  panels_with_same_era5 <- fit_labels %>%
    filter(shared_era5_values %in% TRUE) %>%
    mutate(
      box_xmin = -Inf,
      box_xmax = Inf,
      box_ymin = -Inf,
      box_ymax = Inf,
      shared_label = paste0("same ERA5\n", n_sites_sharing_era5, " sites")
    )

  panels_with_same_reference <- fit_labels %>%
    filter(shared_reference_values %in% TRUE) %>%
    mutate(
      box_xmin = -Inf,
      box_xmax = Inf,
      box_ymin = -Inf,
      box_ymax = Inf,
      shared_label = paste0("same old data\n", n_sites_sharing_reference, " sites")
    )

  era5_outline_colors <- grDevices::colorRampPalette(c(
    "#2C7FB8",
    "#31A354",
    "#E6550D",
    "#756BB1",
    "#636363",
    "#E7298A"
  ))(max(1, length(unique(panels_with_same_era5$shared_era5_group))))
  groups_with_same_era5 <- sort(unique(panels_with_same_era5$shared_era5_group))
  era5_outline_color_for_group <- setNames(
    era5_outline_colors[seq_along(groups_with_same_era5)],
    groups_with_same_era5
  )

  outline_notes <- c(
    if (nrow(panels_with_same_era5) > 0) {
      "Colored labels and solid boxes identify groups of watersheds with the same ERA5-Land annual values."
    },
    if (nrow(panels_with_same_reference) > 0) {
      "Orange labels and dashed boxes identify watersheds with the same old-driver annual values."
    },
    caption_note
  )
  plot_caption <- if (length(outline_notes)) paste(outline_notes, collapse = " ") else NULL

  plot <- ggplot(complete, aes(x = reference_value, y = era5_value)) +
    geom_abline(slope = 1, intercept = 0, color = "grey45", linetype = "dotted", linewidth = 0.45) +
    geom_point(aes(fill = year), shape = 21, color = "white", stroke = 0.15, size = 2.8, alpha = 0.9)

  if (nrow(panels_with_same_era5) > 0) {
    plot <- plot +
      geom_rect(
        data = panels_with_same_era5,
        aes(xmin = box_xmin, xmax = box_xmax, ymin = box_ymin, ymax = box_ymax, color = shared_era5_group),
        inherit.aes = FALSE,
        fill = NA,
        linewidth = 0.7
      ) +
      scale_color_manual(name = "Same ERA5-Land values", values = era5_outline_color_for_group, na.translate = FALSE)
  }

  if (nrow(panels_with_same_reference) > 0) {
    plot <- plot +
      geom_rect(
        data = panels_with_same_reference,
        aes(xmin = box_xmin, xmax = box_xmax, ymin = box_ymin, ymax = box_ymax),
        inherit.aes = FALSE,
        color = "#D95F02",
        fill = NA,
        linetype = "longdash",
        linewidth = 1
      )
  }

  plot +
    geom_label(
      data = panels_with_same_era5,
      aes(x = -Inf, y = -Inf, label = shared_label, color = shared_era5_group),
      inherit.aes = FALSE,
      hjust = -0.05,
      vjust = -0.35,
      size = 2.3,
      linewidth = 0.2,
      label.padding = grid::unit(0.12, "lines"),
      fill = "white",
      alpha = 0.92,
      show.legend = FALSE
    ) +
    geom_label(
      data = panels_with_same_reference,
      aes(x = Inf, y = -Inf, label = shared_label),
      inherit.aes = FALSE,
      hjust = 1.05,
      vjust = -0.35,
      size = 2.3,
      linewidth = 0.2,
      label.padding = grid::unit(0.12, "lines"),
      color = "#A63D00",
      fill = "#FFF3E6",
      alpha = 0.95
    ) +
    geom_text(
      data = fit_labels,
      aes(x = x, y = y, label = label),
      inherit.aes = FALSE,
      hjust = -0.05,
      vjust = 1.45,
      size = 2.6,
      color = "grey15"
    ) +
    facet_wrap(~site_panel, scales = "free", ncol = 4) +
    scale_fill_gradientn(name = "Year", colors = c("#D8ECF8", "#08306B"), breaks = year_breaks(complete$year)) +
    guides(fill = guide_colorbar(barwidth = grid::unit(2.8, "in"), barheight = grid::unit(0.18, "in"))) +
    labs(title = title, x = x_label, y = y_label, caption = plot_caption) +
    theme_minimal(base_size = 10.5) +
    theme(
      plot.title = element_text(face = "bold", size = 14),
      plot.caption = element_text(size = 8.5, color = "grey35"),
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      strip.text = element_text(face = "bold")
    )
}

write_lter_plot_pdf <- function(plot_specs, output_file) {
  pages_written <- 0
  lter_names <- sort(unique(unlist(lapply(plot_specs, function(spec) spec$data$lter))))
  device_is_open <- FALSE
  on.exit({
    if (device_is_open) {
      grDevices::dev.off()
    }
  }, add = TRUE)

  for (lter_name in lter_names) {
    for (spec in plot_specs) {
      page_data <- spec$data %>%
        filter(lter == lter_name, !is.na(reference_value), !is.na(era5_value))

      if (!nrow(page_data)) {
        next
      }

      if (!device_is_open) {
        grDevices::pdf(output_file, width = 12, height = 8.5, onefile = TRUE)
        device_is_open <- TRUE
      }

      print(make_site_plot(
        page_data,
        paste0(lter_name, ": ERA5-Land versus ", spec$reference_label),
        spec$x_label,
        spec$y_label,
        spec$caption_note
      ))
      pages_written <- pages_written + 1
    }
  }

  if (device_is_open) {
    grDevices::dev.off()
    device_is_open <- FALSE
  }

  pages_written
}

# Outputs ----------------------------------------------------------------

comparison_points_file <- file.path(output_folder, "watershed_size_old_vs_gee_points.csv")
site_stats_file <- file.path(output_folder, "watershed_size_old_vs_gee_site_stats.csv")
plots_by_lter_pdf_file <- file.path(output_folder, "watershed_size_old_vs_gee_by_lter.pdf")
and_points_file <- file.path(output_folder, "and_hja_old_vs_gee_points.csv")
and_site_stats_file <- file.path(output_folder, "and_hja_old_vs_gee_site_stats.csv")
and_plots_pdf_file <- file.path(output_folder, "and_hja_old_vs_gee.pdf")
qa_summary_file <- file.path(output_folder, "watershed_size_old_vs_gee_qa_summary.csv")
fallback_by_site_file <- file.path(output_folder, "watershed_size_old_vs_gee_fallback_by_site.csv")
shared_value_groups_file <- file.path(output_folder, "watershed_size_old_vs_gee_shared_values.csv")

write_csv(comparison_points, comparison_points_file, na = "")
write_csv(site_stats, site_stats_file, na = "")
write_csv(filter(comparison_points, lter == "AND"), and_points_file, na = "")
write_csv(filter(site_stats, grepl("^AND: ", site_panel)), and_site_stats_file, na = "")

plot_files <- character(0)
if (write_site_plots) {
  plot_specs <- list(
    list(
      data = filter(comparison_points, comparison == "Evapotranspiration"),
      reference_label = "MODIS ET driver",
      x_label = "MODIS ET driver (kg m-2 yr-1)",
      y_label = "ERA5-Land ET (mm yr-1)",
      caption_note = NULL
    ),
    list(
      data = filter(comparison_points, comparison == "Air temperature"),
      reference_label = "NOAA temperature driver",
      x_label = "NOAA temperature driver (deg C)",
      y_label = "ERA5-Land air temperature (deg C)",
      caption_note = NULL
    ),
    list(
      data = filter(comparison_points, comparison == "Precipitation"),
      reference_label = "GPCP precipitation driver",
      x_label = "GPCP precipitation driver (mm yr-1)",
      y_label = "ERA5-Land precipitation (mm yr-1)",
      caption_note = NULL
    )
  )

  pages_written <- write_lter_plot_pdf(plot_specs, plots_by_lter_pdf_file)
  if (pages_written > 0) {
    message("Wrote LTER plot PDF pages: ", pages_written)
    plot_files <- plots_by_lter_pdf_file
  } else {
    message("Skipped LTER plot PDF because no complete plot rows were found.")
  }

  and_plot_specs <- lapply(plot_specs, function(spec) {
    spec$data <- filter(spec$data, lter == "AND")
    spec
  })
  and_pages_written <- write_lter_plot_pdf(and_plot_specs, and_plots_pdf_file)
  if (and_pages_written > 0) {
    message("Wrote AND/HJA plot PDF pages: ", and_pages_written)
    plot_files <- c(plot_files, and_plots_pdf_file)
  } else {
    message("Skipped AND/HJA plot PDF because no complete AND rows were found.")
  }
}

qa_summary <- comparison_points %>%
  group_by(comparison, reference_product, metric_note) %>%
  summarise(
    n_points = n(),
    n_lter = n_distinct(lter),
    n_sites = n_distinct(site_panel),
    first_year = min(year, na.rm = TRUE),
    last_year = max(year, na.rm = TRUE),
    missing_era5_values = sum(is.na(era5_value)),
    missing_reference_values = sum(is.na(reference_value)),
    native_scale_polygon_mean = sum(era5_fallback_method == "Native-scale polygon mean", na.rm = TRUE),
    fine_scale_polygon_retry = sum(era5_fallback_method == "Fine-scale polygon retry", na.rm = TRUE),
    centroid_fill = sum(era5_fallback_method == "Centroid fill", na.rm = TRUE),
    sites_with_shared_era5_values = n_distinct(site_panel[shared_era5_values %in% TRUE]),
    sites_with_shared_reference_values = n_distinct(site_panel[shared_reference_values %in% TRUE]),
    .groups = "drop"
  ) %>%
  left_join(
    site_stats %>%
      group_by(comparison) %>%
      summarise(
        median_site_r2 = if (all(is.na(r_squared))) NA_real_ else median(r_squared, na.rm = TRUE),
        min_site_r2 = if (all(is.na(r_squared))) NA_real_ else min(r_squared, na.rm = TRUE),
        max_site_r2 = if (all(is.na(r_squared))) NA_real_ else max(r_squared, na.rm = TRUE),
        .groups = "drop"
      ),
    by = "comparison"
  )

fallback_by_site <- comparison_points %>%
  count(comparison, lter, stream_name, shapefile_name, site_panel, era5_fallback_method, name = "n_points") %>%
  arrange(comparison, lter, stream_name, shapefile_name, era5_fallback_method)

shared_value_groups <- bind_rows(
  comparison_points %>%
    filter(shared_era5_values %in% TRUE) %>%
    distinct(
      comparison,
      source = "ERA5-Land",
      shared_group = shared_era5_group,
      n_sites = n_sites_sharing_era5,
      shared_sites = shared_era5_sites
    ),
  comparison_points %>%
    filter(shared_reference_values %in% TRUE) %>%
    distinct(
      comparison,
      source = "old/reference driver",
      shared_group = shared_reference_group,
      n_sites = n_sites_sharing_reference,
      shared_sites = shared_reference_sites
    )
) %>%
  arrange(comparison, source, shared_group)

write_csv(qa_summary, qa_summary_file, na = "")
write_csv(fallback_by_site, fallback_by_site_file, na = "")
write_csv(shared_value_groups, shared_value_groups_file, na = "")

message("Wrote comparison outputs to: ", normalizePath(output_folder))
message("ERA5-Land run label: ", run_label)
message("ERA5-Land years used: ", paste(sort(unique(era5$year)), collapse = ", "))
message("Snow cover is not included in this old-vs-GEE comparison QA.")

if (upload_to_drive) {
  authenticate_drive()
  qa_folder <- drive_child_folder(drive_qa_subfolder, googledrive::as_id(drive_output_folder_id))
  plot_folder <- drive_child_folder(drive_plot_folder, googledrive::as_id(qa_folder))
  csv_folder <- drive_child_folder(drive_csv_folder, googledrive::as_id(qa_folder))

  invisible(lapply(plot_files, upload_output_to_drive, drive_folder = plot_folder))
  invisible(lapply(
    c(
      comparison_points_file,
      site_stats_file,
      and_points_file,
      and_site_stats_file,
      qa_summary_file,
      fallback_by_site_file,
      shared_value_groups_file
    ),
    upload_output_to_drive,
    drive_folder = csv_folder
  ))
}

message("Review folder: ", normalizePath(output_folder))
message("Watershed-size old-vs-GEE QA finished.")
