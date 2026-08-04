### Setup

gee_script_path <- function() {
  source_files <- vapply(sys.frames(), function(frame) {
    if (is.null(frame$ofile)) "" else as.character(frame$ofile)
  }, character(1))
  source_files <- source_files[nzchar(source_files)]
  if (length(source_files)) {
    return(normalizePath(tail(source_files, 1)))
  }
  file_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(file_arg)) {
    return(normalizePath(sub("^--file=", "", file_arg[[1]])))
  }
  normalizePath("workflow/gee/gee_quota_preflight.R")
}

source(file.path(dirname(gee_script_path()), "gee_api.R"))

default_project <- "silica-synthesis"
default_monthly_limit_hours <- 1000
monthly_stop_fraction <- 0.70
max_batch_fraction <- 0.10
max_single_task_fraction <- 0.025
absolute_max_batch_hours <- 100
absolute_max_single_task_hours <- 25
unknown_workflow_cancel_hours <- 2
max_active_tasks <- 5L
max_tasks_per_launch <- 5L
max_effective_pixels_per_task <- 100000000
receipt_valid_minutes <- 15
active_states <- c(
  "READY",
  "RUNNING",
  "PENDING",
  "CANCEL_REQUESTED",
  "CANCELLING"
)
success_states <- c("COMPLETED", "SUCCEEDED")
completed_usage_metric <- "earthengine.googleapis.com/project/cpu/usage_time"
in_progress_usage_metric <- paste0(
  "earthengine.googleapis.com/project/cpu/",
  "in_progress_usage_time"
)

### General helpers

