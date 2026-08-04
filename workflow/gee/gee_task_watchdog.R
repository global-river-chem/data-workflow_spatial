### Setup

watchdog_script_path <- function() {
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
  normalizePath("workflow/gee/gee_task_watchdog.R")
}

source(file.path(dirname(watchdog_script_path()), "gee_api.R"))

watchdog_active_states <- c(
  "READY",
  "RUNNING",
  "PENDING",
  "CANCEL_REQUESTED",
  "CANCELLING"
)

### Helpers

watchdog_parse_args <- function(args) {
  values <- list()
  index <- 1L
  while (index <= length(args)) {
    token <- args[[index]]
    if (!startsWith(token, "--")) {
      stop("Unexpected argument: ", token)
    }
    key <- gsub("-", "_", substring(token, 3), fixed = TRUE)
    if (key == "inspect_once") {
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

watchdog_required <- function(args, name) {
  value <- args[[name]]
  if (is.null(value) || !nzchar(value)) {
    stop("Missing required argument --", gsub("_", "-", name))
  }
  value
}

append_watchdog_event <- function(path, event) {
  line <- jsonlite::toJSON(
    event,
    auto_unbox = TRUE,
    null = "null",
    na = "null",
    digits = NA
  )
  cat(line, "\n", sep = "")
  flush.console()
  if (!is.null(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    cat(line, "\n", file = path, append = TRUE, sep = "")
  }
}

### Monitor

watchdog_main <- function() {
  args <- watchdog_parse_args(commandArgs(trailingOnly = TRUE))
  project <- watchdog_required(args, "project")
  description_prefix <- watchdog_required(args, "description_prefix")
  warning_hours <- as.numeric(args$warning_eecu_hours %||% 10)
  cancel_hours <- as.numeric(args$cancel_eecu_hours %||% 25)
  poll_seconds <- as.integer(args$poll_seconds %||% 10)
  wait_seconds <- as.integer(args$wait_for_first_task_seconds %||% 300)
  log_path <- args$log %||% NULL
  inspect_once <- isTRUE(args$inspect_once)
  if (warning_hours <= 0 || cancel_hours <= 0) {
    stop("EECU thresholds must be positive")
  }
  if (warning_hours >= cancel_hours) {
    stop("The warning threshold must be below the cancellation threshold")
  }
  if (poll_seconds < 10) {
    stop("The polling interval must be at least 10 seconds")
  }
  if (wait_seconds < 0) {
    stop("The initial wait cannot be negative")
  }

  token <- gee_access_token()
  token_issued <- Sys.time()
  started <- Sys.time()
  saw_matching <- FALSE
  warned <- character()
  cancellation_requested <- character()
  append_watchdog_event(
    log_path,
    list(
      at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      event = "watchdog_started",
      project = project,
      description_prefix = description_prefix,
      warning_eecu_hours = warning_hours,
      cancel_eecu_hours = cancel_hours
    )
  )

  repeat {
    if (as.numeric(difftime(Sys.time(), token_issued, units = "mins")) >= 45) {
      token <- gee_access_token()
      token_issued <- Sys.time()
    }
    operations <- gee_list_operations(project, token)
    matching <- Filter(function(operation) {
      startsWith(gee_operation_description(operation), description_prefix) &&
        gee_operation_state(operation) %in% watchdog_active_states
    }, operations)
    if (length(matching)) {
      saw_matching <- TRUE
    }
    for (operation in matching) {
      name <- as.character(operation$name %||% "")
      description <- gee_operation_description(operation)
      state <- gee_operation_state(operation)
      eecu_hours <- gee_operation_eecu_seconds(operation) / 3600
      if (eecu_hours >= warning_hours && !name %in% warned) {
        append_watchdog_event(
          log_path,
          list(
            at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
            event = "high_usage_warning",
            operation = name,
            description = description,
            state = state,
            eecu_hours = round(eecu_hours, 6)
          )
        )
        warned <- c(warned, name)
      }
      if (
        !inspect_once &&
          state == "RUNNING" &&
          eecu_hours >= cancel_hours &&
          !name %in% cancellation_requested
      ) {
        gee_cancel_operation(name, project, token)
        append_watchdog_event(
          log_path,
          list(
            at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
            event = "cancellation_requested",
            operation = name,
            description = description,
            eecu_hours = round(eecu_hours, 6),
            limit_eecu_hours = cancel_hours
          )
        )
        cancellation_requested <- c(cancellation_requested, name)
      }
    }

    if (inspect_once) {
      append_watchdog_event(
        log_path,
        list(
          at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          event = "inspection_complete",
          matching_active_tasks = length(matching)
        )
      )
      return(invisible(NULL))
    }
    if (saw_matching && !length(matching)) {
      append_watchdog_event(
        log_path,
        list(
          at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          event = "watchdog_complete",
          reason = "no_matching_active_tasks"
        )
      )
      return(invisible(NULL))
    }
    elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
    if (!saw_matching && elapsed >= wait_seconds) {
      append_watchdog_event(
        log_path,
        list(
          at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
          event = "watchdog_complete",
          reason = "no_matching_task_appeared"
        )
      )
      return(invisible(NULL))
    }
    Sys.sleep(poll_seconds)
  }
}

if (sys.nframe() == 0L) {
  tryCatch(
    watchdog_main(),
    error = function(error) {
      message("GEE WATCHDOG ERROR: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
