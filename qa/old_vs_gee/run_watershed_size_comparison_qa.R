#!/usr/bin/env Rscript

# Local R entry point for the current watershed-size old-vs-GEE QA run.
# Colab should only be used for the Earth Engine extraction notebooks.

extra_args <- commandArgs(trailingOnly = TRUE)

has_flag <- function(flag) {
  flag %in% extra_args
}

default_arg <- function(flag, value) {
  if (has_flag(flag)) {
    character()
  } else {
    c(flag, as.character(value))
  }
}

reference_driver_path <- Sys.getenv(
  "SILICA_REFERENCE_DRIVER_PATH",
  unset = "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions/spatial-data-files/appeears-nasa/all-data_si-extract_3_20260629.csv"
)

if (!has_flag("--reference-driver-path") && !file.exists(reference_driver_path)) {
  stop(
    "Reference driver file was not found at the default path. ",
    "Pass --reference-driver-path /path/to/all-data_si-extract_3_20260629.csv ",
    "or set SILICA_REFERENCE_DRIVER_PATH.",
    call. = FALSE
  )
}

organize_args <- c(
  "post_export/organize_gee_exports_in_drive.R",
  extra_args,
  default_arg("--run-label", "comparison_sites_fine_scale"),
  default_arg("--start-year", 2001),
  default_arg("--end-year", 2023),
  default_arg("--drive-account", "bushsi@oregonstate.edu"),
  default_arg("--drive-export-folder-id", "1Y4Hz9_vZsar61jjhYOrQXG4AR1oQWNAX"),
  default_arg("--drive-run-folder", "gee_exports_era5_land_watershed_size_comparison_sites_2001_2023")
)

message("Organizing completed GEE CSV exports in Google Drive.")
organize_status <- system2("Rscript", organize_args)
if (!identical(organize_status, 0L)) {
  stop("GEE export Drive organization failed.", call. = FALSE)
}

cmd_args <- c(
  "qa/old_vs_gee/run_old_vs_gee_annual_comparison_qa.R",
  extra_args,
  default_arg("--run-label", "comparison_sites_fine_scale"),
  default_arg("--slug", "watershed_size_comparison"),
  default_arg("--plot-subject", "Watershed-size comparison sites"),
  default_arg("--start-year", 2001),
  default_arg("--end-year", 2023),
  default_arg("--drive-account", "bushsi@oregonstate.edu"),
  default_arg("--drive-export-folder-id", "1Y4Hz9_vZsar61jjhYOrQXG4AR1oQWNAX"),
  default_arg("--drive-export-subfolder", "gee_exports_era5_land_watershed_size_comparison_sites_2001_2023"),
  default_arg("--drive-subfolder", "qa_outputs_old_vs_gee_era5_land_comparisons"),
  default_arg("--reference-driver-path", reference_driver_path),
  default_arg("--write-site-plots", "FALSE"),
  default_arg("--max-plot-sites", 40)
)

message("Running local watershed-size QA with Rscript.")
status <- system2("Rscript", cmd_args)

if (!identical(status, 0L)) {
  stop("Watershed-size comparison QA failed.", call. = FALSE)
}
