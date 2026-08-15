### Load workflow helpers

source("workflow/gee/gee_quota_preflight.R")
source("workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.R")
source("workflow/gee/land_cover/consolidate_safe_glc_major_land_exports.R")

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

custom_stop_approved <- evaluate_preflight(
  proposed_task_count = 1L,
  monthly_limit_hours = 1000,
  monitoring = list(observed_eecu_hours = 799),
  task_summary = known_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L,
  monthly_stop_hours = 800
)
stopifnot(isTRUE(custom_stop_approved$approved))
stopifnot(custom_stop_approved$limits$monthly_stop_eecu_hours == 800)

custom_stop_blocked <- evaluate_preflight(
  proposed_task_count = 1L,
  monthly_limit_hours = 1000,
  monitoring = list(observed_eecu_hours = 800),
  task_summary = known_history,
  max_task_area_km2 = 100,
  scale_m = 1000,
  time_slices_per_task = 1L,
  monthly_stop_hours = 800
)
stopifnot(!custom_stop_blocked$approved)

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
stopifnot(exact_qa$maximum_area_closure_relative_error == 0)
expect_error(glc_validate_asset_rows(exact_rows[-1], exact_plan))

boundary_exact_rows <- exact_rows
boundary_exact_rows[[1]]$Area_m2 <-
  boundary_exact_rows[[1]]$Area_m2 + length(glc_classes) * 0.005
boundary_exact_qa <- glc_validate_asset_rows(boundary_exact_rows, exact_plan)
stopifnot(isTRUE(all.equal(
  boundary_exact_qa$maximum_area_closure_relative_error,
  0.005,
  tolerance = 1e-12
)))

invalid_exact_rows <- exact_rows
invalid_exact_rows[[1]]$Area_m2 <-
  invalid_exact_rows[[1]]$Area_m2 + length(glc_classes) * 0.02
expect_error(glc_validate_asset_rows(invalid_exact_rows, exact_plan))

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
stopifnot(sample_qa$maximum_area_closure_relative_error == 0)

strict_sample_plan <- sample_plan
strict_sample_plan$sample_points <- 10200L
expect_error(glc_validate_asset_rows(sample_rows, strict_sample_plan))

relaxed_sample_plan <- strict_sample_plan
relaxed_sample_plan$minimum_sample_fraction <- 0.98
relaxed_sample_qa <- glc_validate_asset_rows(sample_rows, relaxed_sample_plan)
stopifnot(relaxed_sample_qa$minimum_sample_n == 10000)

planned_sample <- glc_plan_tasks(
  sites = list(list(site_id = "test_site", area_km2 = 1)),
  method = "sample",
  sample_points = 10000L,
  exact_max_work = 260000,
  run_label = "test",
  output_folder = "projects/test/assets/test",
  minimum_sample_fraction = 0.95
)
stopifnot(planned_sample[[1]]$minimum_sample_fraction == 0.95)
expect_error(glc_plan_tasks(
  sites = list(list(site_id = "test_site", area_km2 = 1)),
  method = "sample",
  sample_points = 10000L,
  exact_max_work = 260000,
  run_label = "test",
  output_folder = "projects/test/assets/test",
  minimum_sample_fraction = 0
))

output_args <- glc_parse_args(c("--output-folder", "remote-assets"))
default_output <- glc_output_path(
  output_args,
  "local-output",
  "combined",
  "test"
)
stopifnot(default_output == "local-output/combined_test.csv")
custom_output_args <- glc_parse_args(c("--output", "chosen.csv"))
stopifnot(
  glc_output_path(custom_output_args, "unused", "unused", "unused") ==
    "chosen.csv"
)

### Major-land validation

major_plan <- list(
  asset_id = "projects/test/assets/test_major_land",
  site = list(site_id = "test_site", area_km2 = 1),
  method = "exact",
  sample_points = 0L
)
major_row <- normalize_major_row(list(
  site_id = "test_site",
  major_land = "Forest",
  major_land_mean_fraction = 0.6,
  major_land_tie_count = 1,
  major_land_tie_flag = "no",
  total_temporal_weight = 123,
  valid_temporal_weight = 123,
  extraction_method = "native_30m_exact"
))
major_qa <- validate_major_rows(list(major_row), major_plan)
stopifnot(identical(major_qa$major_land, "Forest"))
stopifnot(major_qa$valid_temporal_weight == 123)

