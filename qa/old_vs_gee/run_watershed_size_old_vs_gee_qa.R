# Watershed-size ERA5-Land vs old spatial-driver QA.
# Run this from the data-workflow_spatial repo root.

if (!file.exists("qa/old_vs_gee/run_old_vs_gee_annual_comparison_qa.R")) {
  stop(
    "Set the R working directory to the data-workflow_spatial repo root before running this script.",
    call. = FALSE
  )
}

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

write_site_plots <- FALSE
max_plot_sites <- 40

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
source("post_export/organize_gee_exports_in_drive.R", local = TRUE)
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
source("qa/old_vs_gee/run_old_vs_gee_annual_comparison_qa.R", local = TRUE)
rm(OLD_VS_GEE_QA_ARGS)

message("Watershed-size old-vs-GEE QA finished.")
