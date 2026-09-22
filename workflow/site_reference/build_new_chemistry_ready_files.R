# build integration-ready chemistry files from new and merged source data

suppressPackageStartupMessages(library(data.table))

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path("workflow", "site_reference", "build_new_chemistry_ready_files.R")
}, mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- gems ----

build_gems <- function(path) {
  columns <- c(
    "GEMS.Station.Number", "Sample.Date", "Parameter.Code", "Value Flags", "Value", "Unit"
  )
  data <- fread(require_input_file(path), select = columns, na.strings = NULL)
  data <- data[
    Parameter.Code %in% c("SiO2-Dis", "Si-Dis") &
      tolower(trimws(Unit)) == "mg/l" &
      is.finite(Value)
  ]
  data[, date := as.IDate(Sample.Date)]
  data <- data[!is.na(date)]
  daily <- data[, .(
    value = mean(Value),
    flag = if (any(grepl("<", `Value Flags`, fixed = TRUE), na.rm = TRUE)) "<" else ""
  ), by = .(Stream_Name = GEMS.Station.Number, date, Parameter.Code)]
  values <- dcast(daily, Stream_Name + date ~ Parameter.Code, value.var = "value")
  flags <- daily[, .(
    DSi_Remark = if (any(flag == "<")) "<" else "",
    DSi_Source_Parameter = paste(sort(unique(Parameter.Code)), collapse = "; ")
  ), by = .(Stream_Name, date)]
  output <- merge(values, flags, by = c("Stream_Name", "date"), all = TRUE)
  setnames(output, c("SiO2-Dis", "Si-Dis"), c("dsi_mg_SiO2_L", "dsi_mg_Si_L"), skip_absent = TRUE)
  for (column in c("dsi_mg_SiO2_L", "dsi_mg_Si_L")) {
    if (!column %in% names(output)) output[, (column) := NA_real_]
  }
  output[, LTER := "GEMS"]
  setcolorder(output, c(
    "LTER", "Stream_Name", "date", "dsi_mg_SiO2_L", "dsi_mg_Si_L",
    "DSi_Remark", "DSi_Source_Parameter"
  ))
  setorder(output, Stream_Name, date)
  output
}

# ---- danube ----

build_danube <- function(path) {
  columns <- c(
    "value_calc", "date_of_sampling", "remark_code", "station_code", "unit",
    "detection_limit", "determinand_code", "determinand"
  )
  data <- fread(require_input_file(path), select = columns, na.strings = NULL)
  data <- data[
    determinand_code %in% c("2.3.10", "2.3.11") &
      tolower(trimws(unit)) == "mg/l" &
      is.finite(value_calc)
  ]
  data[, date := as.IDate(substr(date_of_sampling, 1, 10))]
  data <- data[!is.na(date)]
  data[, priority := fifelse(determinand_code == "2.3.11", 1L, 2L)]
  data[, selected_priority := min(priority), by = .(station_code, date)]
  data <- data[priority == selected_priority]
  output <- data[, .(
    dsi_mg_SiO2_L = mean(value_calc),
    DSi_Remark = if (any(grepl("<", remark_code, fixed = TRUE), na.rm = TRUE)) "<" else "",
    DSi_Detection_Limit_mg_SiO2_L = mean(detection_limit, na.rm = TRUE),
    DSi_Source_Parameter = paste(sort(unique(determinand)), collapse = "; ")
  ), by = .(Stream_Name = station_code, date)]
  output[!is.finite(DSi_Detection_Limit_mg_SiO2_L), DSi_Detection_Limit_mg_SiO2_L := NA_real_]
  output[, LTER := "Danube"]
  setcolorder(output, c(
    "LTER", "Stream_Name", "date", "dsi_mg_SiO2_L", "DSi_Remark",
    "DSi_Detection_Limit_mg_SiO2_L", "DSi_Source_Parameter"
  ))
  setorder(output, Stream_Name, date)
  output
}

# ---- de-duplicated sites ----

deduplicated_site_map <- data.table(
  source_stream_name = c(
    "Green River",
    "Hudson River",
    "Merced River",
    "North Slyamore Creek",
    "Obidos",
    "Onyx River at Lower Wright Weir",
    "Sagehen Creek",
    "Vallecito Creek",
    "West Clear Creek",
    "Yukon River"
  ),
  LTER = c("USGS", "USGS", "USGS", "USGS", "GRO", "MCM", "Sagehen", "USGS", "USGS", "USGS"),
  Stream_Name = c(
    "GREEN RIVER",
    "HUDSON RIVER",
    "MERCED R",
    "North Slyamore Creek",
    "Obidos",
    "Onyx River at Lower Wright Weir",
    "Sagehen",
    "Vallecito Creek",
    "West Clear Creek",
    "YUKON RIVER"
  )
)

deduplicated_variable_map <- c(
  "Al" = "Al",
  "alkalinity" = "alkalinity",
  "Br" = "Br",
  "Ca" = "Ca",
  "Cl" = "Cl",
  "conductivity" = "conductivity",
  "dissolved org C" = "DOC",
  "dissolved org N" = "DON",
  "dissolved oxygen" = "DO",
  "DSi" = "DSi",
  "F" = "F",
  "Fe" = "Fe",
  "HCO3" = "HCO3",
  "K" = "K",
  "Li" = "Li",
  "Mg" = "Mg",
  "Mn" = "Mn",
  "Na" = "Na",
  "NH4" = "NH4",
  "NO3" = "NO3",
  "NOx" = "NOx",
  "pH" = "pH",
  "PO4" = "PO4",
  "SO4" = "SO4",
  "specific conductivity" = "specific_conductivity",
  "Sr" = "Sr",
  "SRP" = "SRP",
  "susp partic matter" = "SPM",
  "temp" = "Temp",
  "TN" = "TN",
  "tot dissolved N" = "TDN",
  "tot org C" = "TOC",
  "TP" = "TP"
)

