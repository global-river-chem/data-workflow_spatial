suppressPackageStartupMessages(library(jsonlite))

source(file.path("workflow", "lib", "workflow_helpers.R"))
repo_root <- silica_find_repo_root()
setwd(repo_root)
source(file.path("workflow", "gee", "gee_api.R"))

main <- function() {

### Settings

args <- commandArgs(trailingOnly = TRUE)
mode_args <- intersect(args, c("--self-test", "--dry-run", "--smoke", "--bulk"))
if (length(mode_args) > 1L) {
  stop("Use only one run mode", call. = FALSE)
}
mode <- if (length(mode_args)) substring(mode_args[[1L]], 3L) else "dry-run"
value_options <- c("--python", "--input-root", "--output-folder", "--project")
recognized <- mode_args
for (option in value_options) {
  position <- which(args == option)
  if (length(position)) {
    if (any(position == length(args))) stop("Option requires a value: ", option, call. = FALSE)
    recognized <- c(recognized, option, args[position + 1L])
  }
}
unknown <- setdiff(args, recognized)
if (length(unknown)) stop("Unexpected argument: ", unknown[[1L]], call. = FALSE)

python <- cli_value(args, "--python", Sys.getenv(
  "SISYN_GEE_PYTHON", unset = Sys.which("python3")
))
input_root <- cli_value(args, "--input-root", Sys.getenv(
  "SISYN_ERA5_RELEASE_INPUT_ROOT", unset = ""
))
launcher <- file.path(
  "workflow",
  "gee",
  "era5_land",
  "run_safe_era5_land_exports.py"
)
output_folder <- cli_value(args, "--output-folder", paste0(
  "projects/silica-synthesis/assets/", "era5_land_release3_20260815_remaining_85"
))
project <- cli_value(args, "--project", "silica-synthesis")
run_label <- "release3_20260815_remaining_85"
monthly_stop_hours <- 800
watchdog_hours <- 0.005
active_states <- c(
  "READY", "RUNNING", "PENDING", "CANCEL_REQUESTED", "CANCELLING"
)
failure_states <- c("FAILED", "CANCELLED")
expected_payload_names <- sprintf("era5_remaining_01_part_%02d", seq_len(6L))
expected_md5 <- c(
  "29bd80d4ec659d832cb9b530cd7ff720",
  "238dc0192cea147381b2cbb4c6f8df47",
  "3d15f4dbb7622b8488a6114335d2323f",
  "59419e690cb972c4fbd04fded57bb782",
  "7ae8211a890d43221ed772f1c13daca6",
  "02d52c30ece550595065efcfe49b88c3",
  "224972c0debb60b76d0e2bfee68e9de6"
)

expected_assets <- as.vector(vapply(expected_payload_names, function(payload) {
  paste0(
    output_folder,
    "/era5a6_",
    run_label,
    "_",
    payload,
    "_",
    2000:2025
  )
}, character(26L)))
smoke_asset <- paste0(
  output_folder,
  "/era5a6_",
  run_label,
  "_era5_remaining_01_part_01_2000"
)

### Retained inputs

validate_inputs <- function(root) {
  if (!nzchar(root) || !dir.exists(root)) stop(
    "Pass --input-root PATH (or set SISYN_ERA5_RELEASE_INPUT_ROOT) to the retained six-part ERA5 inputs",
    call. = FALSE
  )
  payload_list <- file.path(root, "payload_manifest.csv")
  site_file <- file.path(root, "site_inventory.csv")
  payloads <- read.csv(payload_list, stringsAsFactors = FALSE, check.names = FALSE)
  require_columns(payloads, c("payload", "path", "sites", "polygon_area_km2_sum"),
                  "ERA5 retained payload list")
  payload_files <- file.path(dirname(payload_list), payloads$path)
  input_files <- c(payload_list, payload_files)
  if (!identical(as.character(payloads$payload), expected_payload_names) ||
      nrow(payloads) != 6L || sum(as.integer(payloads$sites)) != 85L ||
      any(!file.exists(c(input_files, site_file))) ||
      !identical(unname(tools::md5sum(input_files)), expected_md5)) {
    stop("The exact retained six-part ERA5 inputs changed", call. = FALSE)
  }
  site_ids <- read.csv(site_file, stringsAsFactors = FALSE)$site_id
  payload_ids <- unlist(lapply(payload_files, function(path) {
    value <- fromJSON(path, simplifyVector = FALSE)
    vapply(value$features, function(feature) {
      as.character(feature$properties$site_id)
    }, character(1L))
  }), use.names = FALSE)
  if (length(site_ids) != 85L || anyDuplicated(site_ids) ||
      length(payload_ids) != 85L || anyDuplicated(payload_ids) ||
      !setequal(site_ids, payload_ids)) {
    stop("The retained ERA5 inputs do not cover the exact 85-site set")
  }
  list(payload_list = payload_list, site_file = site_file)
}

if (mode == "self-test" && !nzchar(input_root)) {
  stopifnot(length(expected_assets) == 156L)
  cat("Release-three remaining-85 ERA5 runner self-test passed without external inputs\n")
  return(invisible(TRUE))
}
inputs <- validate_inputs(input_root)
payload_list <- inputs$payload_list
site_file <- inputs$site_file
if (mode == "self-test") {
  stopifnot(length(expected_assets) == 156L)
  cat("Release-three remaining-85 ERA5 runner self-test passed with retained inputs\n")
  return(invisible(TRUE))
}
if (!nzchar(python) || !file.exists(python)) {
  stop("Set --python to an Earth Engine Python environment", call. = FALSE)
}

### Launch helpers

run_capture <- function(command, command_args) {
  output <- system2(command, command_args, stdout = TRUE, stderr = TRUE)
  cat(paste(output, collapse = "\n"), "\n")
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop("Command failed with status ", status, call. = FALSE)
  }
  output
}

