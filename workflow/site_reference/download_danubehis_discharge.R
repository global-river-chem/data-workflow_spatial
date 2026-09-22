# download reviewed daily discharge series from danubehis

suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
  library(xml2)
})

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path("workflow", "site_reference", "download_danubehis_discharge.R")
}, mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- source reader ----

danubehis_url <- function(station_id, start_date, end_date) {
  query <- paste0(
    "symbol%5BQ_mean_daily%5D=Q_mean_daily",
    "&time_from=", format(start_date, "%d.%m.%Y"),
    "&time_to=", format(end_date, "%d.%m.%Y"),
    "&time_minute=&order=time&sort=asc"
  )
  paste0("https://www.danubehis.org/results/", station_id, "?", query)
}

read_chart <- function(station_id, start_date, end_date) {
  page <- read_html(danubehis_url(station_id, start_date, end_date))
  chart_node <- xml_find_first(page, "//*[@id='hydro_results__attachment_chart_Q_mean_daily']")
  if (inherits(chart_node, "xml_missing")) {
    stop("Daily discharge chart is missing for ", station_id, call. = FALSE)
  }
  chart <- fromJSON(xml_attr(chart_node, "data-chart"), simplifyVector = FALSE)
  values <- chart$series[[1]]$data
  if (!length(values)) return(data.table(Date = as.IDate(character()), Qcms = numeric()))
  data.table(
    Date = as.IDate(as.POSIXct(
      vapply(values, `[[`, numeric(1), 1) / 1000,
      origin = "1970-01-01",
      tz = "UTC"
    )),
    Qcms = vapply(values, `[[`, numeric(1), 2)
  )
}

chunk_dates <- function(start_date, end_date, chunk_years) {
  starts <- seq(start_date, end_date, by = paste(chunk_years, "years"))
  ends <- pmin(c(starts[-1] - 1, end_date), end_date)
  data.table(Start = as.IDate(starts), End = as.IDate(ends))
}

download_series <- function(station_id, start_date, end_date, chunk_years) {
  chunks <- chunk_dates(start_date, end_date, chunk_years)
  pieces <- lapply(seq_len(nrow(chunks)), function(index) {
    message(
      station_id, ": ", chunks$Start[[index]], " through ", chunks$End[[index]]
    )
    read_chart(station_id, chunks$Start[[index]], chunks$End[[index]])
  })
  output <- rbindlist(pieces)
  output <- output[is.finite(Qcms) & !is.na(Date)]
  output[, .(Qcms = mean(Qcms)), by = Date][order(Date)]
}

# ---- run ----

mapping_path <- cli_value(args, "--mapping", required = TRUE)
output_dir <- cli_value(args, "--output-dir", required = TRUE)
chunk_years <- cli_integer(args, "--chunk-years", "10", minimum = 1L)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

mapping <- fread(require_input_file(mapping_path), na.strings = NULL, check.names = FALSE)
assert_required_columns(mapping, c(
  "Stream_Name", "Station_ID", "Available_Start", "Available_End", "Discharge_File_Name"
), "DanubeHIS discharge mapping")
if (!nrow(mapping)) stop("The DanubeHIS discharge mapping has no site rows.", call. = FALSE)
for (column in c("Stream_Name", "Station_ID", "Discharge_File_Name")) {
  set(mapping, j = column, value = trimws(as.character(mapping[[column]])))
}
mapping[, Available_Start := as.IDate(Available_Start)]
mapping[, Available_End := as.IDate(Available_End)]
if (any(
  is.na(mapping$Stream_Name) | !nzchar(mapping$Stream_Name) |
    is.na(mapping$Station_ID) | !nzchar(mapping$Station_ID) |
    is.na(mapping$Discharge_File_Name) | !nzchar(mapping$Discharge_File_Name)
)) {
  stop("The mapping contains blank site, station, or discharge names.", call. = FALSE)
}
if (any(is.na(mapping$Available_Start) | is.na(mapping$Available_End))) {
  stop("The mapping contains invalid availability dates.", call. = FALSE)
}
if (any(mapping$Available_Start > mapping$Available_End)) {
  stop("The mapping contains an availability start after its end date.", call. = FALSE)
}
if (anyDuplicated(mapping$Stream_Name) || anyDuplicated(mapping$Discharge_File_Name)) {
  stop("The mapping must have unique site and discharge names.", call. = FALSE)
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
output_paths <- file.path(output_dir, paste0(mapping$Discharge_File_Name, ".csv"))
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}
cache <- new.env(parent = emptyenv())
for (index in seq_len(nrow(mapping))) {
  row <- mapping[index]
  cache_key <- paste(row$Station_ID, row$Available_Start, row$Available_End, sep = "\r")
  if (!exists(cache_key, envir = cache, inherits = FALSE)) {
    assign(
      cache_key,
      download_series(row$Station_ID, row$Available_Start, row$Available_End, chunk_years),
      envir = cache
    )
  }
  discharge <- copy(get(cache_key, envir = cache, inherits = FALSE))
  if (nrow(discharge) < 2L) stop("Too few daily values for ", row$Stream_Name, call. = FALSE)
  discharge[, `:=`(
    Discharge_File_Name = row$Discharge_File_Name,
    LTER = "Danube",
    Stream_Name = row$Stream_Name
  )]
  output_path <- output_paths[[index]]
  fwrite(discharge[, .(Qcms, Date, Discharge_File_Name, LTER, Stream_Name)], output_path)
}

message("Wrote ", nrow(mapping), " reviewed Danube discharge files to ", normalizePath(output_dir))
