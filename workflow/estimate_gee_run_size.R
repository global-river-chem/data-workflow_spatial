suppressPackageStartupMessages({
  library(yaml)
})

default_concurrent_batch_tasks <- 2
ready_queue_limit <- 3000
finished_states <- c("COMPLETED", "FAILED", "CANCELLED")

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg)) sub("^--file=", "", script_arg[[1]]) else "workflow/estimate_gee_run_size.R"
repo_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)

parse_args <- function(args) {
  parsed <- list()
  i <- 1
  while (i <= length(args)) {
    flag <- args[[i]]
    if (!startsWith(flag, "--")) {
      stop("Unexpected argument: ", flag, call. = FALSE)
    }
    if (i == length(args) || startsWith(args[[i + 1]], "--")) {
      parsed[[flag]] <- TRUE
      i <- i + 1
    } else {
      parsed[[flag]] <- args[[i + 1]]
      i <- i + 2
    }
  }
  parsed
}

arg_value <- function(args, flag, default = NULL) {
  args[[flag]] %||% default
}

as_vector <- function(x) {
  if (is.null(x)) {
    return(character())
  }
  as.character(unlist(x, use.names = FALSE))
}

clean_scalar <- function(x) {
  if (is.null(x) || !length(x)) {
    return(NULL)
  }
  value <- as.character(x[[1]])
  if (is.na(value) || !nzchar(value)) {
    return(NULL)
  }
  value
}

first_existing_column <- function(fieldnames, candidates) {
  for (candidate in candidates) {
    if (candidate %in% fieldnames) {
      return(candidate)
    }
  }
  stop("Could not find any of these columns: ", paste(candidates, collapse = ", "), call. = FALSE)
}

