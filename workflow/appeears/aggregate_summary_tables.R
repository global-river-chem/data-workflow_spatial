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

input_root <- get_arg("--input-root")
output_dir <- get_arg("--output-dir")
file_prefix <- get_arg("--file-prefix", "appeears_modis")
overwrite <- get_bool_arg("--overwrite", FALSE)

if (is.null(input_root) || is.null(output_dir)) {
  stop("--input-root and --output-dir are required", call. = FALSE)
}

# ---- inputs ----

task_dirs <- list.dirs(input_root, recursive = FALSE, full.names = TRUE)
task_dirs <- task_dirs[file.info(task_dirs)$isdir]
normalized_output_dir <- normalizePath(output_dir, mustWork = FALSE)
task_dirs <- task_dirs[
  normalizePath(task_dirs, mustWork = TRUE) != normalized_output_dir
]
if (!length(task_dirs)) stop("No AppEEARS task folders found", call. = FALSE)

task_maps <- lapply(task_dirs, function(task_dir) {
  request_file <- list.files(
    task_dir,
    pattern = "-request[.]json$",
    full.names = TRUE
  )
  if (length(request_file) != 1L) {
    stop("Expected one request JSON in ", task_dir, call. = FALSE)
  }
  request <- fromJSON(request_file, simplifyVector = FALSE)
  features <- request$params$geo$features
  if (!length(features)) stop("Request has no features: ", request_file, call. = FALSE)
  data.frame(
    task_name = request$task_name,
    aid = sprintf("aid%04d", seq_along(features)),
    site_id = vapply(
      features,
      function(feature) as.character(feature$properties$site_id),
      character(1L)
    ),
    aoi_name = vapply(
      features,
      function(feature) as.character(feature$properties$aoi_name),
      character(1L)
    ),
    task_dir = task_dir,
    stringsAsFactors = FALSE
  )
})
task_map <- do.call(rbind, task_maps)
if (any(
  is.na(task_map$task_name) | !nzchar(task_map$task_name) |
    is.na(task_map$site_id) | !nzchar(task_map$site_id) |
    is.na(task_map$aoi_name) | !nzchar(task_map$aoi_name)
)) {
  stop("Every AppEEARS task and feature needs task_name, site_id, and aoi_name", call. = FALSE)
}

site_names <- aggregate(
  aoi_name ~ site_id,
  task_map,
  function(value) paste(unique(value), collapse = " | ")
)
if (any(grepl(" | ", site_names$aoi_name, fixed = TRUE))) {
  stop("A site_id maps to multiple aoi_name values", call. = FALSE)
}
task_names <- aggregate(
  task_name ~ site_id,
  task_map,
  function(value) paste(sort(unique(value)), collapse = " | ")
)
names(task_names)[[2L]] <- "appeears_task_names"

read_product <- function(file_name) {
  pieces <- lapply(seq_len(nrow(task_map)), function(index) {
    map_row <- task_map[index, , drop = FALSE]
    file_path <- file.path(map_row$task_dir, file_name)
    if (!file.exists(file_path)) stop("Missing ", file_path, call. = FALSE)
    values <- read.csv(file_path, stringsAsFactors = FALSE, check.names = FALSE)
    values <- values[values$aid == map_row$aid, , drop = FALSE]
    if (!nrow(values)) stop("No rows for ", map_row$aid, " in ", file_path, call. = FALSE)
    values$task_name <- map_row$task_name
    values$site_id <- map_row$site_id
    values$aoi_name <- map_row$aoi_name
    values
  })
  do.call(rbind, pieces)
}

deduplicate_values <- function(values, keys) {
  key <- do.call(paste, c(values[keys], sep = "\r"))
  duplicate_keys <- unique(key[duplicated(key)])
  for (duplicate_key in duplicate_keys) {
    rows <- which(key == duplicate_key)
    observed <- unique(values$Mean[rows])
    observed <- observed[!is.na(observed)]
    if (length(observed) > 1L && diff(range(observed)) > 1e-8) {
      stop("Conflicting AppEEARS summary values for a duplicated observation", call. = FALSE)
    }
    if (length(observed)) values$Mean[rows[[1L]]] <- observed[[1L]]
  }
  values[!duplicated(key), , drop = FALSE]
}

wide_values <- function(values, id_columns, time_column, value_column, prefix, suffix) {
  names(values)[names(values) == value_column] <- "value"
  wide <- reshape(
    values[c(id_columns, time_column, "value")],
    idvar = id_columns,
    timevar = time_column,
    direction = "wide"
  )
  value_names <- grep("^value[.]", names(wide), value = TRUE)
  names(wide)[match(value_names, names(wide))] <- paste0(
    prefix,
    sub("^value[.]", "", value_names),
    suffix
  )
  wide
}