tied_rows <- lapply(c("Forest", "Cropland"), function(major_land) {
  row <- major_row
  row$major_land <- major_land
  row$major_land_mean_fraction <- 0.4
  row$major_land_tie_count <- 2L
  row$major_land_tie_flag <- "yes"
  row
})
tied_qa <- validate_major_rows(tied_rows, major_plan)
stopifnot(tied_qa$rows == 2L)

invalid_major_row <- major_row
invalid_major_row$major_land_mean_fraction <- 1.1
expect_error(validate_major_rows(list(invalid_major_row), major_plan))

### Shared watersheds

shared_source <- data.frame(
  site_id = rep("krr__s_65bc__s65b", 2),
  LTER = rep("KRR", 2),
  Stream_Name = rep("S65B", 2),
  Shapefile_Name = rep("s_65bc", 2),
  Year = c(1985L, 1990L),
  LC_ID = c(50L, 10L),
  Area_m2 = c(750000, 250000),
  stringsAsFactors = FALSE
)
shared_result <- add_shared_watershed_aliases(
  shared_source,
  glc_default_alias_file
)
source_rows <- shared_result$Stream_Name == "S65B"
alias_rows <- shared_result$Stream_Name == "S65C"
stopifnot(sum(source_rows) == 2L)
stopifnot(sum(alias_rows) == 2L)
stopifnot(all(!shared_result$watershed_alias_flag[source_rows]))
stopifnot(all(shared_result$watershed_alias_flag[alias_rows]))
stopifnot(all(
  shared_result$site_id[alias_rows] == "krr__s_65bc__s65c"
))
stopifnot(isTRUE(all.equal(
  shared_result$Area_m2[source_rows],
  shared_result$Area_m2[alias_rows],
  check.attributes = FALSE
)))

existing_alias <- rbind(
  shared_source,
  transform(
    shared_source,
    site_id = "old_alias",
    Stream_Name = "S65C",
    Area_m2 = 0
  )
)
replaced_alias <- add_shared_watershed_aliases(
  existing_alias,
  glc_default_alias_file
)
replaced_rows <- replaced_alias$Stream_Name == "S65C"
stopifnot(sum(replaced_rows) == 2L)
stopifnot(all(replaced_alias$watershed_alias_flag[replaced_rows]))
stopifnot(all(
  replaced_alias$site_id[replaced_rows] == "krr__s_65bc__s65c"
))
stopifnot(isTRUE(all.equal(
  replaced_alias$Area_m2[replaced_rows],
  shared_source$Area_m2,
  check.attributes = FALSE
)))

### Major-land calculation settings

python_check <- paste(
  "from pathlib import Path",
  "import sys",
  paste0(
    "sys.path.insert(0, str(Path.cwd() / ",
    "'workflow/gee/land_cover'))"
  ),
  "import run_safe_glc_fcs30d_exports as annual",
  "import run_safe_glc_major_land_exports as major",
  "assert sum(major.YEAR_WEIGHTS.values()) == 123",
  paste0(
    "assert set(major.MAPPED_CLASS_IDS) | ",
    "set(major.NON_CANDIDATE_CLASS_IDS) == set(annual.GLC_CLASSES)"
  ),
  paste0(
    "assert not set(major.MAPPED_CLASS_IDS) & ",
    "set(major.NON_CANDIDATE_CLASS_IDS)"
  ),
  paste0(
    "assert annual.workload_fingerprint([], 'annual_classes') != ",
    "annual.workload_fingerprint([], 'major_land')"
  ),
  sep = "; "
)
python_status <- system2(
  "python3",
  c("-c", shQuote(python_check)),
  stdout = TRUE,
  stderr = TRUE
)
stopifnot(is.null(attr(python_status, "status")))

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
expected_gee_python <- c(
  "workflow/gee/era5_land/run_safe_era5_land_exports.py",
  "workflow/gee/human_impacts/run_missing_site_exports.py",
  "workflow/gee/land_cover/run_safe_glc_fcs30d_exports.py",
  "workflow/gee/land_cover/run_safe_glc_major_land_exports.py"
)
stopifnot(setequal(gee_python, expected_gee_python))
direct_gee_python <- setdiff(
  gee_python,
  "workflow/gee/land_cover/run_safe_glc_major_land_exports.py"
)
stopifnot(all(vapply(direct_gee_python, function(path) {
  any(grepl("^\\s*(import ee|from ee)", readLines(path, warn = FALSE)))
}, logical(1))))
major_python <- readLines(
  "workflow/gee/land_cover/run_safe_glc_major_land_exports.py",
  warn = FALSE
)
stopifnot(any(grepl(
  "^import run_safe_glc_fcs30d_exports as glc$",
  major_python
)))

cat("All R GEE workflow tests passed\n")