iso_utc <- function(value = Sys.time()) {
  format(as.POSIXct(value, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

month_start_utc <- function(now, timezone_name) {
  local <- as.POSIXlt(now, tz = timezone_name)
  start_text <- sprintf(
    "%04d-%02d-01 00:00:00",
    local$year + 1900,
    local$mon + 1
  )
  as.POSIXct(start_text, tz = timezone_name)
}

nearest_rank <- function(values, probability) {
  if (!length(values)) {
    return(NA_real_)
  }
  ordered <- sort(values)
  ordered[[max(1L, ceiling(probability * length(ordered)))]]
}

sort_json_names <- function(value) {
  if (!is.list(value)) {
    return(value)
  }
  if (!is.null(names(value))) {
    value <- value[order(names(value))]
  }
  lapply(value, sort_json_names)
}

canonical_checksum <- function(payload) {
  payload$checksum <- NULL
  encoded <- jsonlite::toJSON(
    sort_json_names(payload),
    auto_unbox = TRUE,
    null = "null",
    na = "null",
    digits = NA,
    pretty = FALSE
  )
  digest::digest(encoded, algo = "sha256", serialize = FALSE)
}

write_json <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  text <- jsonlite::toJSON(
    value,
    auto_unbox = TRUE,
    null = "null",
    na = "null",
    digits = NA,
    pretty = TRUE
  )
  writeLines(c(text, ""), path, useBytes = TRUE)
}

as_number_or_null <- function(value) {
  if (is.null(value) || identical(value, "")) NULL else as.numeric(value)
}

as_integer_or_null <- function(value) {
  if (is.null(value) || identical(value, "")) NULL else as.integer(value)
}

### Task summaries

summarize_operations <- function(operations, description_prefix) {
  states <- vapply(operations, gee_operation_state, character(1))
  descriptions <- vapply(
    operations,
    gee_operation_description,
    character(1)
  )
  eecu_seconds <- vapply(
    operations,
    gee_operation_eecu_seconds,
    numeric(1)
  )
  active <- states %in% active_states
  matching <- startsWith(descriptions, description_prefix)
  successful_hours <- eecu_seconds[
    matching & states %in% success_states & eecu_seconds > 0
  ] / 3600
  matching_hours <- eecu_seconds[matching & eecu_seconds > 0] / 3600
  active_counts <- table(states[active])
  expensive_index <- order(eecu_seconds, decreasing = TRUE)
  expensive_index <- expensive_index[
    matching[expensive_index] & eecu_seconds[expensive_index] > 0
  ]
  expensive_index <- head(expensive_index, 10)
  expensive <- lapply(expensive_index, function(index) {
    list(
      description = descriptions[[index]],
      state = states[[index]],
      eecu_hours = round(eecu_seconds[[index]] / 3600, 3)
    )
  })
  list(
    active_task_count = sum(active),
    active_task_eecu_hours = round(sum(eecu_seconds[active]) / 3600, 6),
    active_state_counts = as.list(as.integer(active_counts)) |>
      stats::setNames(names(active_counts)),
    matching_task_count = sum(matching),
    matching_tasks_with_usage = length(matching_hours),
    successful_tasks_with_usage = length(successful_hours),
    historical_eecu_hours = list(
      median = if (length(successful_hours)) {
        round(stats::median(successful_hours), 3)
      } else {
        NULL
      },
      p90 = if (length(successful_hours)) {
        round(nearest_rank(successful_hours, 0.90), 3)
      } else {
        NULL
      },
      max = if (length(matching_hours)) {
        round(max(matching_hours), 3)
      } else {
        NULL
      }
    ),
    highest_cost_matching_tasks = expensive
  )
}

fetch_live_inputs <- function(
  project,
  description_prefix,
  timezone_name,
  now = Sys.time()
) {
  token <- gee_access_token()
  start <- month_start_utc(now, timezone_name)
  start_utc <- iso_utc(start)
  end_utc <- iso_utc(now)
  completed_seconds <- gee_monitoring_seconds(
    project,
    completed_usage_metric,
    start_utc,
    end_utc,
    token
  )
  in_progress_seconds <- gee_monitoring_seconds(
    project,
    in_progress_usage_metric,
    start_utc,
    end_utc,
    token
  )
  task_summary <- summarize_operations(
    gee_list_operations(project, token),
    description_prefix
  )
  monitoring <- list(
    completed_eecu_hours = completed_seconds / 3600,
    in_progress_eecu_hours = in_progress_seconds / 3600,
    currently_active_task_eecu_hours =
      task_summary$active_task_eecu_hours,
    observed_eecu_hours = max(completed_seconds, in_progress_seconds) / 3600
  )
  list(
    monitoring = monitoring,
    task_summary = task_summary,
    interval = list(
      start_utc = start_utc,
      end_utc = end_utc,
      timezone = timezone_name
    )
  )
}

### Quota decision

evaluate_preflight <- function(
  proposed_task_count,
  monthly_limit_hours,
  monitoring,
  task_summary,
  max_task_area_km2 = NULL,
  scale_m = NULL,
  time_slices_per_task = 1L,
  bands_per_slice = 1L,
  effective_pixels_per_task = NULL,
  watchdog_cancel_hours_cap = NULL
) {
  blockers <- character()
  warnings <- character()
  observed_hours <- as.numeric(monitoring$observed_eecu_hours)
  stop_hours <- monthly_limit_hours * monthly_stop_fraction
  max_batch_hours <- min(
    monthly_limit_hours * max_batch_fraction,
    absolute_max_batch_hours
  )
  max_single_task_hours <- min(
    monthly_limit_hours * max_single_task_fraction,
    absolute_max_single_task_hours
  )
  active_count <- as.integer(task_summary$active_task_count)
  p90_hours <- task_summary$historical_eecu_hours$p90
  max_hours <- task_summary$historical_eecu_hours$max
  projected_hours <- if (is.null(p90_hours)) {
    NULL
  } else {
    as.numeric(p90_hours) * proposed_task_count
  }
  effective_pixels <- effective_pixels_per_task
  estimate_source <- if (is.null(effective_pixels)) NULL else "launcher_override"
  if (
    is.null(effective_pixels) &&
      !is.null(max_task_area_km2) &&
      !is.null(scale_m)
  ) {
    effective_pixels <- max_task_area_km2 * 1000000 /
      (scale_m * scale_m) * time_slices_per_task * bands_per_slice
    estimate_source <- "area_scale_time_bands"
  }

  if (observed_hours >= stop_hours) {
    blockers <- c(
      blockers,
      sprintf(
        paste0(
          "Month-to-date usage is %.1f EECU-h, at or above the ",
          "%.1f EECU-h safety stop"
        ),
        observed_hours,
        stop_hours
      )
    )
  } else if (observed_hours >= monthly_limit_hours * 0.50) {
    warnings <- c(
      warnings,
      sprintf(
        "Month-to-date usage has reached %.1f EECU-h",
        observed_hours
      )
    )
  }
  if (proposed_task_count > max_tasks_per_launch) {
    blockers <- c(
      blockers,
      sprintf(
        "The launch proposes %d tasks; the hard limit is %d",
        proposed_task_count,
        max_tasks_per_launch
      )
    )
  }
  if (active_count + proposed_task_count > max_active_tasks) {
    blockers <- c(
      blockers,
      sprintf(
        paste0(
          "%d Earth Engine tasks are active and %d more are proposed; ",
          "the combined limit is %d"
        ),
        active_count,
        proposed_task_count,
        max_active_tasks
      )
    )
  }
  if (proposed_task_count < 1) {
    blockers <- c(blockers, "The proposed task count must be at least one")
  }
  if (is.null(p90_hours) && proposed_task_count > 1) {
    blockers <- c(
      blockers,
      paste0(
        "This task prefix has no measured EECU history; launch exactly one ",
        "smoke-test task first"
      )
    )
  } else if (!is.null(projected_hours) && projected_hours > max_batch_hours) {
    blockers <- c(
      blockers,
      sprintf(
        "Historical p90 cost projects %.1f EECU-h for this batch",
        projected_hours
      )
    )
  }
  if (
    !is.null(projected_hours) &&
      observed_hours + projected_hours > stop_hours
  ) {
    blockers <- c(
      blockers,
      "Month-to-date usage plus projected usage exceeds the safety stop"
    )
  }
  if (!is.null(max_hours) && as.numeric(max_hours) > max_single_task_hours) {
    blockers <- c(
      blockers,
      "A matching task exceeds the single-task EECU limit"
    )
  }
  if (
    !is.null(effective_pixels) &&
      effective_pixels > max_effective_pixels_per_task
  ) {
    blockers <- c(
      blockers,
      sprintf(
        paste0(
          "The largest task represents about %.0f pixel-band-time ",
          "evaluations, above the %d limit"
        ),
        effective_pixels,
        max_effective_pixels_per_task
      )
    )
  }
  if (is.null(effective_pixels)) {
    warnings <- c(
      warnings,
      "No geometry-based work estimate was available"
    )
  }

  watchdog_cancel_hours <- if (is.null(p90_hours)) {
    min(unknown_workflow_cancel_hours, max_single_task_hours)
  } else {
    min(
      max_single_task_hours,
      max(unknown_workflow_cancel_hours, as.numeric(p90_hours) * 3)
    )
  }
  if (!is.null(watchdog_cancel_hours_cap)) {
    if (watchdog_cancel_hours_cap <= 0) {
      stop("The watchdog cancellation cap must be positive")
    }
    watchdog_cancel_hours <- min(
      watchdog_cancel_hours,
      watchdog_cancel_hours_cap
    )
  }

  list(
    approved = !length(blockers),
    blockers = blockers,
    warnings = warnings,
    limits = list(
      monthly_limit_eecu_hours = monthly_limit_hours,
      monthly_stop_eecu_hours = stop_hours,
      max_batch_eecu_hours = max_batch_hours,
      max_single_task_eecu_hours = max_single_task_hours,
      max_active_tasks = max_active_tasks,
      max_tasks_per_launch = max_tasks_per_launch,
      max_effective_pixels_per_task = max_effective_pixels_per_task,
      watchdog_cancel_eecu_hours = watchdog_cancel_hours
    ),
    estimates = list(
      historical_p90_projected_batch_eecu_hours = if (
        is.null(projected_hours)
      ) NULL else round(projected_hours, 3),
      effective_pixels_per_largest_task = if (
        is.null(effective_pixels)
      ) NULL else round(effective_pixels),
      effective_pixel_estimate_source = estimate_source
    )
  )
}

### Receipt lifecycle

build_receipt <- function(
  project,
  workflow,
  description_prefix,
  proposed_task_count,
  site_count,
  max_task_area_km2,
  scale_m,
  time_slices_per_task,
  monthly_limit_hours,
  monitoring,
  task_summary,
  interval,
  bands_per_slice = 1L,
  effective_pixels_per_task = NULL,
  workload_fingerprint = NULL,
  watchdog_cancel_hours_cap = NULL,
  now = Sys.time()
) {
  decision <- evaluate_preflight(
    proposed_task_count,
    monthly_limit_hours,
    monitoring,
    task_summary,
    max_task_area_km2,
    scale_m,
    time_slices_per_task,
    bands_per_slice,
    effective_pixels_per_task,
    watchdog_cancel_hours_cap
  )
  receipt <- list(
    schema_version = 3L,
    project = project,
    workflow = workflow,
    description_prefix = description_prefix,
    proposed_task_count = proposed_task_count,
    site_count = site_count,
    max_task_area_km2 = max_task_area_km2,
    scale_m = scale_m,
    time_slices_per_task = time_slices_per_task,
    bands_per_slice = bands_per_slice,
    effective_pixels_per_task = effective_pixels_per_task,
    workload_fingerprint = workload_fingerprint,
    watchdog_cancel_eecu_hours_cap = watchdog_cancel_hours_cap,
    issued_at_utc = iso_utc(now),
    expires_at_utc = iso_utc(now + receipt_valid_minutes * 60),
    monitoring_interval = interval,
    monitoring = lapply(monitoring, function(value) round(as.numeric(value), 6)),
    task_summary = task_summary,
    decision = decision
  )
  receipt$checksum <- canonical_checksum(receipt)
  receipt
}

consumed_path <- function(receipt_path) {
  paste0(receipt_path, ".consumed.json")
}

values_match <- function(actual, expected) {
  if (is.null(expected)) {
    return(TRUE)
  }
  if (is.numeric(expected)) {
    return(
      !is.null(actual) &&
        isTRUE(all.equal(
          as.numeric(actual),
          as.numeric(expected),
          tolerance = 1e-9
        ))
    )
  }
  identical(as.character(actual), as.character(expected))
}

validate_preflight_receipt <- function(
  receipt_path,
  project,
  workflow,
  description_prefix,
  proposed_task_count,
  site_count = NULL,
  max_task_area_km2 = NULL,
  scale_m = NULL,
  time_slices_per_task = NULL,
  bands_per_slice = NULL,
  effective_pixels_per_task = NULL,
  workload_fingerprint = NULL,
  now = Sys.time()
) {
  if (!file.exists(receipt_path)) {
    stop("Missing GEE preflight receipt: ", receipt_path)
  }
  if (file.exists(consumed_path(receipt_path))) {
    stop("GEE preflight receipt was already consumed")
  }
  receipt <- jsonlite::fromJSON(receipt_path, simplifyVector = FALSE)
  if (!identical(receipt$checksum, canonical_checksum(receipt))) {
    stop("GEE preflight receipt checksum is invalid")
  }
  if (!identical(as.integer(receipt$schema_version), 3L)) {
    stop("GEE preflight receipt uses an obsolete safety schema")
  }
  if (!isTRUE(receipt$decision$approved)) {
    stop("GEE preflight did not approve this launch")
  }
  expected <- list(
    project = project,
    workflow = workflow,
    description_prefix = description_prefix,
    proposed_task_count = proposed_task_count,
    site_count = site_count,
    max_task_area_km2 = max_task_area_km2,
    scale_m = scale_m,
    time_slices_per_task = time_slices_per_task,
    bands_per_slice = bands_per_slice,
    effective_pixels_per_task = effective_pixels_per_task,
    workload_fingerprint = workload_fingerprint
  )
  mismatches <- names(expected)[!vapply(
    names(expected),
    function(name) values_match(receipt[[name]], expected[[name]]),
    logical(1)
  )]
  if (length(mismatches)) {
    stop(
      "GEE preflight receipt does not match: ",
      paste(mismatches, collapse = ", ")
    )
  }
  expires <- as.POSIXct(
    receipt$expires_at_utc,
    format = "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )
  if (now >= expires) {
    stop("GEE preflight receipt expired at ", receipt$expires_at_utc)
  }
  receipt
}

start_watchdog <- function(
  receipt_path,
  receipt,
  project,
  description_prefix,
  wait_for_first_task_seconds = 300L
) {
  watchdog_script <- file.path(dirname(gee_script_path()), "gee_task_watchdog.R")
  watchdog_log <- paste0(receipt_path, ".watchdog.jsonl")
  cancel_hours <- as.numeric(
    receipt$decision$limits$watchdog_cancel_eecu_hours %||%
      unknown_workflow_cancel_hours
  )
  warning_hours <- min(10, cancel_hours / 2)
  args <- c(
    watchdog_script,
    "--project", project,
    "--description-prefix", description_prefix,
    "--warning-eecu-hours", format(warning_hours, scientific = FALSE),
    "--cancel-eecu-hours", format(cancel_hours, scientific = FALSE),
    "--wait-for-first-task-seconds", as.character(wait_for_first_task_seconds),
    "--log", watchdog_log
  )
  system2(
    "Rscript",
    args,
    wait = FALSE,
    stdout = FALSE,
    stderr = FALSE
  )
  watchdog_log
}

consume_preflight_receipt <- function(
  receipt_path,
  project,
  workflow,
  description_prefix,
  proposed_task_count,
  site_count = NULL,
  max_task_area_km2 = NULL,
  scale_m = NULL,
  time_slices_per_task = NULL,
  bands_per_slice = NULL,
  effective_pixels_per_task = NULL,
  workload_fingerprint = NULL,
  now = Sys.time(),
  launch_watchdog = TRUE
) {
  receipt <- validate_preflight_receipt(
    receipt_path,
    project,
    workflow,
    description_prefix,
    proposed_task_count,
    site_count,
    max_task_area_km2,
    scale_m,
    time_slices_per_task,
    bands_per_slice,
    effective_pixels_per_task,
    workload_fingerprint,
    now
  )
  marker <- list(
    consumed_at_utc = iso_utc(now),
    receipt = receipt_path,
    checksum = receipt$checksum,
    project = project,
    workflow = workflow,
    description_prefix = description_prefix,
    proposed_task_count = proposed_task_count
  )
  if (launch_watchdog) {
    marker$watchdog_log <- start_watchdog(
      receipt_path,
      receipt,
      project,
      description_prefix
    )
  }
  write_json(marker, consumed_path(receipt_path))
  invisible(receipt)
}

### Command line

parse_cli_args <- function(args) {
  values <- list()
  index <- 1L
  while (index <= length(args)) {
    token <- args[[index]]
    if (!startsWith(token, "--")) {
      stop("Unexpected argument: ", token)
    }
    key <- gsub("-", "_", substring(token, 3), fixed = TRUE)
    if (key %in% c("consume")) {
      values[[key]] <- TRUE
      index <- index + 1L
      next
    }
    if (index == length(args) || startsWith(args[[index + 1L]], "--")) {
      stop("Missing value for ", token)
    }
    values[[key]] <- args[[index + 1L]]
    index <- index + 2L
  }
  values
}

required_arg <- function(args, name) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) {
    stop("Missing required argument --", gsub("_", "-", name))
  }
  value
}

print_report <- function(receipt, receipt_path) {
  decision <- receipt$decision
  status <- if (isTRUE(decision$approved)) "APPROVED" else "BLOCKED"
  cat("GEE QUOTA PREFLIGHT: ", status, "\n", sep = "")
  cat(
    sprintf(
      paste0(
        "Month-to-date EECU: %.1f h ",
        "(completed %.1f h; in-progress %.1f h)\n"
      ),
      receipt$monitoring$observed_eecu_hours,
      receipt$monitoring$completed_eecu_hours,
      receipt$monitoring$in_progress_eecu_hours
    )
  )
  cat(
    "Existing active tasks: ",
    receipt$task_summary$active_task_count,
    "\n",
    sep = ""
  )
  if (length(decision$warnings)) {
    cat("Warnings:\n", paste0("  - ", decision$warnings, collapse = "\n"), "\n")
  }
  if (length(decision$blockers)) {
    cat("Blockers:\n", paste0("  - ", decision$blockers, collapse = "\n"), "\n")
  }
  cat("Receipt: ", receipt_path, "\n", sep = "")
  cat("Receipt expires: ", receipt$expires_at_utc, " and can be used once\n", sep = "")
}

preflight_main <- function() {
  args <- parse_cli_args(commandArgs(trailingOnly = TRUE))
  project <- args$project %||% default_project
  receipt_path <- required_arg(args, "receipt")
  workflow <- required_arg(args, "workflow")
  description_prefix <- required_arg(args, "description_prefix")
  proposed_task_count <- as.integer(required_arg(args, "proposed_task_count"))
  site_count <- as_integer_or_null(args$site_count)
  max_task_area_km2 <- as_number_or_null(args$max_task_area_km2)
  scale_m <- as_number_or_null(args$scale_m)
  time_slices_per_task <- as.integer(args$time_slices_per_task %||% 1)
  bands_per_slice <- as.integer(args$bands_per_slice %||% 1)
  effective_pixels_per_task <- as_number_or_null(
    args$effective_pixels_per_task
  )
  workload_fingerprint <- args$workload_fingerprint %||% NULL

  if (isTRUE(args$consume)) {
    consume_preflight_receipt(
      receipt_path,
      project,
      workflow,
      description_prefix,
      proposed_task_count,
      site_count,
      max_task_area_km2,
      scale_m,
      time_slices_per_task,
      bands_per_slice,
      effective_pixels_per_task,
      workload_fingerprint
    )
    cat("Consumed GEE preflight receipt: ", receipt_path, "\n", sep = "")
    return(invisible(NULL))
  }

  if (!grepl("^[a-z0-9][a-z0-9_-]*$", workflow)) {
    stop("Workflow must contain only lowercase letters, numbers, underscores, and hyphens")
  }
  monthly_limit_hours <- as.numeric(
    args$monthly_limit_hours %||% default_monthly_limit_hours
  )
  watchdog_cap <- as_number_or_null(args$watchdog_cancel_eecu_hours)
  timezone_name <- args$timezone %||% "America/Los_Angeles"
  live <- fetch_live_inputs(project, description_prefix, timezone_name)
  receipt <- build_receipt(
    project,
    workflow,
    description_prefix,
    proposed_task_count,
    site_count,
    max_task_area_km2,
    scale_m,
    time_slices_per_task,
    monthly_limit_hours,
    live$monitoring,
    live$task_summary,
    live$interval,
    bands_per_slice,
    effective_pixels_per_task,
    workload_fingerprint,
    watchdog_cap
  )
  write_json(receipt, receipt_path)
  print_report(receipt, receipt_path)
  if (!isTRUE(receipt$decision$approved)) {
    stop("Earth Engine quota preflight blocked this launch")
  }
}

if (sys.nframe() == 0L) {
  tryCatch(
    preflight_main(),
    error = function(error) {
      message("GEE QUOTA PREFLIGHT ERROR: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