add_task_names <- function(values) {
  values <- merge(site_names, values, by = c("site_id", "aoi_name"), all.y = TRUE)
  merge(values, task_names, by = "site_id", all.x = TRUE)
}

# ---- evapotranspiration ----

sum_or_na <- function(value) {
  if (any(is.na(value))) return(NA_real_)
  sum(value)
}

mean_or_na <- function(value) {
  if (any(is.na(value))) return(NA_real_)
  mean(value)
}

parse_product_dates <- function(value, label) {
  parsed <- suppressWarnings(as.Date(as.character(value), format = "%Y-%m-%d"))
  if (any(is.na(parsed))) {
    stop(label, " contains a blank or invalid date", call. = FALSE)
  }
  parsed
}

et <- read_product("MOD16A2GF-061-Statistics.csv")
et$Date <- parse_product_dates(et$Date, "ET")
et <- deduplicate_values(et, c("site_id", "Dataset", "Date"))
et$year <- as.integer(format(et$Date, "%Y"))
et$month <- tolower(format(et$Date, "%b"))

et_annual <- aggregate(
  et["Mean"],
  et[c("site_id", "aoi_name", "year")],
  sum_or_na
)
et_wide <- wide_values(
  et_annual,
  c("site_id", "aoi_name"),
  "year",
  "Mean",
  "evapotrans_",
  "_kg_m2"
)

et_month_year <- aggregate(
  et["Mean"],
  et[c("site_id", "aoi_name", "year", "month")],
  sum_or_na
)
et_month <- aggregate(
  et_month_year["Mean"],
  et_month_year[c("site_id", "aoi_name", "month")],
  mean_or_na
)
et_month_wide <- wide_values(
  et_month,
  c("site_id", "aoi_name"),
  "month",
  "Mean",
  "evapotrans_",
  "_kg_m2"
)
et_output <- merge(et_wide, et_month_wide, by = c("site_id", "aoi_name"), all = TRUE)
et_output <- add_task_names(et_output)

# ---- net primary production ----

npp <- read_product("MOD17A3HGF-061-Statistics.csv")
npp$Date <- parse_product_dates(npp$Date, "NPP")
npp <- deduplicate_values(npp, c("site_id", "Dataset", "Date"))
npp$year <- as.integer(format(npp$Date, "%Y"))
npp_annual <- aggregate(
  npp["Mean"],
  npp[c("site_id", "aoi_name", "year")],
  mean_or_na
)
npp_output <- wide_values(
  npp_annual,
  c("site_id", "aoi_name"),
  "year",
  "Mean",
  "npp_",
  "_kgC_m2_year"
)
npp_output <- add_task_names(npp_output)

# ---- green-up date ----

greenup <- read_product("MCD12Q2-061-Statistics.csv")
greenup$Date <- parse_product_dates(greenup$Date, "Green-up data")
greenup$cycle <- sub(".*Greenup_([01])_.*", "\\1", greenup[["File Name"]])
if (any(!greenup$cycle %in% c("0", "1"))) {
  stop("Could not parse every green-up cycle", call. = FALSE)
}
greenup <- deduplicate_values(greenup, c("site_id", "Dataset", "Date", "cycle"))
greenup$year <- as.integer(format(greenup$Date, "%Y"))
greenup$greenup_date <- as.character(
  as.Date("1970-01-01") + round(as.numeric(greenup$Mean))
)
greenup_date_year <- as.integer(substr(greenup$greenup_date, 1L, 4L))
greenup_year_offset <- greenup_date_year - greenup$year
invalid_greenup_year <- !is.na(greenup_year_offset) &
  !greenup_year_offset %in% c(-1L, 0L)
if (any(invalid_greenup_year)) {
  stop("Green-up dates fall outside the product year or prior year", call. = FALSE)
}
greenup$key <- paste0("cycle", greenup$cycle, "_", greenup$year)
greenup_values <- greenup[c("site_id", "aoi_name", "key", "greenup_date")]
greenup_output <- wide_values(
  greenup_values,
  c("site_id", "aoi_name"),
  "key",
  "greenup_date",
  "greenup_",
  "MMDD"
)
greenup_output <- add_task_names(greenup_output)

# ---- outputs ----

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
outputs <- list(
  et = et_output,
  npp = npp_output,
  greenup = greenup_output
)
output_paths <- file.path(
  output_dir,
  paste0(file_prefix, "_", names(outputs), ".csv")
)
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}
for (product in names(outputs)) {
  output_path <- file.path(output_dir, paste0(file_prefix, "_", product, ".csv"))
  write.csv(outputs[[product]], output_path, row.names = FALSE, na = "")
  cat(output_path, nrow(outputs[[product]]), "rows\n")
}
