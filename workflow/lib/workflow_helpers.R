cli_value <- function(args, name, default = NULL, required = FALSE) {
  index <- which(args == name)
  if (!length(index)) {
    if (required) stop("Missing required option: ", name, call. = FALSE)
    return(default)
  }
  if (index[[length(index)]] == length(args)) {
    stop("Option requires a value: ", name, call. = FALSE)
  }
  args[[index[[length(index)]] + 1L]]
}

cli_values <- function(args, name) {
  index <- which(args == name)
  if (!length(index)) return(character())
  if (any(index == length(args))) {
    stop("Option requires a value: ", name, call. = FALSE)
  }
  args[index + 1L]
}

cli_boolean <- function(args, name, default = FALSE) {
  value <- tolower(cli_value(args, name, as.character(default)))
  if (!value %in% c("true", "false", "yes", "no", "1", "0")) {
    stop(name, " must be true or false.", call. = FALSE)
  }
  value %in% c("true", "yes", "1")
}

cli_integer <- function(args, name, default = NULL, minimum = NULL) {
  value <- cli_value(args, name, default)
  if (is.null(value)) return(NULL)
  value <- suppressWarnings(as.integer(value))
  if (is.na(value)) stop(name, " must be an integer.", call. = FALSE)
  if (!is.null(minimum) && value < minimum) {
    stop(name, " must be at least ", minimum, ".", call. = FALSE)
  }
  value
}

require_input_file <- function(path, label = "input file") {
  if (!file.exists(path)) stop("Missing ", label, ": ", path, call. = FALSE)
  normalizePath(path, mustWork = TRUE)
}

prepare_output_dir <- function(path, is_file = FALSE) {
  directory <- if (is_file) dirname(path) else path
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  invisible(normalizePath(directory, mustWork = TRUE))
}

