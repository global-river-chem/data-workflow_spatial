# ---- explicit extraction inputs ----

script <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]))
repo_root <- normalizePath(file.path(dirname(script), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
source(file.path(dirname(script), "vegetation_helpers.R"))
source(file.path(dirname(script), "bess_helpers.R"))
source(file.path(dirname(script), "bess_monthly_helpers.R"))
args <- commandArgs(trailingOnly = TRUE)
if ("--help" %in% args) {
  cat("Use --points FILE --years 1982:2022 --drive-folder ID --auth-cache FILE --output-dir DIR\nOptional: --site-roster FILE --source-cache DIR --test --pause-seconds 15 --dry-run\n")
  quit(status = 0)
}
points_path <- require_input_file(cli_value(args, "--points", required = TRUE))
sample_points <- read_vegetation_points(points_path, .05)
years <- vegetation_years(cli_value(args, "--years", required = TRUE), 1982L, 2022L)
mode <- cli_value(args, "--mode", "monthly")
if (mode != "monthly") stop("Only monthly BESS extraction is supported")
selected_dates <- bess_months(years)
folder <- cli_value(args, "--drive-folder", required = TRUE)
auth <- require_input_file(cli_value(args, "--auth-cache", required = TRUE), "existing Drive login")
roster_path <- cli_value(args, "--site-roster")
if (!is.null(roster_path)) roster_path <- require_input_file(roster_path)
roster <- if (!is.null(roster_path)) readRDS(roster_path) else NULL
pause <- cli_integer(args, "--pause-seconds", default = 15L, minimum = 0L)
output <- cli_value(args, "--output-dir", required = TRUE)
if ("--dry-run" %in% args) {
  cat("Checked", length(unique(sample_points$site)), "watersheds and", length(selected_dates), "requested", mode, "files; no downloads started\n")
  quit(status = 0)
}
for (package in c("ncdf4", "googledrive", "jsonlite")) {
  if (!requireNamespace(package, quietly = TRUE)) stop("Install the R package: ", package)
}
job <- vegetation_output(output, repo_root)
code <- c(script, file.path(dirname(script), c("vegetation_helpers.R", "bess_helpers.R", "bess_monthly_helpers.R")), file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))
# record the input files and settings so a resumed run uses the same data
inputs <- c(points_path, roster_path)
record <- vegetation_run_record(
  job, inputs,
  list(mode = mode, years = years, folder = folder, dates = selected_dates, pause_seconds = pause), code
)
run_settings <- list(folder = folder, download_pause_seconds = pause)
options(googledrive_quiet = TRUE, gargle_quiet = TRUE)

# ---- source access and extraction ----

authorize_downloads <- function(path) {
  # reuse an existing permission grant without opening a login or requesting access
  if (!file.exists(path)) stop("the existing Drive login is unavailable; checkpoint retained")
  token <- readRDS(path)
  scope <- "https://www.googleapis.com/auth/drive"
  if (!scope %in% strsplit(token$credentials$scope, " ", fixed = TRUE)[[1L]]) {
    stop("the existing login lacks Drive download access; checkpoint retained")
  }
  invisible(token$refresh())
  if (!scope %in% strsplit(token$credentials$scope, " ", fixed = TRUE)[[1L]]) {
    stop("the refreshed login lacks Drive download access; checkpoint retained")
  }
  googledrive::drive_auth(token = token)
}

source_cache <- cli_value(args, "--source-cache", file.path(job, "monthly-files"))
source_cache <- vegetation_output(source_cache, repo_root)
tryCatch({
  authorize_downloads(auth)
  run_bess_monthly(sample_points, years, run_settings, job, record, roster,
    source_cache = source_cache, test = "--test" %in% args)
}, error = function(error) {
  writeLines(paste("stopped:", conditionMessage(error)), file.path(job, "status.txt"))
  stop(error)
})