load_group_counts <- function(geometry_check_path, preferred_column) {
  if (!file.exists(geometry_check_path)) {
    stop("Geometry check file not found: ", geometry_check_path, call. = FALSE)
  }

  geometry_check <- read.csv(
    geometry_check_path,
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
  group_column <- first_existing_column(
    names(geometry_check),
    c(preferred_column, "run_group", "run_grp")
  )
  groups <- geometry_check[[group_column]]
  groups <- groups[!is.na(groups) & nzchar(groups)]

  if (!length(groups)) {
    stop("No run groups found in ", geometry_check_path, call. = FALSE)
  }

  table(groups)
}

month_values <- function(months = "all") {
  if (is.null(months) || identical(months, "all")) {
    return(seq.int(1, 12))
  }
  values <- as_vector(months)
  if (length(values) == 1 && identical(values, "all")) {
    return(seq.int(1, 12))
  }
  as.integer(values)
}

run_periods <- function(timing, start_year, end_year, months = "all") {
  timing <- timing %||% "annual"
  if (identical(timing, "static")) {
    return(list(list(year = NA_integer_, month = NA_integer_, months = NULL, period = "static")))
  }

  if (is.null(start_year) || is.null(end_year)) {
    stop("start_year and end_year are required unless timing is static.", call. = FALSE)
  }

  periods <- list()
  for (year in seq.int(as.integer(start_year), as.integer(end_year))) {
    if (identical(timing, "annual")) {
      periods[[length(periods) + 1]] <- list(year = year, month = NA_integer_, months = NULL, period = "annual")
    } else if (identical(timing, "monthly")) {
      for (month in month_values(months)) {
        periods[[length(periods) + 1]] <- list(year = year, month = month, months = NULL, period = "monthly")
      }
    } else if (timing %in% c("monthly_by_year", "monthly_year")) {
      periods[[length(periods) + 1]] <- list(
        year = year,
        month = NA_integer_,
        months = month_values(months),
        period = "monthly_by_year"
      )
    } else {
      stop("Unsupported timing: ", timing, call. = FALSE)
    }
  }
  periods
}

product_names_for_run <- function(run) {
  if (identical(run$mode, "era5_land")) {
    return(NA_character_)
  }
  products <- as_vector(run$products)
  if (length(products)) {
    return(products)
  }
  product <- run$product
  if (!is.null(product) && nzchar(product)) {
    return(product)
  }
  stop("Run needs either products or product.", call. = FALSE)
}

build_run_list <- function(run_config, run_groups, active_run_name = NULL) {
  runs <- run_config$runs %||% list()
  active_run <- active_run_name %||% run_config$active_run

  if (is.null(active_run) || !nzchar(active_run)) {
    stop("Set active_run in config/run-list.yml.", call. = FALSE)
  }
  if (!active_run %in% names(runs)) {
    stop("Run not found in config/run-list.yml: ", active_run, call. = FALSE)
  }

  run <- runs[[active_run]]
  requested_groups <- run$run_groups %||% "all"
  selected_groups <- if (length(requested_groups) == 1 && identical(requested_groups, "all")) {
    run_groups
  } else {
    as_vector(requested_groups)
  }
  periods <- run_periods(
    timing = run$timing %||% "annual",
    start_year = run$start_year,
    end_year = run$end_year,
    months = run$months %||% "all"
  )
  products <- product_names_for_run(run)

  rows <- list()
  for (run_group in selected_groups) {
    for (period in periods) {
      for (product in products) {
        rows[[length(rows) + 1]] <- list(
          run_name = active_run,
          mode = run$mode %||% "single_product",
          product = product,
          products = paste(as_vector(run$products), collapse = "|"),
          year = period$year,
          month = period$month,
          months = period$months,
          period = period$period,
          run_group = run_group
        )
      }
    }
  }
  rows
}

months_in_row <- function(row) {
  if (!identical(row$period, "monthly_by_year")) {
    return(1L)
  }
  months <- row$months
  if (is.null(months) || (length(months) == 1 && identical(months, "all"))) {
    return(12L)
  }
  length(months)
}

estimate_output_rows <- function(run_rows, group_counts) {
  total <- 0
  for (row in run_rows) {
    total <- total + as.integer(group_counts[[row$run_group]]) * months_in_row(row)
  }
  total
}

run_product_count <- function(run_settings) {
  if (identical(run_settings$mode, "era5_land")) {
    return(length(as_vector(run_settings$products)))
  }
  products <- as_vector(run_settings$products)
  if (length(products)) {
    return(length(products))
  }
  if (!is.null(run_settings$product)) {
    return(1L)
  }
  0L
}

format_hours <- function(tasks, minutes_per_task = NULL) {
  waves <- ceiling(tasks / default_concurrent_batch_tasks)
  if (is.null(minutes_per_task)) {
    return(sprintf("%s two-task waves", format(waves, big.mark = ",")))
  }
  hours <- waves * minutes_per_task / 60
  sprintf("%s two-task waves, about %s hours at %g min/task", format(waves, big.mark = ","), format(round(hours, 1), big.mark = ","), minutes_per_task)
}

product_label <- function(row) {
  value <- clean_scalar(row[["product"]])
  if (!is.null(value)) {
    return(value)
  }
  value <- clean_scalar(row[["products"]])
  if (!is.null(value)) {
    return(value)
  }
  clean_scalar(row[["mode"]]) %||% ""
}

observed_minutes_per_task <- function(timing_log_path, mode = NULL, period = NULL, product = NULL) {
  timing <- read.csv(timing_log_path, check.names = FALSE, stringsAsFactors = FALSE)
  values <- numeric()

  for (i in seq_len(nrow(timing))) {
    row <- timing[i, , drop = FALSE]
    if (!row$state %in% finished_states) {
      next
    }
    if (!is.null(mode) && !identical(row$mode, mode)) {
      next
    }
    if (!is.null(period) && !identical(row$period, period)) {
      next
    }
    if (!is.null(product) && !product %in% strsplit(product_label(row), "\\|", fixed = FALSE)[[1]]) {
      next
    }
    elapsed <- row$elapsed_min
    if (is.na(elapsed) || !nzchar(elapsed)) {
      next
    }
    values <- c(values, as.numeric(elapsed))
  }

  if (!length(values)) {
    stop("No finished timing rows matched the requested filters in ", timing_log_path, call. = FALSE)
  }

  list(minutes_per_task = mean(values), timing_n = length(values))
}

year_span <- function(run_settings) {
  if (identical(run_settings$timing, "static")) {
    return("static")
  }
  start_year <- run_settings$start_year
  end_year <- run_settings$end_year
  if (identical(start_year, end_year)) {
    return(as.character(start_year))
  }
  paste0(start_year, "-", end_year)
}

describe_run <- function(run_name, run_config, group_counts, minutes_per_task = NULL) {
  run_rows <- build_run_list(run_config, names(group_counts), active_run_name = run_name)
  run_settings <- run_config$runs[[run_name]]
  tasks <- length(run_rows)

  list(
    run_name = run_name,
    mode = run_settings$mode %||% "single_product",
    timing = run_settings$timing %||% "annual",
    years = year_span(run_settings),
    products = run_product_count(run_settings),
    tasks = tasks,
    output_rows = estimate_output_rows(run_rows, group_counts),
    launch_export = isTRUE(run_settings$launch_export),
    time_note = format_hours(tasks, minutes_per_task),
    queue_note = if (tasks > ready_queue_limit) "split before queuing" else ""
  )
}

print_table <- function(rows) {
  headers <- c(
    "run_name",
    "mode",
    "timing",
    "years",
    "products",
    "tasks",
    "output_rows",
    "launch_export",
    "time_note",
    "queue_note"
  )
  values <- lapply(rows, function(row) {
    vapply(headers, function(header) as.character(row[[header]]), character(1))
  })
  values <- do.call(rbind, values)
  widths <- pmax(nchar(headers), apply(values, 2, function(column) max(nchar(column))))

  cat(paste(mapply(format, headers, width = widths, justify = "left"), collapse = "  "), "\n", sep = "")
  cat(paste(strrep("-", widths), collapse = "  "), "\n", sep = "")
  for (i in seq_len(nrow(values))) {
    cat(paste(mapply(format, values[i, ], width = widths, justify = "left"), collapse = "  "), "\n", sep = "")
  }
}

args <- parse_args(commandArgs(trailingOnly = TRUE))
run_config <- yaml::read_yaml(file.path(repo_root, "config", "run-list.yml"))
asset_config <- yaml::read_yaml(file.path(repo_root, "config", "gee-assets.yml"))

geometry_check <- path.expand(asset_config$watersheds$geometry_check)
preferred_group_column <- run_config$site_groups$column %||% "run_group"
group_counts <- load_group_counts(geometry_check, preferred_group_column)
minutes_per_task <- arg_value(args, "--minutes-per-task")
if (!is.null(minutes_per_task)) {
  minutes_per_task <- as.numeric(minutes_per_task)
}

timing_log <- arg_value(args, "--timing-log")
if (!is.null(timing_log) && is.null(minutes_per_task)) {
  observed <- observed_minutes_per_task(
    timing_log_path = path.expand(timing_log),
    mode = arg_value(args, "--timing-mode"),
    period = arg_value(args, "--timing-period"),
    product = arg_value(args, "--timing-product")
  )
  minutes_per_task <- observed$minutes_per_task
  cat(sprintf("Using %.2f min/task from %s timing rows\n\n", minutes_per_task, observed$timing_n))
}

run_names <- names(run_config$runs %||% list())
requested_run <- arg_value(args, "--run")
if (!is.null(requested_run)) {
  if (!requested_run %in% run_names) {
    stop("Run not found: ", requested_run, call. = FALSE)
  }
  run_names <- requested_run
}

rows <- lapply(
  run_names,
  describe_run,
  run_config = run_config,
  group_counts = group_counts,
  minutes_per_task = minutes_per_task
)

cat("Watersheds in geometry check:", format(sum(group_counts), big.mark = ","), "\n")
cat("Run groups:", format(length(group_counts), big.mark = ","), "\n")
cat("Default Earth Engine batch-task concurrency used here:", default_concurrent_batch_tasks, "\n")
cat("Queue warning threshold used here:", format(ready_queue_limit, big.mark = ","), "ready tasks\n\n")
print_table(rows)
