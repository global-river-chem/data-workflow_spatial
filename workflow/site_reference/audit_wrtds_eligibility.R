# Audit site-level WRTDS eligibility without changing the WRTDS workflow or live tables

suppressPackageStartupMessages(library(data.table))

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- normalizePath(if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else file.path("workflow", "site_reference", "audit_wrtds_eligibility.R"), mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- Helpers ----

clean_text <- function(value) {
  value <- as.character(value)
  value[is.na(value)] <- ""
  trimws(value)
}

normalize_lter <- function(value) {
  aliases <- c(
    ECCC_Canada = "Canada_ECCC",
    DGA_Chile = "Chile_DGA",
    MLIT_Japan = "Japan_MLIT",
    RWS_Netherlands = "Netherlands_RWS",
    CAMELS_Switzerland = "Switzerland_CAMELS_CH"
  )
  value <- clean_text(value)
  replace <- value %in% names(aliases)
  value[replace] <- unname(aliases[value[replace]])
  value
}

normalize_discharge_name <- function(value) {
  value <- basename(clean_text(value))
  sub("\\.csv$", "", value, ignore.case = TRUE)
}

read_general_table <- function(path, sheet = NULL) {
  path <- require_input_file(path)
  extension <- tolower(tools::file_ext(path))
  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("The readxl package is required for Excel input.", call. = FALSE)
    }
    if (is.null(sheet) || !nzchar(sheet)) sheet <- readxl::excel_sheets(path)[[1]]
    out <- as.data.frame(readxl::read_excel(path, sheet = sheet), check.names = FALSE)
  } else {
    separator <- if (extension == "csv") "," else "\t"
    out <- data.table::fread(
      path,
      sep = separator,
      quote = if (separator == ",") "\"" else "",
      na.strings = "NA",
      check.names = FALSE,
      data.table = FALSE,
      showProgress = FALSE
    )
  }
  out[] <- lapply(out, function(value) if (is.character(value)) clean_text(value) else value)
  out
}