read_plan_counts <- function(output) {
  if (any(grepl("No missing tasks remain", output, fixed = TRUE))) {
    return(c(missing = 0L, eligible = 0L))
  }
  line <- output[grepl("Missing tasks:", output, fixed = TRUE)]
  values <- regmatches(
    line,
    regexec(
      "Missing tasks: ([0-9]+); tasks eligible in this launch: ([0-9]+)",
      line
    )
  )[[1L]]
  if (length(line) != 1L || length(values) != 3L) {
    stop("Could not read ERA5 task counts", call. = FALSE)
  }
  c(missing = as.integer(values[[2L]]), eligible = as.integer(values[[3L]]))
}

set_cli_value <- function(values, flag, value) {
  index <- match(flag, values)
  if (is.na(index)) return(c(values, flag, value))
  values[[index + 1L]] <- value
  values
}

asset_ids <- function() {
  assets <- gee_list_assets(output_folder, project)
  vapply(assets, function(asset) as.character(asset$name %||% ""), character(1L))
}

assert_known_assets <- function() {
  current <- asset_ids()
  unexpected <- setdiff(current, expected_assets)
  if (length(unexpected)) {
    stop("The ERA5 output folder contains an unexpected asset", call. = FALSE)
  }
  current
}

assert_global_idle <- function() {
  active <- Filter(
    function(operation) gee_operation_state(operation) %in% active_states,
    gee_list_operations(project)
  )
  if (length(active)) {
    stop("Earth Engine is not globally idle", call. = FALSE)
  }
}

launcher_args <- function(years, max_tasks, receipt, task_log = NULL) {
  values <- c(
    "--payload-manifest", payload_list,
    "--output-folder", output_folder,
    "--run-label", run_label,
    "--project", project,
    "--period", "annual",
    "--years", years,
    "--expected-site-count", "85",
    "--expected-site-ids", site_file,
    "--max-new-tasks", as.character(max_tasks),
    "--receipt-output", receipt
  )
  if (!is.null(task_log)) values <- c(values, "--task-log", task_log)
  values
}

quota_command <- function(plan, receipt) {
  line <- trimws(plan[grepl("gee_quota_preflight.R", plan, fixed = TRUE)])
  if (length(line) != 1L) stop("Could not identify the quota check")
  values <- scan(text = line, what = character(), quiet = TRUE)
  values <- set_cli_value(
    values,
    "--monthly-stop-eecu-hours",
    as.character(monthly_stop_hours)
  )
  values <- set_cli_value(
    values,
    "--watchdog-cancel-eecu-hours",
    format(watchdog_hours, scientific = FALSE)
  )
  values <- set_cli_value(values, "--receipt", receipt)
  list(command = values[[1L]], args = values[-1L])
}

