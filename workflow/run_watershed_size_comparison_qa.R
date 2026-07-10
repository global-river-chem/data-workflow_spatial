# Watershed-size ERA5-Land vs old spatial-driver QA.

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
    file.exists(file.path(candidate_roots, "workflow", "run_old_vs_gee_annual_qa.R"))
]

if (!length(matching_roots)) {
  stop(
    "Could not find the data-workflow_spatial repo root from this script location.",
    call. = FALSE
  )
}

repo_root <- matching_roots[[1]]
setwd(repo_root)
message("Working directory: ", repo_root)

# Settings ---------------------------------------------------------------

run_label <- "comparison_sites_fine_scale"
start_year <- 2001
end_year <- 2023

drive_account <- "bushsi@oregonstate.edu"
drive_export_folder_id <- "1Y4Hz9_vZsar61jjhYOrQXG4AR1oQWNAX"
drive_output_folder_id <- "1hYedMgoR1907nwtOjjjqYFzjG28gk3-T"

drive_export_subfolder <- "gee_exports_era5_land_watershed_size_comparison_sites_2001_2023"
drive_qa_subfolder <- "qa_outputs_old_vs_gee_era5_land_comparisons"

reference_driver_path <- Sys.getenv(
  "SILICA_REFERENCE_DRIVER_PATH",
  unset = "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/spatial-data-extractions/spatial-data-files/appeears-nasa/all-data_si-extract_3_20260629.csv"
)

write_site_plots <- TRUE
max_plot_sites <- 80

if (!file.exists(reference_driver_path)) {
  stop(
    "Reference driver file was not found: ",
    reference_driver_path,
    call. = FALSE
  )
}

# Step 1: organize completed GEE exports in Drive ------------------------

GEE_EXPORT_ORGANIZE_ARGS <- c(
  "--run-label", run_label,
  "--start-year", start_year,
  "--end-year", end_year,
  "--drive-account", drive_account,
  "--drive-export-folder-id", drive_export_folder_id,
  "--drive-run-folder", drive_export_subfolder
)

message("Step 1: organizing completed GEE CSV exports in Google Drive.")
source("workflow/organize_drive_exports.R", local = TRUE)
rm(GEE_EXPORT_ORGANIZE_ARGS)

# Step 2: compare ERA5-Land outputs with old spatial-driver products -----

OLD_VS_GEE_QA_ARGS <- c(
  "--run-label", run_label,
  "--slug", "watershed_size_comparison",
  "--plot-subject", "Watershed-size comparison sites",
  "--start-year", start_year,
  "--end-year", end_year,
  "--drive-account", drive_account,
  "--drive-export-folder-id", drive_export_folder_id,
  "--drive-export-subfolder", drive_export_subfolder,
  "--drive-folder-id", drive_output_folder_id,
  "--drive-subfolder", drive_qa_subfolder,
  "--reference-driver-path", reference_driver_path,
  "--write-site-plots", write_site_plots,
  "--max-plot-sites", max_plot_sites
)

message("Step 2: running watershed-size old-vs-GEE QA.")
source("workflow/run_old_vs_gee_annual_qa.R", local = TRUE)
rm(OLD_VS_GEE_QA_ARGS)

message("Watershed-size old-vs-GEE QA finished.")