collect_input_files <- function(paths, directories, role) {
  paths <- clean_text(paths)
  paths <- paths[nzchar(paths)]
  for (directory in clean_text(directories)) {
    if (!dir.exists(directory)) {
      stop("Missing ", role, " directory: ", directory, call. = FALSE)
    }
    found <- list.files(directory, "\\.csv$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    role_pattern <- paste0("[/\\\\]site-level-integration-package[/\\\\]", role, "[/\\\\]")
    preferred <- found[grepl(role_pattern, found, ignore.case = TRUE)]
    paths <- c(paths, if (length(preferred)) preferred else found)
  }
  paths <- unique(paths)
  missing <- paths[!file.exists(paths)]
  if (length(missing)) {
    stop("Missing ", role, " file(s): ", paste(missing, collapse = ", "), call. = FALSE)
  }
  normalizePath(paths, mustWork = TRUE)
}

first_column <- function(columns, choices, required = TRUE, label = "column") {
  found <- choices[choices %in% columns]
  if (length(found)) return(found[[1]])
  if (required) stop(
    "Could not find ", label, ". Expected one of: ", paste(choices, collapse = ", "),
    call. = FALSE
  )
  NULL
}

longest_missing_run <- function(dates) {
  dates <- sort(unique(as.Date(dates[!is.na(dates)])))
  if (length(dates) < 2L) return(NA_integer_)
  max(c(0L, as.integer(diff(dates)) - 1L))
}

collapse_values <- function(value) {
  value <- sort(unique(clean_text(value)))
  value <- value[nzchar(value)]
  paste(value, collapse = "; ")
}

as_yes_no <- function(value) ifelse(isTRUE(value), "Yes", "No")
when <- function(test, text) if (isTRUE(test)) text else NULL

# ---- WRTDS rule trace ----

extract_rule_number <- function(lines, pattern, label) {
  hits <- grep(pattern, lines, perl = TRUE, value = TRUE)
  if (!length(hits)) stop("Could not trace ", label, " from the WRTDS code.", call. = FALSE)
  matched_rule <- regmatches(hits[[1]], regexpr(pattern, hits[[1]], perl = TRUE))
  number <- regmatches(matched_rule, regexpr("[0-9]+(?:\\.[0-9]+)?", matched_rule, perl = TRUE))
  value <- suppressWarnings(as.numeric(number))
  if (!is.finite(value)) stop("Invalid ", label, " in the WRTDS code.", call. = FALSE)
  value
}

trace_wrtds_rules <- function(step02_path, step03_path) {
  step02_path <- require_input_file(step02_path, "WRTDS wrangling script")
  step03_path <- require_input_file(step03_path, "WRTDS analysis script")
  step02 <- readLines(step02_path, warn = FALSE)
  step03 <- readLines(step03_path, warn = FALSE)

  wrangle_minimum <- extract_rule_number(step02, "filter\\(n\\s*<\\s*[0-9]+", "minimum observation count")
  analysis_minimum <- extract_rule_number(step03, "minNumObs\\s*=\\s*[0-9]+", "EGRET minimum observation count")
  minimum_uncensored <- extract_rule_number(step03, "minNumUncen\\s*=\\s*[0-9]+", "EGRET minimum uncensored count")
  maximum_censored_fraction <- extract_rule_number(
    step02, "Below_BDL.*>=\\s*[0-9]+(?:\\.[0-9]+)?", "maximum censored fraction"
  )
  if (maximum_censored_fraction > 1) maximum_censored_fraction <- maximum_censored_fraction / 100
  long_gap_review_days <- extract_rule_number(step02, "filter\\(\\.n\\s*>\\s*[0-9]+", "long discharge-gap review threshold")
  q_buffer_year_days <- extract_rule_number(step02, "365\\.25", "pre-chemistry discharge buffer")
  q_followup_fraction <- extract_rule_number(step02, "0\\.25\\s*\\*\\s*365", "post-chemistry discharge buffer")

  required_checks <- c(
    use_wrtds_gate = any(grepl('filter\\(Use_WRTDS == "yes"\\)', step02)),
    strict_chemistry_crop = any(grepl("Date > min_date & Date < max_date", step02, fixed = TRUE)),
    internal_gap_interpolation = any(grepl("na.approx", step02, fixed = TRUE)),
    dsi_unit_conversion = any(grepl('variable == "DSi"', step02, fixed = TRUE)),
    mdl_name_rewrite = any(grepl('gsub\\("MDL', step02)),
    q_buffer_extra_day = any(grepl("365.25)) - 1", step02, fixed = TRUE)),
    q_followup_days = any(grepl("0.25*365", step02, fixed = TRUE))
  )
  if (!all(required_checks)) {
    stop(
      "The WRTDS code no longer matches the audited workflow rules: ",
      paste(names(required_checks)[!required_checks], collapse = ", "),
      call. = FALSE
    )
  }
  if (wrangle_minimum != analysis_minimum) {
    stop(
      "WRTDS observation thresholds disagree between wrangling and analysis: ",
      wrangle_minimum, " versus ", analysis_minimum, ".",
      call. = FALSE
    )
  }

  if (!requireNamespace("EGRET", quietly = TRUE)) {
    stop("The EGRET package is required to verify its strict sample-count checks.", call. = FALSE)
  }
  egret_code <- paste(deparse(body(get("runSurvReg", asNamespace("EGRET")))), collapse = "\n")
  egret_checks <- c(
    grepl("minNumObs >= nrow(localSample)", egret_code, fixed = TRUE),
    grepl("minNumUncen >= sum(localSample$Uncen)", egret_code, fixed = TRUE)
  )
  if (!all(egret_checks)) {
    stop("The installed EGRET sample-count checks no longer match this audit.", call. = FALSE)
  }

  list(
    observation_setting = as.integer(analysis_minimum),
    uncensored_setting = as.integer(minimum_uncensored),
    minimum_observations = as.integer(analysis_minimum + 1L),
    minimum_uncensored = as.integer(minimum_uncensored + 1L),
    maximum_censored_fraction = maximum_censored_fraction,
    long_gap_review_days = as.integer(long_gap_review_days),
    q_buffer_start_days = q_buffer_year_days + 1,
    q_buffer_end_days = q_followup_fraction * 365,
    step02_md5 = unname(tools::md5sum(step02_path)),
    step03_md5 = unname(tools::md5sum(step03_path)),
    egret_version = as.character(utils::packageVersion("EGRET"))
  )
}

# ---- Input readers ----

unit_is_umol_l <- function(unit) {
  normalized <- tolower(clean_text(unit))
  normalized <- chartr("µμ", "uu", normalized)
  normalized <- gsub("[^a-z0-9/]", "", normalized)
  normalized %in% c(
    "um", "umol/l", "umoll", "umoll1", "umolperl", "micromolar",
    "micromol/l", "micromoll"
  )
}

mapping_is_approved <- function(status) {
  status <- tolower(clean_text(status))
  allowed <- trimws(paste(rep(c("approved", "complete", "verified", "final"), each = 2L),
                          rep(c("", "mapping"), 4L)))
  status %in% allowed
}

read_chemistry_key <- function(path, selected_lters, variable_name) {
  if (is.null(path) || !nzchar(path)) return(NULL)
  key <- read_general_table(path)
  assert_required_columns(key, c(
    "LTER", "Stream_Name", "variable", "units", "Analyte_Group",
    "master_variable", "master_units", "mapping_status", "conversion_basis"
  ), "chemistry key")
  key$Match_LTER <- normalize_lter(key$LTER)
  key$Stream_Name <- clean_text(key$Stream_Name)
  analyte_group <- tolower(clean_text(key$Analyte_Group))
  silica_name <- grepl("silica|sio2|h4sio4", key$variable, ignore.case = TRUE) |
    tolower(clean_text(key$variable)) == "si"
  keep <- key$Match_LTER %in% selected_lters & if (variable_name == "DSi") {
    analyte_group %in% c("si", "silica/silicon") | silica_name
  } else clean_text(key$master_variable) == variable_name
  key <- key[keep, , drop = FALSE]
  out <- data.frame(
    Match_LTER = key$Match_LTER,
    Stream_Name = key$Stream_Name,
    Source_Variable = clean_text(key$variable),
    Source_Unit = clean_text(key$units),
    Mapping_Status = clean_text(key$mapping_status),
    Conversion_Basis = clean_text(key$conversion_basis),
    Basis_Approved = mapping_is_approved(key$mapping_status) &
      clean_text(key$master_variable) == variable_name &
      unit_is_umol_l(key$master_units) &
      nzchar(clean_text(key$conversion_basis)),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  match_key <- paste(out$Match_LTER, out$Stream_Name, tolower(out$Source_Variable),
                     tolower(out$Source_Unit), sep = "\r")
  if (anyDuplicated(match_key)) stop("Chemistry-key source mappings are not unique.", call. = FALSE)
  out
}

read_chemistry_file <- function(path, selected_lters, variable_name, chemistry_key) {
  columns <- names(data.table::fread(path, nrows = 0L, check.names = FALSE, showProgress = FALSE))
  field <- list(
    lter = first_column(columns, "LTER", label = "chemistry LTER column"),
    stream = first_column(columns, "Stream_Name", label = "chemistry stream column"),
    date = first_column(columns, c("date", "Date"), label = "chemistry date column"),
    variable = first_column(columns, c("variable", "Variable"), label = "chemistry variable column"),
    unit = first_column(columns, c("units", "Units", "unit"), FALSE),
    value = first_column(columns, c("value", "Value", "value_mgL"), label = "chemistry value column"),
    remark = first_column(columns, c("remarks", "Remark", "remark"), FALSE)
  )
  data <- data.table::fread(path, select = unique(unlist(field)), check.names = FALSE,
                            data.table = FALSE, showProgress = FALSE)
  out <- data.frame(
    Match_LTER = normalize_lter(data[[field$lter]]),
    Stream_Name = clean_text(data[[field$stream]]),
    Date = as.Date(data[[field$date]]),
    Variable = clean_text(data[[field$variable]]),
    Source_Variable = clean_text(data[[field$variable]]),
    Unit = if (is.null(field$unit)) "" else clean_text(data[[field$unit]]),
    Value = suppressWarnings(as.numeric(data[[field$value]])),
    Remark = if (is.null(field$remark)) "" else clean_text(data[[field$remark]]),
    Censor_Source_Available = !is.null(field$remark),
    Chemistry_Source_File = path,
    check.names = FALSE
  )
  keep <- out$Match_LTER %in% selected_lters & !is.na(out$Date) &
    is.finite(out$Value) & out$Value >= 0
  out <- out[keep, , drop = FALSE]

  if (!is.null(chemistry_key)) {
    row_key <- paste(out$Match_LTER, out$Stream_Name, tolower(out$Source_Variable),
                     tolower(out$Unit), sep = "\r")
    source_key <- paste(chemistry_key$Match_LTER, chemistry_key$Stream_Name,
                        tolower(chemistry_key$Source_Variable),
                        tolower(chemistry_key$Source_Unit), sep = "\r")
    matched <- match(row_key, source_key)
    direct <- out$Variable == variable_name
    possible_silica <- variable_name == "DSi" & (
      grepl("silica|sio2|h4sio4", out$Source_Variable, ignore.case = TRUE) |
        tolower(clean_text(out$Source_Variable)) == "si"
    )
    unmatched_silica <- possible_silica & !direct & is.na(matched)
    if (any(unmatched_silica)) {
      stop("Silica source rows lack an exact chemistry-key mapping in ", path, ": ",
           paste(sort(unique(out$Source_Variable[unmatched_silica])), collapse = ", "),
           call. = FALSE)
    }
    keep <- direct | !is.na(matched)
    out <- out[keep, , drop = FALSE]
    matched <- matched[keep]
    out$Mapping_Status <- rep("Direct standardized variable", nrow(out))
    out$Conversion_Basis <- rep("Input already uses the requested variable", nrow(out))
    out$Basis_Approved <- rep(TRUE, nrow(out))
    mapped <- !is.na(matched)
    out$Variable <- variable_name
    out$Mapping_Status[mapped] <- chemistry_key$Mapping_Status[matched[mapped]]
    out$Conversion_Basis[mapped] <- chemistry_key$Conversion_Basis[matched[mapped]]
    out$Basis_Approved[mapped] <- chemistry_key$Basis_Approved[matched[mapped]]
  } else {
    out <- out[out$Variable == variable_name, , drop = FALSE]
    out$Mapping_Status <- rep("Direct standardized variable", nrow(out))
    out$Conversion_Basis <- rep("Input already uses the requested variable", nrow(out))
    out$Basis_Approved <- rep(TRUE, nrow(out))
  }
  out
}

read_chemistry_inputs <- function(files, selected_lters, variable_name, chemistry_key) {
  if (!length(files)) {
    return(data.frame(Match_LTER = character(), Stream_Name = character(),
      Date = as.Date(character()), Variable = character(), Source_Variable = character(),
      Unit = character(), Value = numeric(), Remark = character(), Mapping_Status = character(),
      Conversion_Basis = character(), Basis_Approved = logical(),
      Censor_Source_Available = logical(), Chemistry_Source_File = character()))
  }
  pieces <- lapply(files, read_chemistry_file, selected_lters, variable_name, chemistry_key)
  out <- data.table::rbindlist(pieces, fill = TRUE, use.names = TRUE)
  if (!nrow(out)) return(as.data.frame(out))
  out <- out[, .(
    Value = mean(Value, na.rm = TRUE),
    Remark = if (any(Remark == "<")) "<" else "",
    Mapping_Status = collapse_values(Mapping_Status),
    Conversion_Basis = collapse_values(Conversion_Basis),
    Basis_Approved = all(Basis_Approved),
    Censor_Source_Available = all(Censor_Source_Available),
    Chemistry_Source_File = paste(sort(unique(Chemistry_Source_File)), collapse = "; ")
  ), by = .(Match_LTER, Stream_Name, Date, Variable, Source_Variable, Unit)]
  as.data.frame(out)
}

read_discharge_file <- function(path, wanted_names) {
  columns <- names(data.table::fread(path, nrows = 0L, check.names = FALSE, showProgress = FALSE))
  date_column <- first_column(columns, c("Date", "date"), label = "discharge date column")
  q_column <- first_column(columns, c("Qcms", "Q"), label = "discharge value column")
  name_column <- first_column(columns, "Discharge_File_Name", FALSE)
  data <- data.table::fread(path, select = unique(c(date_column, q_column, name_column)),
                            check.names = FALSE, data.table = FALSE, showProgress = FALSE)
  discharge_name <- if (is.null(name_column)) {
    rep(normalize_discharge_name(path), nrow(data))
  } else {
    normalize_discharge_name(data[[name_column]])
  }
  out <- data.frame(
    Discharge_File_Name = discharge_name,
    Date = as.Date(data[[date_column]]),
    Qcms = suppressWarnings(as.numeric(data[[q_column]])),
    Discharge_Source_File = path,
    check.names = FALSE
  )
  keep <- out$Discharge_File_Name %in% wanted_names & !is.na(out$Date) & is.finite(out$Qcms)
  out[keep, , drop = FALSE]
}

read_discharge_inputs <- function(files, wanted_names) {
  wanted_names <- unique(normalize_discharge_name(wanted_names))
  wanted_names <- wanted_names[nzchar(wanted_names)]
  if (!length(files) || !length(wanted_names)) {
    return(data.frame(Discharge_File_Name = character(), Date = as.Date(character()),
                      Qcms = numeric(), Discharge_Source_File = character()))
  }
  pieces <- lapply(files, read_discharge_file, wanted_names)
  out <- data.table::rbindlist(pieces, fill = TRUE, use.names = TRUE)
  if (!nrow(out)) return(as.data.frame(out))
  out <- out[, .(
    Qcms = mean(Qcms, na.rm = TRUE),
    Discharge_Source_File = paste(sort(unique(Discharge_Source_File)), collapse = "; ")
  ), by = .(Discharge_File_Name, Date)]
  as.data.frame(out)
}

apply_discharge_updates <- function(sites, path) {
  assigned <- nzchar(sites$Discharge_File_Name)
  sites$Pairing_Review_Status <- ifelse(assigned,
    "Existing Site Reference assignment; not rechecked by this run", "Missing")
  sites$Pairing_Distance_km <- NA_real_
  sites$Discharge_Link_Source <- ifelse(assigned, "Site Reference", "Missing")
  if (is.null(path) || !nzchar(path)) return(sites)
  updates <- read_general_table(path)
  assert_required_columns(
    updates,
    c(
      "Live_LTER", "Stream_Name", "Discharge_File_Name", "Units",
      "Discharge_Site_Name", "Pairing_Distance_km"
    ),
    "discharge update table"
  )
  update_key <- paste(normalize_lter(updates$Live_LTER), clean_text(updates$Stream_Name), sep = "\r")
  if (anyDuplicated(update_key)) stop("Discharge update keys are not unique.", call. = FALSE)
  site_key <- paste(sites$Match_LTER, sites$Stream_Name, sep = "\r")
  matched <- match(site_key, update_key)
  proposed <- normalize_discharge_name(updates$Discharge_File_Name[matched])
  use_update <- !is.na(matched) & nzchar(proposed)
  sites$Discharge_File_Name[use_update] <- proposed[use_update]
  sites$Units[use_update] <- clean_text(updates$Units[matched[use_update]])
  sites$Discharge_Site_Name[use_update] <- clean_text(updates$Discharge_Site_Name[matched[use_update]])
  sites$Pairing_Distance_km[use_update] <- suppressWarnings(
    as.numeric(updates$Pairing_Distance_km[matched[use_update]]))
  sites$Discharge_Link_Source[use_update] <- "Reviewed staged update"
  sites$Pairing_Review_Status[use_update] <- "Reviewed staged assignment"
  sites
}

# ---- Eligibility evaluation ----

flowing_water <- function(value) {
  normalized <- tolower(clean_text(value))
  normalized %in% c(
    "river", "stream", "creek", "brook", "river or stream", "outlet", "lake outlet"
  )
}

evaluate_one_site <- function(site, chemistry, discharge, rules, variable_name) {
  chem <- chemistry[
    chemistry$Match_LTER == site$Match_LTER &
      chemistry$Stream_Name == site$Stream_Name,
    ,
    drop = FALSE
  ]
  q_name <- normalize_discharge_name(site$Discharge_File_Name)
  q_units <- clean_text(site$Units)
  q_units_verified <- tolower(q_units) == "cms"
  pairing_status <- clean_text(site$Pairing_Review_Status)
  pairing_evidence <- nzchar(pairing_status) && pairing_status != "Missing"
  q <- discharge[discharge$Discharge_File_Name == q_name, , drop = FALSE]
  q <- q[order(q$Date), , drop = FALSE]
  q_source_files <- collapse_values(q$Discharge_Source_File)
  chemistry_source_files <- collapse_values(chem$Chemistry_Source_File)

  area <- suppressWarnings(as.numeric(site$drainSqKm))
  has_area <- length(area) && is.finite(area) && area > 0
  is_flowing <- flowing_water(site$Waterbody)
  has_q_name <- nzchar(q_name)
  has_q <- nrow(q) >= 2L && length(unique(q$Date)) >= 2L
  q_full_start <- if (nrow(q)) min(q$Date) else as.Date(NA)
  q_full_end <- if (nrow(q)) max(q$Date) else as.Date(NA)
  q_full_negative <- if (nrow(q)) sum(q$Qcms < 0, na.rm = TRUE) else 0L
  q_full_zero <- if (nrow(q)) sum(q$Qcms == 0, na.rm = TRUE) else 0L
  q_full_longest_gap <- if (has_q) longest_missing_run(q$Date) else NA_integer_
  chem_start <- if (nrow(chem)) min(chem$Date) else as.Date(NA)
  chem_end <- if (nrow(chem)) max(chem$Date) else as.Date(NA)
  q_window_requested_start <- if (nrow(chem)) {
    chem_start - rules$q_buffer_start_days
  } else {
    as.Date(NA)
  }
  q_window_requested_end <- if (nrow(chem)) {
    chem_end + rules$q_buffer_end_days
  } else {
    as.Date(NA)
  }
  q_wrtds <- if (has_q && nrow(chem)) {
    q[q$Date > q_window_requested_start & q$Date <= q_window_requested_end, , drop = FALSE]
  } else {
    q[0, , drop = FALSE]
  }
  has_q_window <- nrow(q_wrtds) >= 2L && length(unique(q_wrtds$Date)) >= 2L
  q_start <- if (nrow(q_wrtds)) min(q_wrtds$Date) else as.Date(NA)
  q_end <- if (nrow(q_wrtds)) max(q_wrtds$Date) else as.Date(NA)
  q_negative <- if (nrow(q_wrtds)) sum(q_wrtds$Qcms < 0, na.rm = TRUE) else 0L
  q_zero <- if (nrow(q_wrtds)) sum(q_wrtds$Qcms == 0, na.rm = TRUE) else 0L
  q_missing_days <- if (has_q_window) {
    as.integer(q_end - q_start) + 1L - length(unique(q_wrtds$Date))
  } else {
    NA_integer_
  }
  q_longest_gap <- if (has_q_window) longest_missing_run(q_wrtds$Date) else NA_integer_
  in_q_range <- if (has_q && nrow(chem)) {
    chem$Date > q_full_start & chem$Date < q_full_end
  } else {
    rep(FALSE, nrow(chem))
  }
  chem_in_range <- chem[in_q_range, , drop = FALSE]
  observations <- length(unique(chem_in_range$Date))
  observation_gate <- observations >= rules$minimum_observations
  chemistry_years <- length(unique(format(chem_in_range$Date, "%Y")))
  year_gate <- chemistry_years >= rules$project_minimum_dsi_years
  unit_values <- unique(clean_text(chem_in_range$Unit))
  unit_values <- unit_values[nzchar(unit_values)]
  source_variables <- collapse_values(chem_in_range$Source_Variable)
  basis_status <- collapse_values(chem_in_range$Mapping_Status)
  basis_verified <- nrow(chem_in_range) > 0L && all(chem_in_range$Basis_Approved)
  units_verified <- basis_verified &&
    length(unit_values) > 0L &&
    all(unit_is_umol_l(unit_values))

  source_remarks_column <- nrow(chem_in_range) > 0L &&
    all(chem_in_range$Censor_Source_Available)
  mdl_column <- if (variable_name == "DSi") {
    "MDL_Si_mgL"
  } else {
    paste0("MDL_", variable_name, "_mgL")
  }
  mdl_available <- mdl_column %in% names(site) &&
    is.finite(suppressWarnings(as.numeric(site[[mdl_column]])))
  corrected_mdl_available <- mdl_available && units_verified
  current_wrtds_censoring_applied <- variable_name != "DSi"
  censor_verified <- FALSE
  if (source_remarks_column) {
    source_censored_dates <- unique(chem_in_range$Date[chem_in_range$Remark == "<"])
    censored_count <- length(source_censored_dates)
    uncensored_count <- observations - censored_count
  } else {
    censored_count <- NA_integer_
    uncensored_count <- NA_integer_
  }
  censored_fraction <- if (source_remarks_column && observations > 0L) {
    censored_count / observations
  } else {
    NA_real_
  }
  uncensored_count_gate <- if (source_remarks_column) {
    uncensored_count >= rules$minimum_uncensored
  } else {
    NA
  }
  censored_fraction_gate <- if (source_remarks_column) {
    censored_fraction < rules$maximum_censored_fraction
  } else {
    NA
  }
  uncensored_gate <- censor_verified &&
    isTRUE(uncensored_count_gate) &&
    isTRUE(censored_fraction_gate)
  current_code_uncensored_gate <- observations >= rules$minimum_uncensored

  one_year_buffer <- has_q && nrow(chem) && q_full_start <= chem_start - 366
  covers_chemistry <- has_q && nrow(chem) && q_full_start < chem_start && q_full_end > chem_end
  long_gap <- is.finite(q_longest_gap) && q_longest_gap > rules$long_gap_review_days

  mechanical_fail <- c(
    when(!has_area, "missing positive drainage area"),
    when(!has_q_name, "no discharge file assigned"),
    when(has_q_name && !has_q, "assigned discharge series not found or too short"),
    when(has_q_name && !q_units_verified, "discharge units are not recorded as cms"),
    when(has_q_name && !pairing_evidence, "no discharge-pairing evidence is recorded"),
    when(has_q && nrow(chem) && !has_q_window, "fewer than two discharge dates in the WRTDS crop window"),
    when(q_negative > 0L, paste0(q_negative, " negative daily discharge values")),
    when(!nrow(chem), paste0("no ", variable_name, " chemistry records in supplied inputs")),
    when(
      nrow(chem) && !observation_gate,
      paste0(observations, " in-range observations; ", rules$minimum_observations, " required")
    )
  )
  mechanical_pass <- !length(mechanical_fail)

  review_flags <- c(
    when(!is_flowing, "not a flowing-water site"),
    when(mechanical_pass && !basis_verified, "DSi analyte basis or conversion is not approved"),
    when(
      mechanical_pass && !units_verified,
      "DSi units are missing or incompatible with the current micromolar conversion"
    ),
    when(mechanical_pass && !censor_verified, "censor fraction and uncensored count are not verified"),
    when(
      mechanical_pass && source_remarks_column && censored_count > 0L,
      "source censor flags are present but the current WRTDS input path does not preserve them"
    ),
    when(
      mechanical_pass && !year_gate,
      paste0(chemistry_years, " DSi years; project QA requires ",
             rules$project_minimum_dsi_years, " for automatic advancement")
    ),
    when(
      mechanical_pass && corrected_mdl_available && variable_name == "DSi",
      "MDL_Si_mgL is available, but the current WRTDS join maps it to Si rather than DSi"
    ),
    when(mechanical_pass && q_zero > 0L, paste0(q_zero, " zero-flow days would trigger EGRET's discharge adjustment")),
    when(mechanical_pass && long_gap, paste0(q_longest_gap, "-day discharge gap would be linearly interpolated"))
  )
  qa_warnings <- c(
    when(mechanical_pass && !one_year_buffer, "less than one year of discharge before chemistry"),
    when(mechanical_pass && !covers_chemistry, "discharge does not extend beyond the full chemistry range")
  )

  verified_ready <- mechanical_pass &&
    is_flowing &&
    q_negative == 0L &&
    units_verified &&
    censor_verified &&
    isTRUE(uncensored_gate) &&
    year_gate &&
    q_zero == 0L &&
    !long_gap
  candidate_after_review <- mechanical_pass && is_flowing && q_negative == 0L
  status <- if (verified_ready) "Ready" else if (mechanical_pass) "Hold for review" else "Not runnable"
  reason <- paste(c(mechanical_fail, review_flags), collapse = "; ")
  if (!nzchar(reason)) reason <- "All audited requirements pass"
  warning_text <- paste(qa_warnings, collapse = "; ")

  data.frame(
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Current_Use_WRTDS = clean_text(site$Use_WRTDS),
    Recommended_Use_WRTDS = ifelse(verified_ready, "Yes", "No"),
    Decision_Status = status,
    Candidate_After_Review = as_yes_no(candidate_after_review),
    Decision_Reason = reason,
    QA_Warnings = warning_text,
    Waterbody = clean_text(site$Waterbody),
    Flowing_Water = as_yes_no(is_flowing),
    drainSqKm = if (has_area) area else NA_real_,
    Drainage_Area_Present = as_yes_no(has_area),
    Discharge_File_Name = q_name,
    Discharge_Units = q_units,
    Discharge_Units_Verified = as_yes_no(q_units_verified),
    Discharge_Site_Name = clean_text(site$Discharge_Site_Name),
    Pairing_Review_Status = pairing_status,
    Pairing_Distance_km = suppressWarnings(as.numeric(site$Pairing_Distance_km)),
    Discharge_Link_Source = site$Discharge_Link_Source,
    Discharge_Source_Files = q_source_files,
    Discharge_Series_Found = as_yes_no(has_q),
    Q_Full_Start = q_full_start,
    Q_Full_End = q_full_end,
    Q_Full_Daily_Records = nrow(q),
    Q_Full_Longest_Gap_Days = q_full_longest_gap,
    Q_Full_Negative_Days = q_full_negative,
    Q_Full_Zero_Days = q_full_zero,
    WRTDS_Q_Window_Requested_Start = q_window_requested_start,
    WRTDS_Q_Window_Requested_End = q_window_requested_end,
    WRTDS_Q_Window_Found = as_yes_no(has_q_window),
    Q_Start = q_start,
    Q_End = q_end,
    Q_Daily_Records = nrow(q_wrtds),
    Q_Missing_Internal_Days = q_missing_days,
    Q_Longest_Gap_Days = q_longest_gap,
    Q_Negative_Days = q_negative,
    Q_Zero_Days = q_zero,
    One_Year_Prechemistry_Q_Buffer = as_yes_no(one_year_buffer),
    Q_Extends_Beyond_Chemistry = as_yes_no(covers_chemistry),
    Chemistry_Variable = variable_name,
    Chemistry_Source_Files = chemistry_source_files,
    Chemistry_Records = nrow(chem),
    Chemistry_First_Date = chem_start,
    Chemistry_Last_Date = chem_end,
    Chemistry_Dates_Within_Q_Range = observations,
    Chemistry_Distinct_Years = chemistry_years,
    Project_Minimum_DSi_Years = rules$project_minimum_dsi_years,
    Project_Year_Rule_Source = "SiSyn QA policy; not enforced by the WRTDS code",
    Project_Year_Gate = ifelse(year_gate, "Pass", "Fail"),
    Chemistry_Source_Variables = source_variables,
    Chemistry_Units = collapse_values(unit_values),
    Chemistry_Basis_Status = basis_status,
    DSi_Basis_Approved = as_yes_no(basis_verified),
    DSi_Units_Code_Compatible = as_yes_no(units_verified),
    Censoring_Verified = as_yes_no(censor_verified),
    Source_Remarks_Column_Present = as_yes_no(source_remarks_column),
    MDL_Field = mdl_column,
    Corrected_MDL_Available = as_yes_no(corrected_mdl_available),
    Current_WRTDS_MDL_Key_Matches = ifelse(variable_name == "DSi", "No", "Yes"),
    Current_WRTDS_Censoring_Applied = as_yes_no(current_wrtds_censoring_applied),
    Current_Code_Assumed_Uncensored_Gate = ifelse(
      current_code_uncensored_gate,
      "Pass",
      "Fail"
    ),
    Source_Uncensored_Dates = uncensored_count,
    Source_Censored_Dates = censored_count,
    Source_Censored_Fraction = censored_fraction,
    Total_Observation_Gate = ifelse(observation_gate, "Pass", "Fail"),
    Source_Uncensored_Count_Gate = if (is.na(uncensored_count_gate)) {
      "Unknown"
    } else ifelse(uncensored_count_gate, "Pass", "Fail"),
    Source_Censored_Fraction_Gate = if (is.na(censored_fraction_gate)) {
      "Unknown"
    } else ifelse(censored_fraction_gate, "Pass", "Fail"),
    Mechanical_Code_Gates = ifelse(mechanical_pass, "Pass", "Fail"),
    WRTDS_MinNumObs_Setting = rules$observation_setting,
    WRTDS_MinNumUncen_Setting = rules$uncensored_setting,
    WRTDS_Minimum_Observations = rules$minimum_observations,
    WRTDS_Minimum_Uncensored = rules$minimum_uncensored,
    WRTDS_Maximum_Censored_Fraction = rules$maximum_censored_fraction,
    WRTDS_Q_Gap_Behavior = "All internal gaps are linearly interpolated; no maximum gap is enforced",
    WRTDS_Step02_MD5 = rules$step02_md5,
    WRTDS_Step03_MD5 = rules$step03_md5,
    Eligibility_Script_MD5 = rules$eligibility_script_md5,
    EGRET_Version = rules$egret_version,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

evaluate_sites <- function(sites, chemistry, discharge, rules, variable_name) {
  rows <- lapply(seq_len(nrow(sites)), function(index) {
    evaluate_one_site(sites[index, , drop = FALSE], chemistry, discharge, rules, variable_name)
  })
  data.table::rbindlist(rows, fill = TRUE, use.names = TRUE)
}

# ---- Self-test ----

run_self_test <- function(rules) {
  site_names <- c(
    "ready", "exactly45", "uncensored45", "censor33", "short_years",
    "gap_outside", "gap_inside", "negative_outside", "negative_inside",
    "zero_outside", "zero_inside", "reservoir"
  )
  sites <- data.frame(
    LTER = rep("TEST", length(site_names)),
    Match_LTER = rep("TEST", length(site_names)),
    Stream_Name = site_names,
    Use_WRTDS = rep("", length(site_names)),
    Waterbody = ifelse(site_names == "reservoir", "Reservoir", "Stream"),
    drainSqKm = rep(100, length(site_names)),
    Discharge_File_Name = paste0(site_names, "_Q"),
    Units = "cms",
    Discharge_Site_Name = paste(site_names, "gauge"),
    Discharge_Link_Source = "Self-test",
    Pairing_Review_Status = "Self-test pairing",
    Pairing_Distance_km = 0,
    stringsAsFactors = FALSE
  )
  five_year_dates <- function(count) {
    as.Date("2000-01-01") + round(seq(0, 5 * 365, length.out = count))
  }
  chemistry <- do.call(rbind, lapply(seq_len(nrow(sites)), function(index) {
    site_name <- sites$Stream_Name[[index]]
    count <- switch(
      site_name,
      exactly45 = 45L,
      uncensored45 = 50L,
      censor33 = 100L,
      50L
    )
    censored <- switch(
      site_name,
      uncensored45 = 5L,
      censor33 = 33L,
      0L
    )
    dates <- if (site_name == "short_years") {
      as.Date("2000-01-01") + seq_len(count)
    } else {
      five_year_dates(count)
    }
    data.frame(
      Match_LTER = "TEST",
      Stream_Name = site_name,
      Date = dates,
      Variable = "DSi",
      Source_Variable = "DSi",
      Unit = "uM",
      Value = 100,
      Remark = c(rep("<", censored), rep("", count - censored)),
      Mapping_Status = "Approved",
      Conversion_Basis = "Self-test",
      Basis_Approved = TRUE,
      Censor_Source_Available = TRUE,
      Chemistry_Source_File = "self-test",
      stringsAsFactors = FALSE
    )
  }))
  discharge <- do.call(rbind, lapply(site_names, function(site_name) {
    dates <- seq(as.Date("1980-01-01"), as.Date("2010-12-31"), by = "day")
    q <- rep(1, length(dates))
    if (site_name == "gap_outside") {
      keep <- dates < as.Date("1982-01-01") | dates > as.Date("1984-12-31")
      dates <- dates[keep]
      q <- q[keep]
    }
    if (site_name == "gap_inside") {
      keep <- dates < as.Date("2001-01-01") | dates > as.Date("2002-12-31")
      dates <- dates[keep]
      q <- q[keep]
    }
    if (site_name == "negative_outside") q[dates == as.Date("1981-01-01")] <- -1
    if (site_name == "negative_inside") q[dates == as.Date("2003-01-01")] <- -1
    if (site_name == "zero_outside") q[dates == as.Date("1981-01-01")] <- 0
    if (site_name == "zero_inside") q[dates == as.Date("2003-01-01")] <- 0
    data.frame(
      Discharge_File_Name = paste0(site_name, "_Q"),
      Date = dates,
      Qcms = q,
      Discharge_Source_File = "self-test",
      stringsAsFactors = FALSE
    )
  }))
  result <- as.data.frame(evaluate_sites(sites, chemistry, discharge, rules, "DSi"))
  row <- function(name) result[result$Stream_Name == name, , drop = FALSE]
  stopifnot(
    row("ready")$Candidate_After_Review == "Yes",
    row("ready")$Decision_Status == "Hold for review",
    row("ready")$Project_Year_Gate == "Pass",
    row("exactly45")$Decision_Status == "Not runnable",
    row("uncensored45")$Source_Uncensored_Count_Gate == "Fail",
    row("censor33")$Source_Censored_Fraction_Gate == "Fail",
    row("short_years")$Project_Year_Gate == "Fail",
    row("gap_outside")$Q_Full_Longest_Gap_Days > 365,
    row("gap_outside")$Q_Longest_Gap_Days == 0,
    row("gap_inside")$Q_Longest_Gap_Days > 365,
    row("negative_outside")$Q_Full_Negative_Days == 1,
    row("negative_outside")$Q_Negative_Days == 0,
    row("negative_inside")$Decision_Status == "Not runnable",
    row("zero_outside")$Q_Full_Zero_Days == 1,
    row("zero_outside")$Q_Zero_Days == 0,
    row("zero_inside")$Q_Zero_Days == 1,
    row("reservoir")$Flowing_Water == "No",
    all(unit_is_umol_l(c("uM", "µmol/L", "μmol L-1", "micromolar"))),
    !unit_is_umol_l("umol"),
    mapping_is_approved("approved"),
    !mapping_is_approved("not approved")
  )
  message("WRTDS eligibility self-test passed.")
  invisible(TRUE)
}

# ---- Run ----

variable_name <- cli_value(args, "--variable", "DSi")
if (variable_name != "DSi") stop("This eligibility audit currently supports only DSi.", call. = FALSE)
minimum_dsi_years <- suppressWarnings(as.integer(cli_value(args, "--minimum-dsi-years", "5")))
if (!is.finite(minimum_dsi_years) || minimum_dsi_years < 1L) stop(
  "--minimum-dsi-years must be a positive integer.", call. = FALSE)
default_wrtds_root <- file.path(dirname(repo_root), "lterwg-silica-data")
step02_path <- cli_value(args, "--wrtds-step02",
                         file.path(default_wrtds_root, "01-wrtds-step02-wrangling.R"))
step03_path <- cli_value(args, "--wrtds-step03",
                         file.path(default_wrtds_root, "01-wrtds-step03_analysis.R"))
rules <- trace_wrtds_rules(step02_path, step03_path)
rules$project_minimum_dsi_years <- minimum_dsi_years
rules$eligibility_script_md5 <- unname(tools::md5sum(script_path))

if ("--self-test" %in% args) run_self_test(rules) else {
  site_reference_path <- cli_value(args, "--site-reference", required = TRUE)
  site_reference_sheet <- cli_value(args, "--site-reference-sheet", "")
  output_path <- cli_value(args, "--output", required = TRUE)
  overwrite <- cli_boolean(args, "--overwrite", FALSE)
  discharge_updates_path <- cli_value(args, "--discharge-updates", "")
  chemistry_key_path <- cli_value(args, "--chemistry-key", "")

  if (file.exists(output_path) && !overwrite) stop(
    "Output exists. Use --overwrite true to replace it: ", output_path, call. = FALSE)

  sites <- read_general_table(site_reference_path, site_reference_sheet)
  assert_required_columns(sites, c(
    "LTER", "Stream_Name", "Use_WRTDS", "Waterbody", "drainSqKm",
    "Discharge_File_Name", "Units", "Discharge_Site_Name"
  ), "site-reference table")
  sites <- sites[nzchar(clean_text(sites$LTER)) & nzchar(clean_text(sites$Stream_Name)), , drop = FALSE]
  sites$LTER <- clean_text(sites$LTER)
  sites$Stream_Name <- clean_text(sites$Stream_Name)
  sites$Match_LTER <- normalize_lter(sites$LTER)
  sites$Discharge_File_Name <- normalize_discharge_name(sites$Discharge_File_Name)
  if (anyDuplicated(paste(sites$LTER, sites$Stream_Name, sep = "\r"))) stop(
    "Site-reference LTER and Stream_Name keys are not unique.", call. = FALSE)
  sites <- apply_discharge_updates(select_site_rows(sites, args), discharge_updates_path)

  chemistry_files <- collect_input_files(cli_values(args, "--chemistry"),
    cli_values(args, "--chemistry-dir"), "chemistry")
  chemistry_key <- read_chemistry_key(chemistry_key_path, unique(sites$Match_LTER), variable_name)
  discharge_files <- collect_input_files(cli_values(args, "--discharge"),
    cli_values(args, "--discharge-dir"), "discharge")

  chemistry <- read_chemistry_inputs(chemistry_files, unique(sites$Match_LTER),
                                     variable_name, chemistry_key)
  discharge <- read_discharge_inputs(discharge_files, unique(sites$Discharge_File_Name))
  result <- as.data.frame(evaluate_sites(sites, chemistry, discharge, rules, variable_name))

  if (nrow(result) != nrow(sites) || anyDuplicated(paste(result$LTER, result$Stream_Name, sep = "\r"))) stop(
    "Eligibility output does not preserve one unique row per selected site.", call. = FALSE)
  if (!all(result$Recommended_Use_WRTDS %in% c("Yes", "No"))) stop(
    "Eligibility output contains an invalid WRTDS recommendation.", call. = FALSE)

  prepare_output_dir(output_path, is_file = TRUE)
  data.table::fwrite(result, output_path, sep = "\t", na = "", quote = FALSE)

  message("Wrote ", nrow(result), " site decisions to ", normalizePath(output_path),
    ". Ready: ", sum(result$Recommended_Use_WRTDS == "Yes"),
    "; hold: ", sum(result$Decision_Status == "Hold for review"),
    "; not runnable: ", sum(result$Decision_Status == "Not runnable"), ".")
}