wait_for_tasks <- function(task_log, wall_limit_seconds = 10800) {
  records <- fromJSON(task_log, simplifyDataFrame = TRUE)
  operation_names <- paste0("projects/", project, "/operations/", records$task_id)
  if (!nrow(records) || any(!nzchar(records$task_id))) {
    stop("The launcher did not record submitted task IDs", call. = FALSE)
  }
  started <- Sys.time()
  repeat {
    operations <- gee_list_operations(project)
    names_now <- vapply(
      operations,
      function(operation) operation$name %||% "",
      character(1L)
    )
    index <- match(operation_names, names_now)
    if (anyNA(index)) {
      if (difftime(Sys.time(), started, units = "secs") > 300) {
        stop("Submitted Earth Engine operations were not visible")
      }
      Sys.sleep(10)
      next
    }
    selected <- operations[index]
    states <- vapply(selected, gee_operation_state, character(1L))
    foreign <- setdiff(
      names_now[vapply(
        operations,
        function(operation) gee_operation_state(operation) %in% active_states,
        logical(1L)
      )],
      operation_names
    )
    if (length(foreign)) {
      for (active_index in which(states %in% active_states)) {
        gee_cancel_operation(operation_names[[active_index]], project)
      }
      stop("Foreign Earth Engine work overlapped this batch")
    }
    if (any(states %in% failure_states)) {
      stop("An ERA5 task failed or was cancelled", call. = FALSE)
    }
    if (all(states == "SUCCEEDED")) break
    if (difftime(Sys.time(), started, units = "secs") > wall_limit_seconds) {
      for (active_index in which(states %in% active_states)) {
        gee_cancel_operation(operation_names[[active_index]], project)
      }
      stop("An ERA5 batch exceeded its wall-time safety limit", call. = FALSE)
    }
    Sys.sleep(10)
  }
  for (attempt in seq_len(12L)) {
    if (all(records$asset_id %in% asset_ids())) return(invisible(records))
    Sys.sleep(10)
  }
  stop("Successful ERA5 tasks did not produce every planned asset")
}

submit_batch <- function(years, max_tasks) {
  assert_global_idle()
  assert_known_assets()
  receipt <- tempfile("era5-release3-receipt-", fileext = ".json")
  task_log <- tempfile("era5-release3-tasks-", fileext = ".json")
  on.exit(unlink(c(
    receipt,
    paste0(receipt, ".consumed.json"),
    paste0(receipt, ".watchdog.jsonl"),
    task_log
  ), force = TRUE), add = TRUE)
  command_args <- launcher_args(years, max_tasks, receipt, task_log)
  plan <- run_capture(python, c(launcher, command_args))
  before <- read_plan_counts(plan)
  if (before[["eligible"]] == 0L) return(before)
  quota <- quota_command(plan, receipt)
  assert_global_idle()
  run_capture(quota$command, quota$args)
  assert_global_idle()
  run_capture(
    python,
    c(launcher, command_args, "--submit", "--preflight-receipt", receipt)
  )
  wait_for_tasks(task_log)
  after <- read_plan_counts(run_capture(python, c(launcher, command_args)))
  if (after[["missing"]] != before[["missing"]] - before[["eligible"]]) {
    stop("The completed ERA5 batch did not make exact planned progress")
  }
  after
}

### Selected mode

if (mode == "dry-run") {
  assert_global_idle()
  assert_known_assets()
  receipt <- tempfile("era5-release3-dry-", fileext = ".json")
  on.exit(unlink(receipt, force = TRUE), add = TRUE)
  result <- read_plan_counts(run_capture(
    python,
    c(launcher, launcher_args("2000", 1L, receipt))
  ))
  cat(
    "Dry run: ", result[["missing"]], " tasks missing; ",
    result[["eligible"]], " eligible. No task was submitted.\n",
    sep = ""
  )
  quit(status = 0L)
}

lock_dir <- file.path(tempdir(), "sisyn-era5-release3-remaining-85.lock")
if (!dir.create(lock_dir, showWarnings = FALSE)) {
  stop("Another remaining-85 ERA5 scheduler holds the lock", call. = FALSE)
}
on.exit(unlink(lock_dir, recursive = TRUE, force = TRUE), add = TRUE)

if (mode == "smoke") {
  current <- assert_known_assets()
  if (smoke_asset %in% current) {
    cat("The largest-part 2000 smoke asset already exists\n")
    quit(status = 0L)
  }
  if (length(current)) stop("Smoke mode requires an otherwise empty output set")
  submit_batch("2000", 1L)
  if (!smoke_asset %in% assert_known_assets()) stop("Smoke asset is absent")
  cat("Largest-part leap-year smoke succeeded\n")
  quit(status = 0L)
}

if (!smoke_asset %in% assert_known_assets()) {
  stop("Bulk mode requires the largest-part 2000 smoke asset", call. = FALSE)
}
repeat {
  result <- submit_batch("2000:2025", 5L)
  if (result[["missing"]] == 0L) break
}
if (!setequal(assert_known_assets(), expected_assets)) {
  stop("The ERA5 run ended without the exact 156-asset set")
}
cat("ERA5 remaining-85 extraction complete: 156 assets\n")
}

main()