normalize_comparison_unit <- function(value) {
  value <- trimws(as.character(value))
  value[value == "umol/L"] <- "uM"
  value[value == "deg C"] <- "C"
  value
}

build_deduplicated_sites <- function(input_dir) {
  if (!dir.exists(input_dir)) stop("Missing de-duplicated chemistry directory: ", input_dir, call. = FALSE)
  files <- sort(list.files(
    input_dir,
    pattern = "_chemistry_deduplicated[.]csv$",
    full.names = TRUE
  ))
  if (!length(files)) stop("No de-duplicated chemistry files found in: ", input_dir, call. = FALSE)

  required <- c(
    "stream_name", "variable", "sample_date", "sample_datetime_utc", "value", "unit",
    "qa_comparison_value", "qa_comparison_unit", "source_file", "raw_stream_name",
    "source_dataset", "source_row", "qualifier", "overlapping_source_count",
    "overlapping_sources", "deduplication_action", "deduplication_note"
  )
  data <- rbindlist(lapply(files, function(path) {
    value <- fread(require_input_file(path), na.strings = NULL)
    assert_required_columns(value, required, basename(path))
    value[, deduplicated_source_file := basename(path)]
    value
  }), fill = TRUE)

  data <- merge(
    data,
    deduplicated_site_map,
    by.x = "stream_name",
    by.y = "source_stream_name",
    all.x = TRUE
  )
  if (data[is.na(LTER) | is.na(Stream_Name), .N]) {
    missing <- paste(sort(unique(data[is.na(LTER) | is.na(Stream_Name), stream_name])), collapse = ", ")
    stop("Missing final site identity for: ", missing, call. = FALSE)
  }

  data[, normalized_variable := unname(deduplicated_variable_map[variable])]
  if (data[is.na(normalized_variable), .N]) {
    missing <- paste(sort(unique(data[is.na(normalized_variable), variable])), collapse = ", ")
    stop("Missing chemistry variable mapping for: ", missing, call. = FALSE)
  }

  output <- data.table(
    LTER = data$LTER,
    Stream_Name = data$Stream_Name,
    date = as.IDate(data$sample_date),
    sample_datetime_utc = data$sample_datetime_utc,
    variable = data$normalized_variable,
    value = suppressWarnings(as.numeric(data$qa_comparison_value)),
    units = normalize_comparison_unit(data$qa_comparison_unit),
    remarks = data$qualifier,
    source_value = suppressWarnings(as.numeric(data$value)),
    source_units = data$unit,
    source_file = data$source_file,
    raw_stream_name = data$raw_stream_name,
    source_dataset = data$source_dataset,
    source_row = data$source_row,
    overlapping_source_count = data$overlapping_source_count,
    overlapping_sources = data$overlapping_sources,
    deduplication_action = data$deduplication_action,
    deduplication_note = data$deduplication_note,
    deduplicated_source_file = data$deduplicated_source_file
  )
  if (output[is.na(date) | !is.finite(value) | is.na(units) | !nzchar(units), .N]) {
    stop("De-duplicated chemistry output contains an invalid date, value, or unit", call. = FALSE)
  }
  setorder(output, LTER, Stream_Name, date, variable, sample_datetime_utc, source_file, source_row)
  output
}

# ---- run ----

gems_path <- cli_value(args, "--gems")
danube_path <- cli_value(args, "--danube")
deduplicated_dir <- cli_value(args, "--deduplicated-dir")
output_dir <- cli_value(args, "--output-dir", required = TRUE)
overwrite <- cli_boolean(args, "--overwrite", FALSE)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
outputs <- list()
if (!is.null(gems_path) && nzchar(gems_path)) outputs$gems_dsi_ready_v1.csv <- build_gems(gems_path)
if (!is.null(danube_path) && nzchar(danube_path)) outputs$danube_dsi_ready_v1.csv <- build_danube(danube_path)
if (!is.null(deduplicated_dir) && nzchar(deduplicated_dir)) {
  outputs$deduplicated_sites_chemistry_ready_v1.csv <- build_deduplicated_sites(deduplicated_dir)
}
if (!length(outputs)) {
  stop("Provide at least one of --gems, --danube, or --deduplicated-dir", call. = FALSE)
}

output_paths <- file.path(output_dir, names(outputs))
existing_outputs <- output_paths[file.exists(output_paths)]
if (length(existing_outputs) && !overwrite) {
  stop(
    "Output files already exist. Use --overwrite true to replace them: ",
    paste(existing_outputs, collapse = ", "),
    call. = FALSE
  )
}

for (name in names(outputs)) {
  path <- file.path(output_dir, name)
  fwrite(outputs[[name]], path)
  message(
    "Wrote ", nrow(outputs[[name]]), " chemistry rows across ",
    uniqueN(outputs[[name]]$Stream_Name), " sites to ", normalizePath(path)
  )
}
