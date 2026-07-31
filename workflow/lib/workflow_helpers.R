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

read_workflow_table <- function(path) {
  if (!file.exists(path)) stop("Missing input table: ", path, call. = FALSE)
  separator <- if (tolower(tools::file_ext(path)) == "csv") "," else "\t"
  read.delim(
    path,
    sep = separator,
    quote = "",
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
