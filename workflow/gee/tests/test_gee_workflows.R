### Load workflow helpers

source("workflow/gee/gee_quota_preflight.R")
source("workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.R")

expect_error <- function(expression) {
  failed <- FALSE
  tryCatch(
    force(expression),
    error = function(error) {
      failed <<- TRUE
    }
  )
  stopifnot(failed)
}

### Quota decisions

monitoring <- list(observed_eecu_hours = 10)
empty_history <- list(
  active_task_count = 0L,
  historical_eecu_hours = list(p90 = NULL, max = NULL)
)
known_history <- list(
  active_task_count = 0L,
  historical_eecu_hours = list(p90 = 0.001, max = 0.002)
)

single_smoke <- evaluate_preflight(
  proposed_task_count = 1L,
  monthly_limit_hours = 1000,
  monitoring = monitoring,
  task_summary = empty_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L
)
stopifnot(isTRUE(single_smoke$approved))
stopifnot(single_smoke$limits$watchdog_cancel_eecu_hours == 2)

capped_smoke <- evaluate_preflight(
  proposed_task_count = 1L,
  monthly_limit_hours = 1000,
  monitoring = monitoring,
  task_summary = empty_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L,
  watchdog_cancel_hours_cap = 0.01
)
stopifnot(capped_smoke$limits$watchdog_cancel_eecu_hours == 0.01)

unknown_batch <- evaluate_preflight(
  proposed_task_count = 2L,
  monthly_limit_hours = 1000,
  monitoring = monitoring,
  task_summary = empty_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L
)
stopifnot(!unknown_batch$approved)

known_batch <- evaluate_preflight(
  proposed_task_count = 5L,
  monthly_limit_hours = 1000,
  monitoring = monitoring,
  task_summary = known_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L
)
stopifnot(isTRUE(known_batch$approved))

active_history <- known_history
active_history$active_task_count <- 1L
active_block <- evaluate_preflight(
  proposed_task_count = 5L,
  monthly_limit_hours = 1000,
  monitoring = monitoring,
  task_summary = active_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L
)
stopifnot(!active_block$approved)

### Receipt lifecycle

issued <- as.POSIXct("2026-08-05 12:00:00", tz = "UTC")
receipt <- build_receipt(
  project = "test-project",
  workflow = "era5_land_annual",
  description_prefix = "era5a6_",
  proposed_task_count = 1L,
  site_count = 10L,
  max_task_area_km2 = 100,
  scale_m = 11100,
  time_slices_per_task = 365L,
  monthly_limit_hours = 1000,
  monitoring = list(
    completed_eecu_hours = 1,
    in_progress_eecu_hours = 1,
    currently_active_task_eecu_hours = 0,
    observed_eecu_hours = 1
  ),
  task_summary = empty_history,
  interval = list(
    start_utc = "2026-08-01T07:00:00Z",
    end_utc = "2026-08-05T12:00:00Z",
    timezone = "America/Los_Angeles"
  ),
  bands_per_slice = 6L,
  workload_fingerprint = paste(rep("a", 64), collapse = ""),
  watchdog_cancel_hours_cap = 0.01,
  now = issued
)
stopifnot(receipt$checksum == canonical_checksum(receipt))

receipt_path <- tempfile(fileext = ".json")
write_json(receipt, receipt_path)
validated <- validate_preflight_receipt(
  receipt_path,
  project = "test-project",
  workflow = "era5_land_annual",
  description_prefix = "era5a6_",
  proposed_task_count = 1L,
  site_count = 10L,
  max_task_area_km2 = 100,
  scale_m = 11100,
  time_slices_per_task = 365L,
  bands_per_slice = 6L,
  workload_fingerprint = paste(rep("a", 64), collapse = ""),
  now = issued + 60
)
stopifnot(validated$checksum == receipt$checksum)
consume_preflight_receipt(
  receipt_path,
  project = "test-project",
  workflow = "era5_land_annual",
  description_prefix = "era5a6_",
  proposed_task_count = 1L,
  site_count = 10L,
  max_task_area_km2 = 100,
  scale_m = 11100,
  time_slices_per_task = 365L,
  bands_per_slice = 6L,
  workload_fingerprint = paste(rep("a", 64), collapse = ""),
  now = issued + 60,
  launch_watchdog = FALSE
)
stopifnot(file.exists(consumed_path(receipt_path)))
expect_error(validate_preflight_receipt(
  receipt_path,
  project = "test-project",
  workflow = "era5_land_annual",
  description_prefix = "era5a6_",
  proposed_task_count = 1L,
  now = issued + 60
))

### GLC validation

exact_rows <- lapply(glc_years, function(year) {
  lapply(glc_classes, function(class_id) {
    list(
      site_id = "test_site",
      Year = year,
      LC_ID = class_id,
      Area_m2 = 1,
      extraction_method = "native_30m_exact",
      sample_count = 0,
      sample_n = 0,
      sample_fraction = 0,
      sample_standard_error = 0,
      requested_sample_n = 0,
      sampling_seed = 0,
      polygon_area_m2 = length(glc_classes),
      native_pixel_estimate = 1,
      effective_pixel_band_time = 1
    )
  })
}) |>
  unlist(recursive = FALSE)
exact_plan <- list(
  asset_id = "projects/test/assets/test_site",
  site = list(site_id = "test_site", area_km2 = 1),
  method = "exact",
  sample_points = 0L
)
exact_qa <- glc_validate_asset_rows(exact_rows, exact_plan)
stopifnot(exact_qa$rows == length(glc_years) * length(glc_classes))
expect_error(glc_validate_asset_rows(exact_rows[-1], exact_plan))

sample_rows <- lapply(glc_years, function(year) {
  lapply(seq_along(glc_classes), function(index) {
    count <- if (index == 1L) 10000 else 0
    fraction <- count / 10000
    list(
      site_id = "test_site",
      Year = year,
      LC_ID = glc_classes[[index]],
      Area_m2 = fraction * length(glc_classes),
      extraction_method = "deterministic_local_equal_area_points_v1",
      sample_count = count,
      sample_n = 10000,
      sample_fraction = fraction,
      sample_standard_error = 0,
      requested_sample_n = 10000,
      sampling_seed = 1,
      polygon_area_m2 = length(glc_classes),
      native_pixel_estimate = 1,
      effective_pixel_band_time = 1
    )
  })
}) |>
  unlist(recursive = FALSE)
sample_plan <- exact_plan
sample_plan$method <- "sample"
sample_plan$sample_points <- 10000L
sample_qa <- glc_validate_asset_rows(sample_rows, sample_plan)
stopifnot(sample_qa$minimum_sample_n == 10000)

### Language boundary

local_python <- c(
  "workflow/gee/gee_quota_preflight.py",
  "workflow/gee/gee_task_watchdog.py",
  "workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.py",
  list.files("workflow/gee/tests", pattern = "\\.py$", full.names = TRUE)
)
stopifnot(!any(file.exists(local_python)))
gee_python <- list.files(
  "workflow/gee",
  pattern = "\\.py$",
  recursive = TRUE,
  full.names = TRUE
)
stopifnot(length(gee_python) == 3L)
stopifnot(all(vapply(gee_python, function(path) {
  any(grepl("^\\s*(import ee|from ee)", readLines(path, warn = FALSE)))
}, logical(1))))

cat("All R GEE workflow tests passed\n")
