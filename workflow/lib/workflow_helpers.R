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

require_columns <- function(data, columns, label) {
  missing <- setdiff(columns, names(data))
  if (length(missing)) {
    stop(label, " is missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
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
  if ("Derived_DA_Unverified" %in% names(data)) {
    area[tolower(trimws(data$Derived_DA_Unverified)) == "yes"] <- NA_real_
  }
  area
}