assert_required_columns <- function(data, columns, label = "table") {
  missing <- setdiff(columns, names(data))
  if (length(missing)) {
    stop(
      label, " is missing required columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(data)
}

silica_find_repo_root <- function(start = getwd()) {
  current <- normalizePath(start, mustWork = TRUE)
  repeat {
    if (dir.exists(file.path(current, ".git"))) return(current)
    parent <- dirname(current)
    if (identical(parent, current)) {
      stop("Could not locate the repository root from ", start, ".", call. = FALSE)
    }
    current <- parent
  }
}

read_workflow_table <- function(path) {
  if (!file.exists(path)) stop("Missing input table: ", path, call. = FALSE)
  is_csv <- tolower(tools::file_ext(path)) == "csv"
  separator <- if (is_csv) "," else "\t"
  read.delim(
    path,
    sep = separator,
    quote = if (is_csv) "\"" else "",
    comment.char = "",
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

read_csv <- function(path, all_character = FALSE) {
  read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    colClasses = if (all_character) "character" else NA
  )
}

bind_tables <- function(tables) {
  columns <- unique(unlist(lapply(tables, names), use.names = FALSE))
  tables <- lapply(tables, function(data) {
    for (column in setdiff(columns, names(data))) data[[column]] <- NA_character_
    data[, columns, drop = FALSE]
  })
  output <- do.call(rbind, tables)
  rownames(output) <- NULL
  output
}

data_files <- function(path, required) {
  if (!file.exists(path)) return(character())
  candidates <- if (dir.exists(path)) {
    sort(list.files(path, pattern = "[.]csv$", recursive = TRUE, full.names = TRUE))
  } else path
  candidates[vapply(candidates, function(candidate) {
    header <- tryCatch(
      names(read.csv(candidate, nrows = 0L, stringsAsFactors = FALSE, check.names = FALSE)),
      error = function(error) character()
    )
    all(required %in% header)
  }, logical(1))]
}

read_data_set <- function(path, required, label) {
  files <- data_files(path, required)
  if (!length(files)) stop(
    "No ", label, " table with the required columns was found in ", path,
    call. = FALSE
  )
  list(data = bind_tables(lapply(files, read_csv, all_character = TRUE)), files = files)
}

empty_like <- function(data, rows) {
  output <- lapply(data, function(column) {
    if (is.integer(column)) return(rep(NA_integer_, rows))
    if (is.numeric(column)) return(rep(NA_real_, rows))
    if (is.logical(column)) return(rep(NA, rows))
    rep(NA_character_, rows)
  })
  names(output) <- names(data)
  as.data.frame(output, stringsAsFactors = FALSE, check.names = FALSE)
}

cast_like <- function(value, example, column) {
  if (is.integer(example)) {
    output <- suppressWarnings(as.integer(value))
  } else if (is.numeric(example)) {
    output <- suppressWarnings(as.numeric(value))
  } else if (is.logical(example)) {
    normalized <- tolower(trimws(as.character(value)))
    output <- ifelse(is.na(value) | normalized == "", NA,
                     normalized %in% c("true", "t", "1", "yes"))
  } else {
    output <- as.character(value)
  }
  bad_numeric <- (is.integer(example) || is.numeric(example)) &
    !is.na(value) & nzchar(trimws(as.character(value))) & is.na(output)
  if (any(bad_numeric)) stop("Could not convert values for ", column, call. = FALSE)
  output
}

fill_columns <- function(target, source, columns = intersect(names(target), names(source))) {
  for (column in columns) {
    target[[column]] <- cast_like(source[[column]], target[[column]], column)
  }
  target
}

first_numeric <- function(value, label) {
  numeric <- suppressWarnings(as.numeric(value))
  numeric <- numeric[is.finite(numeric)]
  if (length(numeric) != 1L) stop("Expected one numeric value for ", label, call. = FALSE)
  numeric[[1L]]
}

row_has_value <- function(data) {
  if (!ncol(data)) return(rep(FALSE, nrow(data)))
  rowSums(vapply(data, function(column) {
    !is.na(column) & nzchar(trimws(as.character(column)))
  }, logical(nrow(data)))) > 0L
}

normalized_text <- function(value) {
  output <- trimws(as.character(value))
  output[is.na(output)] <- ""
  output
}

require_columns <- function(data, columns, label) {
  missing <- setdiff(columns, names(data))
  if (length(missing)) {
    stop(label, " is missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
}

file_records <- function(paths, labels = NULL) {
  paths <- normalizePath(paths, mustWork = TRUE)
  records <- data.frame(
    path = paths,
    bytes = as.numeric(file.info(paths)$size),
    md5 = unname(tools::md5sum(paths)),
    stringsAsFactors = FALSE
  )
  if (!is.null(labels)) records <- cbind(label = labels, records)
  records
}

safe_file_name <- function(value) {
  gsub("[^A-Za-z0-9_-]+", "_", value)
}

percent_difference <- function(value, reference) {
  100 * abs(value - reference) / reference
}

install_checked_outputs <- function(staged, targets, backup_root = tempdir()) {
  if (length(staged) != length(targets) || any(!file.exists(staged))) {
    stop("Checked outputs and targets must exist and have equal length", call. = FALSE)
  }
  backup <- tempfile("output-backup-", tmpdir = backup_root)
  dir.create(backup, recursive = TRUE)
  on.exit(unlink(backup, recursive = TRUE, force = TRUE), add = TRUE)
  backup_paths <- file.path(backup, sprintf("%02d_%s", seq_along(targets), basename(targets)))
  existed <- file.exists(targets)
  backed <- installed <- logical(length(targets))

  for (index in which(existed)) {
    backed[[index]] <- file.rename(targets[[index]], backup_paths[[index]])
    if (!backed[[index]]) {
      for (restore in which(backed)) file.rename(backup_paths[[restore]], targets[[restore]])
      stop("Could not stage an existing output for replacement", call. = FALSE)
    }
  }
  for (index in seq_along(targets)) {
    dir.create(dirname(targets[[index]]), recursive = TRUE, showWarnings = FALSE)
    installed[[index]] <- file.rename(staged[[index]], targets[[index]])
    if (!installed[[index]]) break
  }
  if (all(installed)) return(invisible(targets))

  for (index in which(installed)) {
    if (dir.exists(targets[[index]])) {
      unlink(targets[[index]], recursive = TRUE)
    } else if (file.exists(targets[[index]])) {
      file.remove(targets[[index]])
    }
  }
  for (index in which(existed)) file.rename(backup_paths[[index]], targets[[index]])
  stop("Could not install all checked outputs", call. = FALSE)
}

normalize_key <- function(value) {
  value <- iconv(as.character(value), from = "UTF-8", to = "ASCII//TRANSLIT")
  value <- tolower(gsub("[^A-Za-z0-9]+", "_", value))
  gsub("(^_+|_+$)", "", value)
}

select_site_rows <- function(data, args) {
  lters <- cli_values(args, "--lter")
  site_keys <- cli_values(args, "--site")
  run_all <- cli_boolean(args, "--all", FALSE)
  if (!run_all && !length(lters) && !length(site_keys)) {
    stop("Select rows with --lter, --site LTER::Stream_Name, or --all true.", call. = FALSE)
  }
  keys <- paste(data$LTER, data$Stream_Name, sep = "::")
  keep <- run_all | data$LTER %in% lters | keys %in% site_keys
  selected <- data[keep, , drop = FALSE]
  if (!nrow(selected)) stop("No site rows matched the selection.", call. = FALSE)
  selected
}

independent_reference_area <- function(data) {
  area <- suppressWarnings(as.numeric(data$drainSqKm))
  if ("Drainage_Area_Verified" %in% names(data)) {
    area[tolower(trimws(data$Drainage_Area_Verified)) != "yes"] <- NA_real_
  } else if ("Derived_DA_Unverified" %in% names(data)) {
    area[tolower(trimws(data$Derived_DA_Unverified)) == "yes"] <- NA_real_
  }
  area
}
