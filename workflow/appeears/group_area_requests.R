suppressPackageStartupMessages(library(jsonlite))

# ---- arguments ----

args <- commandArgs(trailingOnly = TRUE)

get_arg <- function(flag, default = NULL) {
  index <- match(flag, args)
  if (is.na(index)) return(default)
  if (index == length(args)) stop(flag, " requires a value", call. = FALSE)
  args[[index + 1L]]
}

get_bool_arg <- function(flag, default = FALSE) {
  value <- tolower(trimws(get_arg(flag, as.character(default))))
  if (!value %in% c("true", "false", "t", "f", "1", "0", "yes", "no")) {
    stop(flag, " must be true or false", call. = FALSE)
  }
  value %in% c("true", "t", "1", "yes")
}

request_dir <- get_arg("--request-dir")
output_dir <- get_arg("--output-dir")
site_slugs <- strsplit(get_arg("--site-slugs", ""), ",", fixed = TRUE)[[1L]]
date_blocks <- strsplit(get_arg("--date-blocks", ""), ",", fixed = TRUE)[[1L]]
task_prefix <- get_arg("--task-prefix", "sisyn-grouped")
run_date <- get_arg("--run-date", format(Sys.Date(), "%Y%m%d"))
overwrite <- get_bool_arg("--overwrite", FALSE)

if (is.null(request_dir) || is.null(output_dir)) {
  stop("--request-dir and --output-dir are required", call. = FALSE)
}
site_slugs <- trimws(site_slugs)
date_blocks <- trimws(date_blocks)
site_slugs <- site_slugs[nzchar(site_slugs)]
date_blocks <- date_blocks[nzchar(date_blocks)]
if (!length(site_slugs) || !length(date_blocks)) {
  stop("--site-slugs and --date-blocks must not be empty", call. = FALSE)
}
if (anyDuplicated(site_slugs) || anyDuplicated(date_blocks)) {
  stop("--site-slugs and --date-blocks must not contain duplicates", call. = FALSE)
}
if (!nzchar(trimws(task_prefix)) || !nzchar(trimws(run_date))) {
  stop("--task-prefix and --run-date must not be blank", call. = FALSE)
}

# ---- group requests ----

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_paths <- file.path(
  output_dir,
  paste0(task_prefix, "-", date_blocks, "-", run_date, "-request.json")
)
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}

for (date_block in date_blocks) {
  paths <- file.path(
    request_dir,
    paste0(site_slugs, "-all4-", date_block, "-", run_date, ".json")
  )
  if (any(!file.exists(paths))) {
    stop("Missing request files: ", paste(paths[!file.exists(paths)], collapse = ", "), call. = FALSE)
  }

  requests <- lapply(paths, fromJSON, simplifyVector = FALSE)
  reference <- requests[[1L]]
  features <- unlist(
    lapply(requests, function(request) request$params$geo$features),
    recursive = FALSE
  )
  if (!length(features)) stop("Grouped request contains no features", call. = FALSE)
  feature_property <- function(feature, name) {
    value <- feature$properties[[name]]
    if (is.null(value) || length(value) != 1L) return(NA_character_)
    trimws(as.character(value))
  }
  site_ids <- vapply(features, feature_property, character(1L), name = "site_id")
  aoi_names <- vapply(features, feature_property, character(1L), name = "aoi_name")
  if (any(is.na(site_ids) | !nzchar(site_ids) | is.na(aoi_names) | !nzchar(aoi_names))) {
    stop("Grouped request features need nonblank site_id and aoi_name values", call. = FALSE)
  }
  if (anyDuplicated(site_ids)) stop("Grouped request has duplicate site_id values", call. = FALSE)

  same_layers <- vapply(
    requests,
    function(request) identical(request$params$layers, reference$params$layers),
    logical(1L)
  )
  same_output <- vapply(
    requests,
    function(request) identical(request$params$output, reference$params$output),
    logical(1L)
  )
  same_dates <- vapply(
    requests,
    function(request) identical(request$params$dates, reference$params$dates),
    logical(1L)
  )
  if (!all(same_layers & same_output & same_dates)) {
    stop("Source requests do not share layers, output settings, and dates", call. = FALSE)
  }

  reference$task_name <- paste(task_prefix, date_block, run_date, sep = "-")
  reference$params$geo$features <- features
  output_path <- file.path(output_dir, paste0(reference$task_name, "-request.json"))
  write_json(reference, output_path, auto_unbox = TRUE, pretty = TRUE, digits = NA)
  cat(output_path, "\n")
}
