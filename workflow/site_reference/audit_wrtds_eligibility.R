# audit wrtds eligibility without changing the site-reference table

suppressPackageStartupMessages(library(data.table))

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_path <- if (length(script_arg)) {
  sub("^--file=", "", script_arg[[1]])
} else {
  file.path("workflow", "site_reference", "audit_wrtds_eligibility.R")
}
script_path <- normalizePath(script_path, mustWork = TRUE)
repo_root <- normalizePath(file.path(dirname(script_path), "..", ".."))
source(file.path(repo_root, "workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)

# ---- names and labels ----

clean_text <- function(value) {
  value <- trimws(as.character(value))
  value[is.na(value)] <- ""
  value[toupper(value) %in% c("NA", "N/A", "NULL")] <- ""
  value
}

# align old network names before matching site names
normalize_lter <- function(value) {
  aliases <- c(
    "CZO-Catalina Jemez" = "Catalina Jemez",
    "ECCC_Canada" = "Canada_ECCC",
    "Elbe" = "Germany",
    "Ipswitch(Carey)" = "PIE",
    "KRR(Julian)" = "KRR",
    "LMP(Wymore)" = "LMP",
    "Sagehen(Sullivan)" = "Sagehen",
    "UMR(Jankowski)" = "UMR",
    "WalkerBranch" = "Walker Branch",
    "DGA_Chile" = "Chile_DGA",
    "MLIT_Japan" = "Japan_MLIT",
    "RWS_Netherlands" = "Netherlands_RWS",
    "CAMELS_Switzerland" = "Switzerland_CAMELS_CH"
  )
  value <- clean_text(value)
  matched <- value %in% names(aliases)
  value[matched] <- unname(aliases[value[matched]])
  value
}

normalize_discharge_name <- function(value) {
  value <- basename(clean_text(value))
  sub("[.]csv$", "", value, ignore.case = TRUE)
}

as_yes_no <- function(value) ifelse(!is.na(value) & value, "Yes", "No")

normalize_decision <- function(value) {
  value <- tolower(clean_text(value))
  fifelse(value == "yes", "Yes", fifelse(value == "no", "No", ""))
}

validate_decision_values <- function(value, label) {
  entered <- tolower(clean_text(value))
  invalid <- nzchar(entered) & !entered %in% c("yes", "no")
  if (any(invalid)) {
    stop(
      label, " contains values other than Yes, No, or blank: ",
      paste(sort(unique(clean_text(value)[invalid])), collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

site_key <- function(lter, stream_name) {
  paste(tolower(normalize_lter(lter)), tolower(clean_text(stream_name)), sep = "\r")
}

collapse_text <- function(value) {
  value <- sort(unique(clean_text(value)))
  paste(value[nzchar(value)], collapse = "; ")
}

supported_q_unit <- function(value) {
  tolower(clean_text(value)) %in% c("cms", "cfs", "ls", "cmh", "cmd")
}

unit_is_umol_l <- function(value) {
  value <- tolower(clean_text(value))
  value <- chartr("µμ", "uu", value)
  value <- gsub("[^a-z0-9/]", "", value)
  value %in% c(
    "um", "umol/l", "umoll", "umoll1", "umolperl", "micromolar",
    "micromol/l", "micromoll"
  )
}

flowing_water <- function(value) {
  tolower(clean_text(value)) %in% c(
    "river", "stream", "creek", "brook", "river or stream", "outlet", "lake outlet"
  )
}

longest_consecutive_run <- function(years) {
  years <- sort(unique(as.integer(years[!is.na(years)])))
  if (!length(years)) return(0L)
  groups <- cumsum(c(TRUE, diff(years) != 1L))
  as.integer(max(tabulate(groups)))
}

# ---- input tables ----

read_general_table <- function(path, sheet = "") {
  path <- require_input_file(path)
  extension <- tolower(tools::file_ext(path))
  if (extension %in% c("xlsx", "xls")) {
    if (!requireNamespace("readxl", quietly = TRUE)) {
      stop("The readxl package is required for Excel input.", call. = FALSE)
    }
    if (!nzchar(sheet)) sheet <- readxl::excel_sheets(path)[[1]]
    return(as.data.frame(readxl::read_excel(path, sheet = sheet), check.names = FALSE))
  }
  separator <- if (extension == "csv") "," else "\t"
  data.table::fread(
    path,
    sep = separator,
    na.strings = NULL,
    check.names = FALSE,
    data.table = FALSE,
    showProgress = FALSE
  )
}

collect_files <- function(paths, directories, label) {
  paths <- clean_text(paths)
  paths <- paths[nzchar(paths)]
  for (directory in clean_text(directories)) {
    if (!dir.exists(directory)) stop("Missing ", label, " directory: ", directory, call. = FALSE)
    paths <- c(paths, list.files(
      directory,
      pattern = "[.]csv$",
      full.names = TRUE,
      recursive = TRUE,
      ignore.case = TRUE
    ))
  }
  paths <- unique(paths)
  missing <- paths[!file.exists(paths)]
  if (length(missing)) stop("Missing ", label, " file: ", missing[[1]], call. = FALSE)
  normalizePath(paths, mustWork = TRUE)
}

first_column <- function(columns, choices, label, required = TRUE) {
  found <- choices[choices %in% columns]
  if (length(found)) return(found[[1]])
  if (required) stop("Could not find ", label, ". Expected: ", paste(choices, collapse = ", "), call. = FALSE)
  NULL
}

# ---- site-reference input ----

read_sites <- function(path, sheet = "") {
  sites <- read_general_table(path, sheet)
  assert_required_columns(sites, c(
    "LTER", "Stream_Name", "Use_WRTDS", "Waterbody", "drainSqKm",
    "Discharge_File_Name", "Units"
  ), "site-reference table")
  optional <- c(
    "GlASS_First_Release", "CQ_Data_Version", "Spatial_Data_Version",
    "GlASS_2.0", "New-or-Updated_since-GlASS_2.0",
    "Alt_Stream_Name", "Original_Stream_Name", "New_Solute_Stream_Name",
    "Discharge_Site_Name", "MDL_Si_mgL"
  )
  for (column in setdiff(optional, names(sites))) sites[[column]] <- ""

  # ignore empty sheet rows but stop if a partly filled row lacks either site name
  lter_present <- nzchar(clean_text(sites$LTER))
  stream_present <- nzchar(clean_text(sites$Stream_Name))
  content_matrix <- vapply(sites, function(value) {
    nzchar(clean_text(value))
  }, logical(nrow(sites)))
  row_has_content <- if (nrow(sites)) rowSums(content_matrix) > 0L else logical()
  incomplete_key <- row_has_content & !(lter_present & stream_present)
  if (any(incomplete_key)) {
    stop(
      "Site-reference rows with content must include both LTER and Stream_Name. Source rows: ",
      paste(which(incomplete_key) + 1L, collapse = ", "),
      call. = FALSE
    )
  }
  sites <- sites[lter_present & stream_present, , drop = FALSE]
  validate_decision_values(sites$Use_WRTDS, "Site-reference Use_WRTDS")
  mdl_text <- clean_text(sites$MDL_Si_mgL)
  mdl_value <- suppressWarnings(as.numeric(mdl_text))
  invalid_mdl <- nzchar(mdl_text) & (!is.finite(mdl_value) | mdl_value < 0)
  if (any(invalid_mdl)) {
    stop("Site-reference MDL_Si_mgL contains invalid values.", call. = FALSE)
  }
  keys <- site_key(sites$LTER, sites$Stream_Name)
  if (anyDuplicated(keys)) {
    stop("The site-reference table contains duplicate LTER and Stream_Name rows.", call. = FALSE)
  }
  sites$Site_Row <- seq_len(nrow(sites))
  sites$Match_LTER <- normalize_lter(sites$LTER)
  sites$Discharge_File_Name <- normalize_discharge_name(sites$Discharge_File_Name)
  sites$Site_Reference_Use_WRTDS <- normalize_decision(sites$Use_WRTDS)
  sites$Decision_Reference_Use_WRTDS <- ""
  sites$Decision_Reference_Source <- ""
  sites$Decision_Reference_Conflict <- "No"
  sites$Decision_Check_Use_WRTDS <- ""
  sites$Decision_Confirmation_Status <- "Not checked"
  sites
}

# ---- cropping instructions ----

numeric_crop_value <- function(value) {
  suppressWarnings(as.numeric(clean_text(value)))
}

unparsed_crop_value <- function(value) {
  value <- clean_text(value)
  parsed <- numeric_crop_value(value)
  nzchar(value) & (!is.finite(parsed) | parsed != floor(parsed))
}

split_stream_id <- function(value) {
  value <- clean_text(value)
  double_separator <- regexpr("__", value, fixed = TRUE)
  single_separator <- regexpr("_", value, fixed = TRUE)
  separator <- ifelse(double_separator > 0L, double_separator, single_separator)
  width <- ifelse(double_separator > 0L, 2L, 1L)
  valid <- separator > 0L
  data.table(
    LTER = ifelse(valid, substr(value, 1L, separator - 1L), ""),
    Stream_Name = ifelse(valid, substr(value, separator + width, nchar(value)), "")
  )
}

collapse_crop_rows <- function(crops, label) {
  if (!nrow(crops)) return(crops)

  # repeated rows may agree but conflicting instructions require review
  conflicts <- crops[, .(
    Greater_Than_Values = uniqueN(Greater_Than[is.finite(Greater_Than)]),
    Less_Than_Values = uniqueN(Less_Than[is.finite(Less_Than)]),
    Remove_Values = uniqueN(Remove[nzchar(Remove)])
  ), by = Site_Key][
    Greater_Than_Values > 1L | Less_Than_Values > 1L | Remove_Values > 1L
  ]
  if (nrow(conflicts)) {
    stop(label, " contains conflicting duplicate site instructions.", call. = FALSE)
  }
  crops[, .(
    Greater_Than = if (any(is.finite(Greater_Than))) Greater_Than[is.finite(Greater_Than)][[1]] else NA_real_,
    Less_Than = if (any(is.finite(Less_Than))) Less_Than[is.finite(Less_Than)][[1]] else NA_real_,
    Remove = if (any(nzchar(Remove))) Remove[nzchar(Remove)][[1]] else "",
    BlankTime_Start = collapse_text(BlankTime_Start),
    BlankTime_End = collapse_text(BlankTime_End),
    Unparsed_Value = any(Unparsed_Value),
    Cropping_Row_Found = TRUE
  ), by = Site_Key]
}

reversed_crop_bounds <- function(greater_than, less_than) {
  greater_than <- numeric_crop_value(greater_than)
  less_than <- numeric_crop_value(less_than)
  is.finite(greater_than) & is.finite(less_than) & greater_than > less_than
}

year_is_in_crop <- function(year, greater_than, less_than, unparsed) {
  # keep data when a year instruction cannot be read so the audit can flag it
  unparsed |
    ((is.na(greater_than) | year >= greater_than) &
      (is.na(less_than) | year <= less_than))
}

read_chemistry_cropping <- function(path, sheet = "") {
  if (!nzchar(path)) return(data.table())
  crops <- read_general_table(path, sheet)
  assert_required_columns(
    crops,
    c("LTER", "Site", "variable", "Greater_Than", "Less_Than", "BlankTime_Start", "BlankTime_End"),
    "chemistry cropping table"
  )
  crops <- crops[tolower(clean_text(crops$variable)) == "dsi", , drop = FALSE]
  if (!nrow(crops)) return(data.table())
  collapse_crop_rows(data.table(
    Site_Key = site_key(crops$LTER, crops$Site),
    Greater_Than = numeric_crop_value(crops$Greater_Than),
    Less_Than = numeric_crop_value(crops$Less_Than),
    Remove = "",
    BlankTime_Start = clean_text(crops$BlankTime_Start),
    BlankTime_End = clean_text(crops$BlankTime_End),
    Unparsed_Value = unparsed_crop_value(crops$Greater_Than) |
      unparsed_crop_value(crops$Less_Than) |
      reversed_crop_bounds(crops$Greater_Than, crops$Less_Than)
  ), "Chemistry cropping table")
}

read_discharge_cropping <- function(path, sheet = "") {
  if (!nzchar(path)) return(data.table())
  crops <- read_general_table(path, sheet)
  assert_required_columns(
    crops, c("Stream_ID", "Greater_Than", "Less_Than", "Remove"), "discharge cropping table"
  )
  identifiers <- split_stream_id(crops$Stream_ID)
  collapse_crop_rows(data.table(
    Site_Key = site_key(identifiers$LTER, identifiers$Stream_Name),
    Greater_Than = numeric_crop_value(crops$Greater_Than),
    Less_Than = numeric_crop_value(crops$Less_Than),
    Remove = normalize_decision(crops$Remove),
    BlankTime_Start = "",
    BlankTime_End = "",
    Unparsed_Value = unparsed_crop_value(crops$Greater_Than) |
      unparsed_crop_value(crops$Less_Than) |
      reversed_crop_bounds(crops$Greater_Than, crops$Less_Than) |
      (!tolower(clean_text(crops$Remove)) %in% c("", "na", "yes", "no"))
  ), "Discharge cropping table")
}

attach_cropping <- function(sites, crops, prefix) {
  output <- data.table(
    Site_Row = sites$Site_Row,
    Site_Key = site_key(sites$LTER, sites$Stream_Name)
  )
  if (nrow(crops)) output <- merge(output, crops, by = "Site_Key", all.x = TRUE)
  if (!"Cropping_Row_Found" %in% names(output)) output[, Cropping_Row_Found := FALSE]
  for (column in c("Greater_Than", "Less_Than")) {
    if (!column %in% names(output)) output[, (column) := NA_real_]
  }
  for (column in c("Remove", "BlankTime_Start", "BlankTime_End")) {
    if (!column %in% names(output)) output[, (column) := ""]
    set(output, which(is.na(output[[column]])), column, "")
  }
  if (!"Unparsed_Value" %in% names(output)) output[, Unparsed_Value := FALSE]
  output[is.na(Cropping_Row_Found), Cropping_Row_Found := FALSE]
  output[is.na(Unparsed_Value), Unparsed_Value := FALSE]
  setnames(
    output,
    c(
      "Cropping_Row_Found", "Greater_Than", "Less_Than", "Remove",
      "BlankTime_Start", "BlankTime_End", "Unparsed_Value"
    ),
    paste0(prefix, c(
      "_Cropping_Row_Found", "_Crop_Greater_Than", "_Crop_Less_Than", "_Crop_Remove",
      "_BlankTime_Start", "_BlankTime_End", "_Crop_Unparsed_Value"
    ))
  )
  output[, Site_Key := NULL]
  output
}

apply_chemistry_cropping <- function(chemistry, cropping) {
  if (!nrow(chemistry) || !nrow(cropping)) return(chemistry)
  fields <- c(
    "Site_Row", "Chemistry_Crop_Greater_Than", "Chemistry_Crop_Less_Than",
    "Chemistry_Crop_Unparsed_Value"
  )
  chemistry <- merge(chemistry, cropping[, ..fields], by = "Site_Row", all.x = TRUE)
  chemistry[, Crop_Year := as.integer(format(Date, "%Y"))]
  chemistry <- chemistry[year_is_in_crop(
    Crop_Year,
    Chemistry_Crop_Greater_Than,
    Chemistry_Crop_Less_Than,
    Chemistry_Crop_Unparsed_Value
  )]
  chemistry[, c(
    "Chemistry_Crop_Greater_Than", "Chemistry_Crop_Less_Than",
    "Chemistry_Crop_Unparsed_Value", "Crop_Year"
  ) := NULL]
  chemistry
}

# ---- reviewed decisions ----

read_decision_reference <- function(path, sheet = "") {
  reference <- read_general_table(path, sheet)
  assert_required_columns(reference, c("LTER", "Stream_Name", "Use_WRTDS"), "decision reference")
  validate_decision_values(reference$Use_WRTDS, "Decision-reference Use_WRTDS")
  reference <- data.table(
    Site_Key = site_key(reference$LTER, reference$Stream_Name),
    Decision_Reference_Use_WRTDS = normalize_decision(reference$Use_WRTDS)
  )[nzchar(Site_Key) & nzchar(Decision_Reference_Use_WRTDS)]
  reference[, .(
    Decision_Reference_Use_WRTDS = if (uniqueN(Decision_Reference_Use_WRTDS) == 1L) {
      Decision_Reference_Use_WRTDS[[1]]
    } else "",
    Decision_Reference_Conflict = as_yes_no(uniqueN(Decision_Reference_Use_WRTDS) > 1L)
  ), by = Site_Key]
}

read_decision_check <- function(path, sheet = "") {
  check <- read_general_table(path, sheet)
  assert_required_columns(
    check,
    c("LTER", "Stream_Name", "Candidate_After_Review", "Mechanical_Code_Gates"),
    "decision check"
  )
  candidate <- tolower(clean_text(check$Candidate_After_Review))
  gate <- tolower(clean_text(check$Mechanical_Code_Gates))
  invalid_candidate <- nzchar(candidate) & !candidate %in% c("yes", "no")
  invalid_gate <- nzchar(gate) & !gate %in% c("pass", "fail")
  if (any(invalid_candidate) || any(invalid_gate)) {
    stop("Decision check contains invalid candidate or gate values.", call. = FALSE)
  }
  check <- data.table(
    Site_Key = site_key(check$LTER, check$Stream_Name),
    Decision_Check_Use_WRTDS = fifelse(
      candidate == "yes" & gate == "pass",
      "Yes",
      fifelse(candidate == "no" & nzchar(gate), "No", "")
    )
  )[nzchar(Site_Key)]
  check[, .(
    Decision_Check_Use_WRTDS = if (uniqueN(Decision_Check_Use_WRTDS) == 1L) {
      Decision_Check_Use_WRTDS[[1]]
    } else ""
  ), by = Site_Key]
}

confirm_decision_reference <- function(reference, check) {
  matched <- match(reference$Site_Key, check$Site_Key)
  reference$Decision_Check_Use_WRTDS <- check$Decision_Check_Use_WRTDS[matched]
  reference$Decision_Check_Use_WRTDS[is.na(reference$Decision_Check_Use_WRTDS)] <- ""
  reference$Decision_Confirmation_Status <- "Conflict with decision check"
  supported <- reference$Decision_Reference_Use_WRTDS == reference$Decision_Check_Use_WRTDS
  reference$Decision_Confirmation_Status[supported] <- "Supported by decision check"
  missing_check <- !nzchar(reference$Decision_Check_Use_WRTDS)
  reference$Decision_Confirmation_Status[missing_check] <- "Not present in decision check"
  conflicting_reference <- reference$Decision_Reference_Conflict == "Yes"
  reference$Decision_Confirmation_Status[conflicting_reference] <- "Reference has conflicting decisions"
  reference
}

apply_decision_reference <- function(sites, reference, source_path) {
  matched <- match(site_key(sites$LTER, sites$Stream_Name), reference$Site_Key)
  reference_decision <- reference$Decision_Reference_Use_WRTDS[matched]
  reference_decision[is.na(reference_decision)] <- ""
  reference_conflict <- reference$Decision_Reference_Conflict[matched]
  reference_conflict[is.na(reference_conflict)] <- "No"
  check_decision <- reference$Decision_Check_Use_WRTDS[matched]
  check_decision[is.na(check_decision)] <- ""
  confirmation_status <- reference$Decision_Confirmation_Status[matched]
  confirmation_status[is.na(confirmation_status)] <- "Not present in decision reference"
  sites$Decision_Reference_Use_WRTDS <- reference_decision
  sites$Decision_Check_Use_WRTDS <- check_decision
  sites$Decision_Confirmation_Status <- confirmation_status
  has_reference <- nzchar(reference_decision) | reference_conflict == "Yes"
  sites$Decision_Reference_Source[has_reference] <- basename(source_path)
  sites$Decision_Reference_Conflict <- as_yes_no(
    reference_conflict == "Yes" |
      (nzchar(sites$Site_Reference_Use_WRTDS) & nzchar(reference_decision) &
        sites$Site_Reference_Use_WRTDS != reference_decision)
  )
  inherit <- !nzchar(sites$Site_Reference_Use_WRTDS) & nzchar(reference_decision) &
    confirmation_status == "Supported by decision check"
  sites$Use_WRTDS[inherit] <- reference_decision[inherit]
  sites
}

site_aliases <- function(sites) {
  name_columns <- c("Stream_Name", "Alt_Stream_Name", "Original_Stream_Name", "New_Solute_Stream_Name")
  site_mdl <- if ("MDL_Si_mgL" %in% names(sites)) {
    suppressWarnings(as.numeric(clean_text(sites$MDL_Si_mgL)))
  } else {
    rep(NA_real_, nrow(sites))
  }
  pieces <- lapply(seq_along(name_columns), function(index) data.table(
    Site_Row = sites$Site_Row,
    Match_LTER = sites$Match_LTER,
    Match_Stream = clean_text(sites[[name_columns[[index]]]]),
    Match_Source = name_columns[[index]],
    Match_Rank = if (name_columns[[index]] == "Stream_Name") 1L else 2L,
    Site_MDL_Si_mgL = site_mdl
  ))
  aliases <- rbindlist(pieces)
  alternate <- aliases[Match_Source == "Alt_Stream_Name", .(
    Match_Stream = clean_text(unlist(strsplit(Match_Stream, ";", fixed = TRUE)))
  ), by = .(Site_Row, Match_LTER, Match_Source, Match_Rank, Site_MDL_Si_mgL)]
  aliases <- unique(rbindlist(list(
    aliases[Match_Source != "Alt_Stream_Name"],
    alternate
  ), use.names = TRUE)[nzchar(Match_Stream)])

  # exact current names outrank alternate names but all alternate fields are equal
  aliases[, Alias_Key := paste(Match_LTER, Match_Stream, sep = "\r")]
  aliases[, Best_Rank := min(Match_Rank), by = Alias_Key]
  aliases <- aliases[Match_Rank == Best_Rank]

  # retain names shared by several sites so the audit can flag them for review
  aliases[, Chemistry_Alias_Ambiguous := uniqueN(Site_Row) > 1L, by = Alias_Key]
  unique(aliases, by = c("Alias_Key", "Site_Row"))
}

# ---- chemistry input ----

parse_censor_column <- function(value, column) {
  text <- tolower(clean_text(value))
  result <- rep(NA, length(text))
  if (tolower(column) == "censored") {
    result[text %in% c("true", "t", "1", "yes")] <- TRUE
    result[text %in% c("false", "f", "0", "no")] <- FALSE
    return(result)
  }
  result[grepl("<", text, fixed = TRUE)] <- TRUE
  result[text %in% c(
    "nd", "non-detect", "nondetect", "not detected", "bdl",
    "below detection", "censored", "true", "yes", "1", "u"
  )] <- TRUE
  result[text %in% c(
    "=", "uncensored", "false", "no", "0", "detected", "j", "e"
  )] <- FALSE
  result
}

parse_detection_limit <- function(value, path, source_rows) {
  text <- clean_text(value)
  numeric <- suppressWarnings(as.numeric(text))
  invalid <- nzchar(text) & (!is.finite(numeric) | numeric < 0)
  if (any(invalid)) {
    stop(
      basename(path), " has invalid detection limits at source rows ",
      paste(source_rows[invalid], collapse = ", "), ".",
      call. = FALSE
    )
  }
  numeric[!nzchar(text)] <- NA_real_
  numeric
}

detection_limit_in_value_units <- function(limit, column, wide_format, unit) {
  if (is.null(column)) return(rep(NA_real_, length(limit)))
  if (column == "detection_limit") return(limit)
  if (wide_format) {
    if (column == "DSi_Detection_Limit_mg_SiO2_L") {
      return(limit * 28.0855 / 60.0843)
    }
    return(limit)
  }
  output <- rep(NA_real_, length(limit))
  compatible <- unit_is_umol_l(unit)
  if (column == "DSi_Detection_Limit_mg_SiO2_L") {
    output[compatible] <- limit[compatible] * 1000 / 60.0843
  } else {
    output[compatible] <- limit[compatible] * 1000 / 28.0855
  }
  output
}

read_chemistry_file <- function(path, aliases) {
  columns <- names(fread(path, nrows = 0L, check.names = FALSE, showProgress = FALSE))

  # accept the current row-based format and the two older dsi column formats
  lter_column <- first_column(columns, c("LTER", "lter"), "chemistry LTER column")
  stream_column <- first_column(columns, c("Stream_Name", "stream_name", "Site"), "chemistry stream column")
  date_column <- first_column(columns, c("date", "Date"), "chemistry date column")
  variable_column <- first_column(
    columns, c("variable", "Variable"), "chemistry variable column", FALSE
  )
  unit_column <- first_column(columns, c("units", "Units", "unit"), "chemistry unit column", FALSE)
  value_column <- first_column(
    columns, c("value", "Value", "value_mgL"), "chemistry value column", FALSE
  )
  wide_si_column <- first_column(columns, "dsi_mg_Si_L", "DSi as Si column", FALSE)
  wide_sio2_column <- first_column(columns, "dsi_mg_SiO2_L", "DSi as SiO2 column", FALSE)
  wide_format <- is.null(variable_column) &&
    (!is.null(wide_si_column) || !is.null(wide_sio2_column))
  censor_columns <- intersect(
    c(
      "censored", "remarks", "Remarks", "remark", "Remark", "remark_code",
      "Value Flags", "DSi_Remark", "Qualifier", "qualifier"
    ),
    columns
  )
  detection_limit_columns <- intersect(
    c("DSi_Detection_Limit_mg_SiO2_L", "DSi_Detection_Limit_mg_Si_L", "detection_limit"),
    columns
  )
  if (!wide_format && (is.null(variable_column) || is.null(value_column))) {
    stop(
      "Expected a long-format variable and value pair or a supported DSi value column in ",
      basename(path),
      call. = FALSE
    )
  }
  selected <- unique(Filter(Negate(is.null), c(
    lter_column, stream_column, date_column, variable_column, unit_column, value_column,
    wide_si_column, wide_sio2_column, censor_columns, detection_limit_columns
  )))
  data <- fread(path, select = selected, check.names = FALSE, showProgress = FALSE)
  data[, Source_Row := .I + 1L]
  if (!is.null(variable_column)) {
    data <- data[tolower(clean_text(get(variable_column))) == "dsi"]
  }
  if (!nrow(data)) return(NULL)

  # match only reviewed site names and keep uncertain alternate-name matches visible
  data[, Alias_Key := paste(normalize_lter(get(lter_column)), clean_text(get(stream_column)), sep = "\r")]
  data <- merge(
    data,
    aliases[, .(
      Alias_Key, Site_Row, Match_Source, Site_MDL_Si_mgL,
      Chemistry_Alias_Ambiguous
    )],
    by = "Alias_Key",
    all = FALSE
  )
  if (!nrow(data)) return(NULL)

  raw_date <- clean_text(data[[date_column]])
  if (wide_format) {
    # older files store mass units and may express dsi as si or sio2
    raw_si <- if (is.null(wide_si_column)) rep("", nrow(data)) else clean_text(data[[wide_si_column]])
    raw_sio2 <- if (is.null(wide_sio2_column)) rep("", nrow(data)) else clean_text(data[[wide_sio2_column]])
    has_value <- nzchar(raw_si) | nzchar(raw_sio2)
    data <- data[has_value]
    raw_date <- raw_date[has_value]
    raw_si <- raw_si[has_value]
    raw_sio2 <- raw_sio2[has_value]
    if (!nrow(data)) return(NULL)
    si_value <- if (is.null(wide_si_column)) {
      rep(NA_real_, nrow(data))
    } else {
      suppressWarnings(as.numeric(raw_si))
    }
    sio2_value <- if (is.null(wide_sio2_column)) {
      rep(NA_real_, nrow(data))
    } else {
      suppressWarnings(as.numeric(raw_sio2)) * 28.0855 / 60.0843
    }
    invalid_value <- (nzchar(raw_si) & !is.finite(si_value)) |
      (nzchar(raw_sio2) & !is.finite(sio2_value))
    both_values <- is.finite(si_value) & is.finite(sio2_value)
    value_tolerance <- sqrt(.Machine$double.eps) * pmax(1, abs(si_value), abs(sio2_value), na.rm = TRUE)
    conflicting_values <- both_values & abs(si_value - sio2_value) > value_tolerance
    if (any(conflicting_values)) {
      stop(
        basename(path), " has conflicting DSi value columns at source rows ",
        paste(data$Source_Row[conflicting_values], collapse = ", "), ".",
        call. = FALSE
      )
    }
    converted_value <- fcoalesce(si_value, sio2_value)
  } else {
    raw_value <- clean_text(data[[value_column]])
    converted_value <- suppressWarnings(as.numeric(raw_value))
    invalid_value <- !nzchar(raw_value) | !is.finite(converted_value)
  }
  parsed_date <- suppressWarnings(as.IDate(raw_date))
  invalid_date <- !nzchar(raw_date) | is.na(parsed_date)
  if (any(invalid_date) || any(invalid_value)) {
    bad_rows <- sort(unique(data$Source_Row[invalid_date | invalid_value]))
    stop(
      basename(path), " has malformed matched DSi records at source rows ",
      paste(bad_rows, collapse = ", "), ".",
      call. = FALSE
    )
  }

  unit <- if (wide_format) {
    rep("mg Si/L", nrow(data))
  } else if (!is.null(unit_column)) {
    clean_text(data[[unit_column]])
  } else {
    rep("", nrow(data))
  }
  raw_censor <- lapply(censor_columns, function(column) clean_text(data[[column]]))
  remark <- if (length(raw_censor)) {
    vapply(seq_len(nrow(data)), function(row) {
      collapse_text(vapply(raw_censor, `[[`, character(1), row))
    }, character(1))
  } else {
    rep("", nrow(data))
  }

  # combine supported measurement notes but reject rows whose flags disagree
  parsed_censor <- lapply(censor_columns, function(column) {
    parse_censor_column(data[[column]], column)
  })
  remark_style <- tolower(censor_columns) != "censored"
  remark_censored <- vapply(seq_len(nrow(data)), function(row) {
    known <- vapply(parsed_censor, `[[`, logical(1), row)
    known <- known[!is.na(known)]
    if (length(unique(known)) > 1L) return(NA)
    if (length(known)) return(known[[1]])
    if (any(remark_style)) {
      text <- vapply(raw_censor[remark_style], `[[`, character(1), row)
      if (all(!nzchar(text))) return(FALSE)
    }
    NA
  }, logical(1))
  censor_disagreement <- if (length(parsed_censor) > 1L) {
    vapply(seq_len(nrow(data)), function(row) {
      known <- vapply(parsed_censor, `[[`, logical(1), row)
      length(unique(known[!is.na(known)])) > 1L
    }, logical(1))
  } else {
    rep(FALSE, nrow(data))
  }
  if (any(censor_disagreement)) {
    stop(
      basename(path), " has conflicting censor flags at source rows ",
      paste(data$Source_Row[censor_disagreement], collapse = ", "), ".",
      call. = FALSE
    )
  }

  # convert each detection limit into the measurement unit before comparison
  row_limits <- lapply(detection_limit_columns, function(column) {
    limit <- parse_detection_limit(data[[column]], path, data$Source_Row)
    detection_limit_in_value_units(limit, column, wide_format, unit)
  })
  if (length(row_limits) > 1L) {
    limit_matrix <- do.call(cbind, row_limits)
    conflicting_limits <- apply(limit_matrix, 1L, function(values) {
      values <- values[is.finite(values)]
      length(values) > 1L &&
        diff(range(values)) > sqrt(.Machine$double.eps) * max(1, abs(values))
    })
    if (any(conflicting_limits)) {
      stop(
        basename(path), " has conflicting DSi detection limits at source rows ",
        paste(data$Source_Row[conflicting_limits], collapse = ", "), ".",
        call. = FALSE
      )
    }
  }
  site_limit <- detection_limit_in_value_units(
    data$Site_MDL_Si_mgL,
    "DSi_Detection_Limit_mg_Si_L",
    wide_format,
    unit
  )
  limit <- if (length(row_limits)) {
    do.call(fcoalesce, c(row_limits, list(site_limit)))
  } else {
    site_limit
  }
  limit_censored <- ifelse(is.finite(limit), converted_value < limit, NA)
  censored <- fcoalesce(remark_censored, limit_censored)

  output <- data.table(
    Site_Row = data$Site_Row,
    Date = parsed_date,
    Unit = unit,
    Value = converted_value,
    Remark = remark,
    Censored = censored,
    DSi_Basis_Documented = TRUE,
    DSi_Unit_Code_Compatible = if (wide_format) {
      FALSE
    } else if (!is.null(unit_column)) {
      unit_is_umol_l(data[[unit_column]])
    } else {
      FALSE
    },
    Censor_Source_Available = !is.na(censored),
    Chemistry_Alias_Ambiguous = data$Chemistry_Alias_Ambiguous,
    Match_Source = data$Match_Source,
    Chemistry_Source_File = path
  )
  output
}

read_chemistry <- function(files, aliases) {
  empty <- data.table(
    Site_Row = integer(), Date = as.IDate(character()), Unit = character(), Value = numeric(),
    Remark = character(), Censored = logical(), DSi_Basis_Documented = logical(),
    DSi_Unit_Code_Compatible = logical(),
    Censor_Source_Available = logical(), Chemistry_Alias_Ambiguous = logical(),
    DSi_Duplicate_Date = logical(),
    DSi_Conflicting_Duplicate_Date = logical(), Match_Source = character(),
    Chemistry_Source_File = character()
  )
  if (!length(files)) return(empty)
  output <- rbindlist(lapply(files, read_chemistry_file, aliases = aliases), fill = TRUE)
  if (!nrow(output)) return(empty)

  # preserve every source file and name match when duplicate records overlap
  provenance <- output[, .(
    Match_Source = collapse_text(Match_Source),
    Chemistry_Source_File = collapse_text(Chemistry_Source_File)
  ), by = Site_Row]
  duplicate_flags <- output[, .(
    DSi_Duplicate_Date = .N > 1L,
    DSi_Conflicting_Duplicate_Date = uniqueN(paste(Unit, signif(Value, 12), Censored, sep = "\r")) > 1L
  ), by = .(Site_Row, Date)]

  # combine exact repeats while keeping conflicting same-day values for review
  output <- unique(output, by = c(
    "Site_Row", "Date", "Unit", "Value", "Censored", "DSi_Basis_Documented",
    "DSi_Unit_Code_Compatible", "Censor_Source_Available", "Chemistry_Alias_Ambiguous"
  ))
  output[, c("Match_Source", "Chemistry_Source_File") := NULL]
  output <- merge(output, provenance, by = "Site_Row", all.x = TRUE)
  merge(output, duplicate_flags, by = c("Site_Row", "Date"), all.x = TRUE)
}

# ---- discharge input ----

read_discharge_file <- function(path) {
  columns <- names(fread(path, nrows = 0L, check.names = FALSE, showProgress = FALSE))
  date_column <- first_column(columns, c("Date", "date"), "discharge date column")
  q_column <- first_column(columns, c("Qcms", "Q"), "discharge value column")
  name_column <- first_column(
    columns, c("Discharge_File_Name", "DischargeFileName"), "discharge name column", FALSE
  )
  selected <- unique(Filter(Negate(is.null), c(date_column, q_column, name_column)))
  data <- fread(path, select = selected, check.names = FALSE, showProgress = FALSE)
  individual_file <- grepl("_Q[.]csv$", basename(path), ignore.case = TRUE)
  if (individual_file && !is.null(name_column)) {
    content_names <- normalize_discharge_name(data[[name_column]])
    content_names <- unique(content_names[nzchar(content_names)])
    expected_name <- normalize_discharge_name(path)
    if (length(content_names) != 1L || content_names != expected_name) {
      stop(
        "Discharge filename and file contents disagree: ", path,
        call. = FALSE
      )
    }
  }
  data.table(
    Discharge_File_Name = if (is.null(name_column)) {
      rep(normalize_discharge_name(path), nrow(data))
    } else {
      normalize_discharge_name(data[[name_column]])
    },
    Date = as.IDate(data[[date_column]]),
    Qcms = suppressWarnings(as.numeric(data[[q_column]])),
    Discharge_Source_File = path
  )[nzchar(Discharge_File_Name) & !is.na(Date) & is.finite(Qcms)]
}

longest_gap <- function(value) {
  value <- sort(unique(value[!is.na(value)]))
  if (length(value) < 2L) return(NA_integer_)
  max(c(0L, as.integer(diff(value)) - 1L))
}

read_discharge <- function(files) {
  if (!length(files)) return(data.table(
    Discharge_File_Name = character(), Date = as.IDate(character()), Qcms = numeric(),
    Discharge_Source_File = character(), Q_Duplicate_Date = logical(),
    Q_Conflicting_Duplicate_Date = logical()
  ))
  file_index <- data.table(
    Path = files,
    File_Name = tolower(basename(files)),
    Checksum = unname(tools::md5sum(files))
  )
  conflicts <- file_index[, .(Checksums = uniqueN(Checksum)), by = File_Name][Checksums > 1L]

  # allow duplicate copies only when their contents are identical
  if (nrow(conflicts)) {
    stop(
      "Conflicting discharge files share the same filename: ",
      paste(conflicts$File_Name, collapse = ", "),
      call. = FALSE
    )
  }
  setorder(file_index, File_Name, Path)
  files <- file_index[, .(Path = Path[[1]]), by = File_Name]$Path
  output <- rbindlist(lapply(files, read_discharge_file), fill = TRUE)
  sources <- output[, .(
    Discharge_Source_File = collapse_text(Discharge_Source_File)
  ), by = Discharge_File_Name]

  # combine repeated dates but keep a flag when their values disagree
  output <- output[, .(
    Qcms = mean(Qcms),
    Q_Duplicate_Date = .N > 1L,
    Q_Conflicting_Duplicate_Date = uniqueN(Qcms) > 1L
  ), by = .(Discharge_File_Name, Date)]
  merge(output, sources, by = "Discharge_File_Name", all.x = TRUE)
}

summarize_discharge <- function(discharge) {
  if (!nrow(discharge)) return(data.table(
    Discharge_File_Name = character(),
    Q_Full_Start = as.IDate(character()),
    Q_Full_End = as.IDate(character()),
    Q_Full_Dates = integer(),
    Q_Full_Negative_Days = integer(),
    Q_Full_Zero_Days = integer(),
    Q_Full_Longest_Gap_Days = integer(),
    Q_Full_Duplicate_Dates = integer(),
    Q_Full_Conflicting_Duplicate_Dates = integer(),
    Discharge_Source_Files = character()
  ))
  discharge[, .(
    Q_Full_Start = min(Date),
    Q_Full_End = max(Date),
    Q_Full_Dates = uniqueN(Date),
    Q_Full_Negative_Days = sum(Qcms < 0),
    Q_Full_Zero_Days = sum(Qcms == 0),
    Q_Full_Longest_Gap_Days = longest_gap(Date),
    Q_Full_Duplicate_Dates = sum(Q_Duplicate_Date),
    Q_Full_Conflicting_Duplicate_Dates = sum(Q_Conflicting_Duplicate_Date),
    Discharge_Source_Files = collapse_text(Discharge_Source_File)
  ), by = Discharge_File_Name]
}

summarize_available_discharge <- function(sites, discharge, discharge_cropping) {
  # this coverage check uses the full series after its documented year crop
  site_discharge <- merge(
    data.table(Site_Row = sites$Site_Row, Discharge_File_Name = sites$Discharge_File_Name),
    discharge_cropping,
    by = "Site_Row",
    all.x = TRUE
  )
  joined <- merge(
    site_discharge,
    discharge,
    by = "Discharge_File_Name",
    all.x = TRUE,
    allow.cartesian = TRUE
  )
  joined[, Discharge_Crop_Year := as.integer(format(Date, "%Y"))]
  joined[, In_Documented_Discharge_Crop :=
    Discharge_Crop_Remove != "Yes" & !is.na(Date) &
      year_is_in_crop(
        Discharge_Crop_Year,
        Discharge_Crop_Greater_Than,
        Discharge_Crop_Less_Than,
        Discharge_Crop_Unparsed_Value
      )]
  joined[In_Documented_Discharge_Crop == TRUE, .(
    Q_Available_Start = min(Date),
    Q_Available_End = max(Date),
    Q_Available_Dates = uniqueN(Date)
  ), by = Site_Row]
}

summarize_wrtds_discharge <- function(sites, chemistry_summary, discharge, discharge_cropping) {
  # request one extra day beyond the required year of discharge before chemistry
  requested_windows <- merge(
    data.table(Site_Row = sites$Site_Row, Discharge_File_Name = sites$Discharge_File_Name),
    chemistry_summary[, .(Site_Row, DSi_First_Date, DSi_Last_Date)],
    by = "Site_Row",
    all.x = TRUE
  )
  requested_windows <- merge(
    requested_windows,
    discharge_cropping,
    by = "Site_Row",
    all.x = TRUE
  )
  requested_windows[, `:=`(
    WRTDS_Q_Window_Requested_Start = DSi_First_Date - 366L,
    WRTDS_Q_Window_Requested_End = DSi_Last_Date + 91L
  )]
  joined <- merge(
    requested_windows,
    discharge,
    by = "Discharge_File_Name",
    all.x = TRUE,
    allow.cartesian = TRUE
  )
  joined[, Discharge_Crop_Year := as.integer(format(Date, "%Y"))]
  joined[, In_Documented_Discharge_Crop :=
    Discharge_Crop_Remove != "Yes" &
      year_is_in_crop(
        Discharge_Crop_Year,
        Discharge_Crop_Greater_Than,
        Discharge_Crop_Less_Than,
        Discharge_Crop_Unparsed_Value
      )]
  joined[, In_WRTDS_Window :=
    In_Documented_Discharge_Crop & !is.na(Date) &
      Date >= WRTDS_Q_Window_Requested_Start & Date <= WRTDS_Q_Window_Requested_End]

  summary <- joined[In_WRTDS_Window == TRUE, .(
    Q_Start = min(Date),
    Q_End = max(Date),
    Q_Dates = uniqueN(Date),
    Q_Negative_Days = sum(Qcms < 0),
    Q_Zero_Days = sum(Qcms == 0),
    Q_Longest_Gap_Days = longest_gap(Date),
    Q_Duplicate_Dates = sum(Q_Duplicate_Date),
    Q_Conflicting_Duplicate_Dates = sum(Q_Conflicting_Duplicate_Date)
  ), by = Site_Row]
  requested <- unique(requested_windows[, .(
    Site_Row, WRTDS_Q_Window_Requested_Start, WRTDS_Q_Window_Requested_End
  )])
  merge(requested, summary, by = "Site_Row", all.x = TRUE)
}

# ---- audit ----

summarize_chemistry <- function(chemistry, q_by_site) {
  empty <- data.table(
    Site_Row = integer(), DSi_First_Date = as.IDate(character()), DSi_Last_Date = as.IDate(character()),
    DSi_Dates = integer(), DSi_Years = integer(), DSi_Dates_Within_Q = integer(),
    DSi_Years_Within_Q = integer(), DSi_Consecutive_Years_Within_Q = integer(),
    DSi_Units = character(), DSi_Negative_Values = integer(),
    DSi_Zero_Values = integer(), DSi_Censored_Values = integer(),
    DSi_Uncensored_Dates_Within_Q = integer(), DSi_Censored_Fraction_Within_Q = numeric(),
    DSi_Duplicate_Dates = integer(), DSi_Conflicting_Duplicate_Dates = integer(),
    DSi_Basis_Documented = logical(), DSi_Unit_Code_Compatible = logical(),
    DSi_Censoring_Documented = logical(),
    Chemistry_Alias_Ambiguous = logical(),
    Chemistry_Match_Source = character(), Chemistry_Source_Files = character()
  )
  if (!nrow(chemistry)) return(empty)
  chemistry <- merge(
    chemistry,
    q_by_site[, .(Site_Row, Q_Available_Start, Q_Available_End)],
    by = "Site_Row",
    all.x = TRUE
  )

  # count chemistry both overall and within the available discharge period
  chemistry[, In_Q_Range :=
    !is.na(Q_Available_Start) & !is.na(Q_Available_End) &
      Date >= Q_Available_Start & Date <= Q_Available_End]
  chemistry[, .(
    DSi_First_Date = min(Date),
    DSi_Last_Date = max(Date),
    DSi_Dates = uniqueN(Date),
    DSi_Years = uniqueN(format(Date, "%Y")),
    DSi_Dates_Within_Q = uniqueN(Date[In_Q_Range]),
    DSi_Years_Within_Q = uniqueN(format(Date[In_Q_Range], "%Y")),
    DSi_Consecutive_Years_Within_Q = longest_consecutive_run(format(Date[In_Q_Range], "%Y")),
    DSi_Units = collapse_text(Unit),
    DSi_Negative_Values = sum(is.finite(Value) & Value < 0),
    DSi_Zero_Values = sum(is.finite(Value) & Value == 0),
    DSi_Censored_Values = sum(Censored),
    DSi_Uncensored_Dates_Within_Q = if (any(In_Q_Range) && all(Censor_Source_Available[In_Q_Range])) {
      uniqueN(Date[In_Q_Range & !Censored])
    } else NA_integer_,
    DSi_Censored_Fraction_Within_Q = if (
      any(In_Q_Range) && all(Censor_Source_Available[In_Q_Range])
    ) {
      sum(In_Q_Range & Censored) / sum(In_Q_Range)
    } else NA_real_,
    DSi_Duplicate_Dates = uniqueN(Date[In_Q_Range & DSi_Duplicate_Date]),
    DSi_Conflicting_Duplicate_Dates = uniqueN(Date[In_Q_Range & DSi_Conflicting_Duplicate_Date]),
    DSi_Basis_Documented = all(DSi_Basis_Documented),
    DSi_Unit_Code_Compatible = all(DSi_Unit_Code_Compatible),
    DSi_Censoring_Documented = any(In_Q_Range) & all(Censor_Source_Available[In_Q_Range]),
    Chemistry_Alias_Ambiguous = any(Chemistry_Alias_Ambiguous),
    Chemistry_Match_Source = collapse_text(Match_Source),
    Chemistry_Source_Files = collapse_text(Chemistry_Source_File)
  ), by = Site_Row]
}

audit_sites <- function(
  sites,
  chemistry,
  discharge,
  chemistry_cropping = NULL,
  discharge_cropping = NULL,
  minimum_observations = 46L,
  minimum_years = 5L,
  gap_review_days = 30L
) {
  validate_decision_values(sites$Use_WRTDS, "Site-reference Use_WRTDS")
  if (!"Site_Reference_Use_WRTDS" %in% names(sites)) {
    sites$Site_Reference_Use_WRTDS <- normalize_decision(sites$Use_WRTDS)
  }
  for (column in c(
    "Decision_Reference_Use_WRTDS", "Decision_Reference_Source", "Decision_Reference_Conflict",
    "Decision_Check_Use_WRTDS", "Decision_Confirmation_Status"
  )) {
    if (!column %in% names(sites)) {
      sites[[column]] <- if (column == "Decision_Reference_Conflict") {
        "No"
      } else if (column == "Decision_Confirmation_Status") {
        "Not checked"
      } else ""
    }
  }
  if (is.null(chemistry_cropping)) {
    chemistry_cropping <- attach_cropping(sites, data.table(), "Chemistry")
  }
  if (is.null(discharge_cropping)) {
    discharge_cropping <- attach_cropping(sites, data.table(), "Discharge")
  }

  # reduce chemistry and discharge to one set of checks per site
  q_summary <- summarize_discharge(discharge)
  q_by_site <- merge(
    data.table(Site_Row = sites$Site_Row, Discharge_File_Name = sites$Discharge_File_Name),
    q_summary,
    by = "Discharge_File_Name",
    all.x = TRUE
  )
  q_available <- merge(
    data.table(Site_Row = sites$Site_Row),
    summarize_available_discharge(sites, discharge, discharge_cropping),
    by = "Site_Row",
    all.x = TRUE
  )
  chem_summary <- summarize_chemistry(chemistry, q_available)
  q_wrtds_summary <- summarize_wrtds_discharge(
    sites,
    chem_summary,
    discharge,
    discharge_cropping
  )
  result <- merge(as.data.table(sites), q_by_site, by = c("Site_Row", "Discharge_File_Name"), all.x = TRUE)
  result <- merge(result, q_available, by = "Site_Row", all.x = TRUE)
  result <- merge(result, chem_summary, by = "Site_Row", all.x = TRUE)
  result <- merge(result, q_wrtds_summary, by = "Site_Row", all.x = TRUE)
  result <- merge(result, chemistry_cropping, by = "Site_Row", all.x = TRUE)
  result <- merge(result, discharge_cropping, by = "Site_Row", all.x = TRUE)
  setorder(result, Site_Row)

  # retain dataset version details without changing any source fields
  result[, Current_Use_WRTDS := normalize_decision(Use_WRTDS)]
  result[, Manual_Decision := Current_Use_WRTDS %in% c("Yes", "No")]
  glass_release <- suppressWarnings(as.numeric(result$GlASS_First_Release))
  result[, Added_Since_GlASS_2 := as_yes_no(
    tolower(clean_text(`GlASS_2.0`)) == "no" | glass_release > 2
  )]
  cq_release <- suppressWarnings(as.numeric(result$CQ_Data_Version))
  latest_cq_release <- if (any(is.finite(cq_release))) max(cq_release, na.rm = TRUE) else NA_real_
  result[, Current_CQ_Release := as_yes_no(is.finite(cq_release) & cq_release == latest_cq_release)]

  drainage_area <- suppressWarnings(as.numeric(result$drainSqKm))
  result[, Drainage_Area_Present := is.finite(drainage_area) & drainage_area > 0]
  result[, Flowing_Water := flowing_water(Waterbody)]
  result[, Discharge_Name_Assigned := nzchar(Discharge_File_Name)]
  result[, Discharge_File_Found := !is.na(Q_Full_Dates) & Q_Full_Dates >= 2L]
  result[, Discharge_Series_Found := !is.na(Q_Available_Dates) & Q_Available_Dates >= 2L]
  result[, WRTDS_Q_Window_Found := !is.na(Q_Dates) & Q_Dates >= 2L]
  result[, Discharge_Unit_Supported := supported_q_unit(Units)]
  result[, DSi_Found := !is.na(DSi_Dates) & DSi_Dates > 0L]
  result[is.na(Chemistry_Alias_Ambiguous), Chemistry_Alias_Ambiguous := FALSE]
  result[, Observation_Gate := !is.na(DSi_Dates_Within_Q) & DSi_Dates_Within_Q >= minimum_observations]
  result[, Uncensored_Observation_Gate := !is.na(DSi_Uncensored_Dates_Within_Q) &
    DSi_Uncensored_Dates_Within_Q >= minimum_observations]
  result[, Censoring_Gate := !is.na(DSi_Censored_Fraction_Within_Q) &
    DSi_Censored_Fraction_Within_Q < 0.33]
  result[, Year_Gate := !is.na(DSi_Consecutive_Years_Within_Q) &
    DSi_Consecutive_Years_Within_Q >= minimum_years]
  result[, Q_Nonnegative := WRTDS_Q_Window_Found & !is.na(Q_Negative_Days) & Q_Negative_Days == 0L]
  result[, Q_Strictly_Positive := Q_Nonnegative & !is.na(Q_Zero_Days) & Q_Zero_Days == 0L]
  result[, Q_Gap_Gate := WRTDS_Q_Window_Found & !is.na(Q_Longest_Gap_Days) &
    Q_Longest_Gap_Days < gap_review_days]
  result[, Q_Duplicate_Gate := WRTDS_Q_Window_Found &
    !is.na(Q_Conflicting_Duplicate_Dates) & Q_Conflicting_Duplicate_Dates == 0L]
  result[, Q_Covers_Chemistry := !is.na(Q_Start) & !is.na(Q_End) & !is.na(DSi_First_Date) &
    Q_Start <= DSi_First_Date & Q_End >= DSi_Last_Date]
  result[, Overlap_Crop_Required := DSi_Found & Discharge_Series_Found &
    !Q_Covers_Chemistry & Observation_Gate]
  result[, One_Year_Prechemistry_Q := Q_Covers_Chemistry & Q_Start <= DSi_First_Date - 365]
  result[, Postchemistry_Q_Buffer := Q_Covers_Chemistry & Q_End >= DSi_Last_Date + 91]
  result[, DSi_Value_Gate := DSi_Found & !is.na(DSi_Negative_Values) &
    DSi_Negative_Values == 0L & !is.na(DSi_Zero_Values) & DSi_Zero_Values == 0L]
  result[, DSi_Duplicate_Gate := DSi_Found & !is.na(DSi_Conflicting_Duplicate_Dates) &
    DSi_Conflicting_Duplicate_Dates == 0L]
  result[, Chemistry_Cropping_Gate :=
    !Chemistry_Crop_Unparsed_Value &
      !nzchar(Chemistry_BlankTime_Start) & !nzchar(Chemistry_BlankTime_End)]
  result[, Discharge_Cropping_Gate :=
    !Discharge_Crop_Unparsed_Value & Discharge_Crop_Remove != "Yes"]

  # minimum checks show whether a site can run from the supplied files at all
  result[, WRTDS_Core_Input_Gates := Drainage_Area_Present & Flowing_Water &
    Discharge_Name_Assigned & Discharge_Series_Found & Discharge_Unit_Supported &
    WRTDS_Q_Window_Found & DSi_Found & Observation_Gate]

  # final readiness also requires documented quality and coverage checks
  result[, WRTDS_Input_Gates := WRTDS_Core_Input_Gates &
    DSi_Basis_Documented & DSi_Unit_Code_Compatible & DSi_Censoring_Documented &
    !Chemistry_Alias_Ambiguous &
    Uncensored_Observation_Gate & Censoring_Gate & DSi_Value_Gate & DSi_Duplicate_Gate & Year_Gate &
    Q_Strictly_Positive & Q_Gap_Gate & Q_Duplicate_Gate & Q_Covers_Chemistry &
    One_Year_Prechemistry_Q & Postchemistry_Q_Buffer &
    Chemistry_Cropping_Gate & Discharge_Cropping_Gate]
  result[, WRTDS_Data_Ready := WRTDS_Input_Gates]
  result[, WRTDS_Readiness_Status := "Not runnable from supplied inputs"]
  result[WRTDS_Core_Input_Gates == TRUE, WRTDS_Readiness_Status := "Hold for documented review"]
  result[WRTDS_Data_Ready == TRUE, WRTDS_Readiness_Status := "Ready"]
  result[, Automated_Candidate := WRTDS_Data_Ready]
  result[, Manual_Yes_Conflict := Current_Use_WRTDS == "Yes" & !WRTDS_Data_Ready]

  # manual decisions always outrank an automated suggestion
  result[, Suggested_Use_WRTDS := ""]
  result[Automated_Candidate == TRUE, Suggested_Use_WRTDS := "Yes"]
  result[Current_Use_WRTDS == "No", Suggested_Use_WRTDS := "No"]
  result[Current_Use_WRTDS == "Yes", Suggested_Use_WRTDS := "Yes"]

  # assign the most trusted decision source last so it takes priority
  result[, Decision_Source := "No recommendation; review incomplete inputs"]
  result[Automated_Candidate == TRUE, Decision_Source := "Automated candidate for manual approval"]
  result[
    nzchar(Decision_Reference_Use_WRTDS),
    Decision_Source := "Decision reference requires manual review"
  ]
  result[
    nzchar(Decision_Reference_Use_WRTDS) &
      Decision_Confirmation_Status == "Supported by decision check",
    Decision_Source := "Supported decision inherited from decision reference"
  ]
  result[
    nzchar(Site_Reference_Use_WRTDS),
    Decision_Source := "Manual site-reference decision retained"
  ]

  # list every failed check in plain language for site-level review
  result[, Audit_Reason := vapply(seq_len(.N), function(index) {
    reasons <- character()
    if (Current_Use_WRTDS[[index]] == "Yes") reasons <- c(reasons, "manual Yes retained")
    if (Current_Use_WRTDS[[index]] == "No") reasons <- c(reasons, "manual No retained")
    if (!Drainage_Area_Present[[index]]) reasons <- c(reasons, "missing positive drainage area")
    if (!Flowing_Water[[index]]) reasons <- c(reasons, "not a flowing-water site")
    if (!Discharge_Name_Assigned[[index]]) reasons <- c(reasons, "no discharge file assigned")
    if (Discharge_Name_Assigned[[index]] && !Discharge_File_Found[[index]]) {
      reasons <- c(reasons, "assigned discharge series not supplied")
    }
    if (Discharge_File_Found[[index]] && !Discharge_Series_Found[[index]] &&
      Discharge_Crop_Remove[[index]] != "Yes") {
      reasons <- c(reasons, "fewer than two discharge dates remain after the documented year crop")
    }
    if (Discharge_Name_Assigned[[index]] && !Discharge_Unit_Supported[[index]]) {
      reasons <- c(reasons, "discharge unit is not supported by the harmonizer")
    }
    if (Discharge_Series_Found[[index]] && DSi_Found[[index]] && !WRTDS_Q_Window_Found[[index]]) {
      reasons <- c(reasons, "fewer than two discharge dates in the requested WRTDS window")
    }
    if (!DSi_Found[[index]]) reasons <- c(reasons, "no matched DSi records in supplied chemistry")
    if (Chemistry_Alias_Ambiguous[[index]]) {
      reasons <- c(reasons, "chemistry name or alias matches more than one site-reference row")
    }
    if (DSi_Found[[index]] && !Observation_Gate[[index]]) {
      reasons <- c(reasons, paste0(
        DSi_Dates_Within_Q[[index]], " in-range DSi dates; ",
        minimum_observations, " required"
      ))
    }
    if (DSi_Found[[index]] && !isTRUE(DSi_Basis_Documented[[index]])) {
      reasons <- c(reasons, "DSi analyte basis is not documented")
    }
    if (DSi_Found[[index]] && !isTRUE(DSi_Unit_Code_Compatible[[index]])) {
      reasons <- c(reasons, "DSi must be converted to micromolar before the current WRTDS wrangling code")
    }
    if (DSi_Found[[index]] && !isTRUE(DSi_Censoring_Documented[[index]])) {
      reasons <- c(
        reasons,
        "DSi censoring or detection-limit handling is not documented in the supplied chemistry"
      )
    }
    if (DSi_Found[[index]] && isTRUE(DSi_Censoring_Documented[[index]]) &&
      !Uncensored_Observation_Gate[[index]]) {
      reasons <- c(
        reasons,
        paste0(
          DSi_Uncensored_Dates_Within_Q[[index]], " uncensored in-range DSi dates; ",
          minimum_observations, " required"
        )
      )
    }
    if (DSi_Found[[index]] && isTRUE(DSi_Censoring_Documented[[index]]) && !Censoring_Gate[[index]]) {
      reasons <- c(reasons, "at least 33% of in-range DSi results are censored")
    }
    if (DSi_Found[[index]] && !Year_Gate[[index]]) {
      reasons <- c(reasons, paste0(
        DSi_Consecutive_Years_Within_Q[[index]], " consecutive in-range DSi years; ",
        minimum_years, " required"
      ))
    }
    if (DSi_Found[[index]] && is.finite(DSi_Negative_Values[[index]]) && DSi_Negative_Values[[index]] > 0L) {
      reasons <- c(reasons, paste0(DSi_Negative_Values[[index]], " negative DSi values"))
    }
    if (DSi_Found[[index]] && is.finite(DSi_Zero_Values[[index]]) && DSi_Zero_Values[[index]] > 0L) {
      reasons <- c(reasons, paste0(
        DSi_Zero_Values[[index]], " zero DSi values require a documented treatment"
      ))
    }
    if (DSi_Found[[index]] && is.finite(DSi_Conflicting_Duplicate_Dates[[index]]) &&
      DSi_Conflicting_Duplicate_Dates[[index]] > 0L) {
      reasons <- c(reasons, paste0(
        DSi_Conflicting_Duplicate_Dates[[index]], " DSi dates have conflicting duplicate values"
      ))
    }
    if (WRTDS_Q_Window_Found[[index]] && !Q_Nonnegative[[index]]) {
      reasons <- c(reasons, paste0(Q_Negative_Days[[index]], " negative discharge days"))
    }
    if (WRTDS_Q_Window_Found[[index]] && is.finite(Q_Zero_Days[[index]]) && Q_Zero_Days[[index]] > 0L) {
      reasons <- c(reasons, paste0(Q_Zero_Days[[index]], " zero-flow days require a documented treatment"))
    }
    if (WRTDS_Q_Window_Found[[index]] && is.finite(Q_Longest_Gap_Days[[index]]) &&
      Q_Longest_Gap_Days[[index]] >= gap_review_days) {
      reasons <- c(reasons, paste0(
        Q_Longest_Gap_Days[[index]], "-day discharge gap is not under the published ",
        gap_review_days, "-day interpolation limit"
      ))
    }
    if (WRTDS_Q_Window_Found[[index]] && is.finite(Q_Conflicting_Duplicate_Dates[[index]]) &&
      Q_Conflicting_Duplicate_Dates[[index]] > 0L) {
      reasons <- c(reasons, paste0(
        Q_Conflicting_Duplicate_Dates[[index]], " discharge dates have conflicting duplicate values"
      ))
    }
    if (DSi_Found[[index]] && Discharge_Series_Found[[index]] && !Q_Covers_Chemistry[[index]]) {
      reasons <- c(reasons, "discharge does not span the cropped chemistry record")
    }
    if (Q_Covers_Chemistry[[index]] && !One_Year_Prechemistry_Q[[index]]) {
      reasons <- c(reasons, "less than one year of discharge before cropped chemistry")
    }
    if (Q_Covers_Chemistry[[index]] && !Postchemistry_Q_Buffer[[index]]) {
      reasons <- c(reasons, "less than 91 days of discharge after cropped chemistry")
    }
    if (Chemistry_Crop_Unparsed_Value[[index]]) {
      reasons <- c(reasons, "chemistry cropping row contains an unparsed instruction")
    }
    if (nzchar(Chemistry_BlankTime_Start[[index]]) || nzchar(Chemistry_BlankTime_End[[index]])) {
      reasons <- c(
        reasons,
        "chemistry blank-time interval is documented but the current WRTDS code does not apply it"
      )
    }
    if (Discharge_Crop_Unparsed_Value[[index]]) {
      reasons <- c(reasons, "discharge cropping row contains an unparsed instruction")
    }
    if (Discharge_Crop_Remove[[index]] == "Yes") {
      reasons <- c(reasons, "discharge cropping table marks this site for removal")
    }
    if (!length(reasons)) reasons <- "all documented readiness checks pass"
    paste(reasons, collapse = "; ")
  }, character(1))]

  # warnings record usable inputs that still need attention
  result[, QA_Warnings := vapply(seq_len(.N), function(index) {
    warnings <- character()
    if (Manual_Yes_Conflict[[index]]) {
      warnings <- c(
        warnings,
        "manual Use_WRTDS = Yes records intended inclusion but does not establish data readiness"
      )
    }
    if (Chemistry_Alias_Ambiguous[[index]]) {
      warnings <- c(warnings, "shared chemistry alias requires a site-level mapping decision")
    }
    if (WRTDS_Q_Window_Found[[index]] && is.finite(Q_Duplicate_Dates[[index]]) &&
      Q_Duplicate_Dates[[index]] > 0L && Q_Conflicting_Duplicate_Dates[[index]] == 0L) {
      warnings <- c(warnings, paste0(
        Q_Duplicate_Dates[[index]], " duplicate discharge dates have identical values and were collapsed"
      ))
    }
    if (DSi_Found[[index]] && is.finite(DSi_Duplicate_Dates[[index]]) &&
      DSi_Duplicate_Dates[[index]] > 0L && DSi_Conflicting_Duplicate_Dates[[index]] == 0L) {
      warnings <- c(warnings, paste0(
        DSi_Duplicate_Dates[[index]], " duplicate DSi dates have identical values and were collapsed"
      ))
    }
    if (Chemistry_Cropping_Row_Found[[index]] &&
      (is.finite(Chemistry_Crop_Greater_Than[[index]]) || is.finite(Chemistry_Crop_Less_Than[[index]]))) {
      warnings <- c(warnings, "documented chemistry year crop was applied before the readiness checks")
    }
    if (Discharge_Cropping_Row_Found[[index]] &&
      (is.finite(Discharge_Crop_Greater_Than[[index]]) || is.finite(Discharge_Crop_Less_Than[[index]]))) {
      warnings <- c(warnings, "documented discharge year crop was applied before the readiness checks")
    }
    paste(warnings, collapse = "; ")
  }, character(1))]

  logical_columns <- c(
    "Manual_Decision", "Drainage_Area_Present", "Flowing_Water", "Discharge_Name_Assigned",
    "Discharge_File_Found", "Discharge_Series_Found", "WRTDS_Q_Window_Found",
    "Discharge_Unit_Supported", "DSi_Found",
    "DSi_Basis_Documented", "DSi_Unit_Code_Compatible", "DSi_Censoring_Documented",
    "Chemistry_Alias_Ambiguous",
    "Observation_Gate", "Uncensored_Observation_Gate", "Censoring_Gate", "Year_Gate",
    "DSi_Value_Gate", "DSi_Duplicate_Gate", "Q_Nonnegative", "Q_Strictly_Positive",
    "Q_Gap_Gate", "Q_Duplicate_Gate",
    "Q_Covers_Chemistry", "Overlap_Crop_Required", "One_Year_Prechemistry_Q",
    "Postchemistry_Q_Buffer", "Chemistry_Cropping_Row_Found", "Chemistry_Crop_Unparsed_Value",
    "Chemistry_Cropping_Gate", "Discharge_Cropping_Row_Found", "Discharge_Crop_Unparsed_Value",
    "Discharge_Cropping_Gate", "WRTDS_Core_Input_Gates", "WRTDS_Input_Gates", "WRTDS_Data_Ready",
    "Automated_Candidate", "Manual_Yes_Conflict"
  )

  # yes and no text is easier to review in the exported table than true and false
  result[, (logical_columns) := lapply(.SD, as_yes_no), .SDcols = logical_columns]
  result[, `:=`(
    WRTDS_Minimum_Observations = minimum_observations,
    Project_Minimum_DSi_Years = minimum_years,
    Discharge_Gap_Review_Days = gap_review_days,
    WRTDS_DSi_Censoring_Note = paste(
      "This audit uses row-level less-than flags when supplied.",
      "The current chemistry harmonizer still maps MDL_Si_mgL to Si rather than DSi",
      "and should be repaired before production WRTDS."
    ),
    WRTDS_Discharge_Unit_Note = "The discharge harmonizer converts cms, cfs, Ls, cmh, and cmd to Qcms",
    WRTDS_Discharge_Gap_Note = paste0(
      "The current WRTDS code linearly interpolates every internal gap; ",
      "this audit withholds Ready when a gap exceeds ",
      "or equals ", gap_review_days,
      " days unless the data are cropped so the gap is outside the analysis window"
    ),
    WRTDS_Readiness_Note = paste(
      "Use_WRTDS is a reviewed modeling decision, not proof that the current input files are ready.",
      "Ready requires documented chemistry basis, compatible units and censoring,",
      "positive discharge, checked gaps,",
      "nonconflicting duplicates, the requested discharge buffers, and usable cropping instructions."
    )
  )]

  # keep related fields together so the exported table reads from decision to evidence
  output_columns <- c(
    "LTER", "Stream_Name", "GlASS_2.0", "New-or-Updated_since-GlASS_2.0",
    "GlASS_First_Release", "CQ_Data_Version", "Spatial_Data_Version",
    "Added_Since_GlASS_2", "Current_CQ_Release", "Site_Reference_Use_WRTDS",
    "Decision_Reference_Use_WRTDS", "Decision_Reference_Source", "Decision_Reference_Conflict",
    "Decision_Check_Use_WRTDS", "Decision_Confirmation_Status",
    "Current_Use_WRTDS", "Suggested_Use_WRTDS", "Decision_Source",
    "WRTDS_Readiness_Status", "WRTDS_Data_Ready", "WRTDS_Core_Input_Gates",
    "WRTDS_Input_Gates", "Automated_Candidate", "Manual_Yes_Conflict", "Audit_Reason", "QA_Warnings",
    "Waterbody", "Flowing_Water", "drainSqKm", "Drainage_Area_Present", "Discharge_File_Name",
    "Discharge_Name_Assigned", "Units", "Discharge_Unit_Supported", "Discharge_Site_Name",
    "Discharge_File_Found", "Discharge_Series_Found", "Q_Full_Start", "Q_Full_End", "Q_Full_Dates",
    "Q_Full_Longest_Gap_Days", "Q_Full_Negative_Days", "Q_Full_Zero_Days",
    "Q_Full_Duplicate_Dates", "Q_Full_Conflicting_Duplicate_Dates",
    "Q_Available_Start", "Q_Available_End", "Q_Available_Dates",
    "WRTDS_Q_Window_Requested_Start", "WRTDS_Q_Window_Requested_End", "WRTDS_Q_Window_Found",
    "Q_Start", "Q_End", "Q_Dates", "Q_Longest_Gap_Days", "Q_Negative_Days", "Q_Zero_Days",
    "Q_Duplicate_Dates", "Q_Conflicting_Duplicate_Dates", "Q_Nonnegative", "Q_Strictly_Positive",
    "Q_Gap_Gate", "Q_Duplicate_Gate",
    "Q_Covers_Chemistry", "Overlap_Crop_Required", "One_Year_Prechemistry_Q", "Postchemistry_Q_Buffer",
    "Discharge_Cropping_Row_Found", "Discharge_Crop_Greater_Than", "Discharge_Crop_Less_Than",
    "Discharge_Crop_Remove", "Discharge_Crop_Unparsed_Value", "Discharge_Cropping_Gate",
    "Discharge_Source_Files", "DSi_Found", "DSi_First_Date", "DSi_Last_Date", "DSi_Dates",
    "DSi_Years", "DSi_Dates_Within_Q", "DSi_Years_Within_Q",
    "DSi_Consecutive_Years_Within_Q", "DSi_Units",
    "DSi_Negative_Values", "DSi_Zero_Values", "DSi_Censored_Values", "DSi_Value_Gate",
    "DSi_Duplicate_Dates", "DSi_Conflicting_Duplicate_Dates", "DSi_Duplicate_Gate",
    "DSi_Basis_Documented", "DSi_Unit_Code_Compatible", "DSi_Censoring_Documented",
    "DSi_Uncensored_Dates_Within_Q", "DSi_Censored_Fraction_Within_Q",
    "Chemistry_Cropping_Row_Found", "Chemistry_Crop_Greater_Than", "Chemistry_Crop_Less_Than",
    "Chemistry_BlankTime_Start", "Chemistry_BlankTime_End", "Chemistry_Crop_Unparsed_Value",
    "Chemistry_Cropping_Gate",
    "Chemistry_Alias_Ambiguous", "Chemistry_Match_Source", "Chemistry_Source_Files",
    "Observation_Gate", "Uncensored_Observation_Gate", "Censoring_Gate", "Year_Gate",
    "WRTDS_Minimum_Observations", "Project_Minimum_DSi_Years", "Discharge_Gap_Review_Days",
    "WRTDS_DSi_Censoring_Note", "WRTDS_Discharge_Unit_Note", "WRTDS_Discharge_Gap_Note",
    "WRTDS_Readiness_Note"
  )
  as.data.frame(result[, ..output_columns])
}

# ---- command-line checks ----

validate_audit_args <- function(args) {
  value_options <- c(
    "--site-reference", "--site-reference-sheet", "--decision-reference",
    "--decision-reference-sheet", "--decision-check", "--decision-check-sheet",
    "--chemistry-cropping", "--chemistry-cropping-sheet", "--discharge-cropping",
    "--discharge-cropping-sheet", "--chemistry", "--chemistry-dir",
    "--discharge", "--discharge-dir", "--output", "--overwrite",
    "--minimum-observations", "--minimum-years", "--gap-review-days"
  )
  repeatable_options <- c("--chemistry", "--chemistry-dir", "--discharge", "--discharge-dir")
  known_options <- c(value_options, "--self-test")

  if ("--self-test" %in% args) {
    if (!identical(args, "--self-test")) {
      stop("Use --self-test by itself.", call. = FALSE)
    }
    return(invisible(TRUE))
  }

  option_positions <- which(startsWith(args, "--"))
  unknown <- unique(setdiff(args[option_positions], known_options))
  if (length(unknown)) {
    stop("Unknown command options: ", paste(unknown, collapse = ", "), call. = FALSE)
  }

  single_use <- setdiff(value_options, repeatable_options)
  repeated <- single_use[vapply(single_use, function(option) {
    sum(args == option) > 1L
  }, logical(1))]
  if (length(repeated)) {
    stop("Use each command option once: ", paste(repeated, collapse = ", "), call. = FALSE)
  }

  value_positions <- which(args %in% value_options) + 1L
  missing_values <- value_positions > length(args)
  if (any(!missing_values)) {
    missing_values[!missing_values] <- startsWith(args[value_positions[!missing_values]], "--")
  }
  if (any(missing_values)) {
    stop("Every command option must be followed by a value.", call. = FALSE)
  }

  used_positions <- unique(c(option_positions, value_positions))
  unused_positions <- setdiff(seq_along(args), used_positions)
  if (length(unused_positions)) {
    stop(
      "Unexpected command values: ", paste(args[unused_positions], collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

strict_cli_integer <- function(args, name, default, minimum) {
  text <- cli_value(args, name, default)
  value <- suppressWarnings(as.numeric(text))
  if (length(value) != 1L || !is.finite(value) || value != floor(value)) {
    stop(name, " must be a whole number.", call. = FALSE)
  }
  if (value < minimum) stop(name, " must be at least ", minimum, ".", call. = FALSE)
  as.integer(value)
}

validate_decision_paths <- function(reference_path, check_path) {
  if (nzchar(check_path) && !nzchar(reference_path)) {
    stop("--decision-check requires --decision-reference.", call. = FALSE)
  }
  invisible(TRUE)
}

# ---- self-test ----

run_self_test <- function() {
  has_error <- function(expression) inherits(try(force(expression), silent = TRUE), "try-error")

  # basic input checks should fail clearly when a value is not usable
  stopifnot(
    has_error(validate_decision_values("maybe", "test decision")),
    unparsed_crop_value("2020.5"),
    reversed_crop_bounds("2021", "2020"),
    longest_consecutive_run(c(2016, 2018, 2020, 2022, 2024)) == 1L,
    longest_consecutive_run(2020:2024) == 5L,
    has_error(validate_audit_args(c("--self-test", "extra"))),
    has_error(validate_audit_args(c("--unknown", "value"))),
    has_error(validate_audit_args(c("--output", "one.tsv", "--output", "two.tsv"))),
    has_error(strict_cli_integer(c("--minimum-years", "5.5"), "--minimum-years", "5", 1L)),
    has_error(validate_decision_paths("", "decision-check.tsv"))
  )

  # small site examples cover manual decisions and each main readiness outcome
  site_names <- c(
    "manual_yes", "manual_no", "new_ready", "new_short", "reference_yes",
    "zero_flow", "long_gap", "nonconsecutive"
  )
  sites <- data.frame(
    LTER = "TEST",
    Stream_Name = site_names,
    Use_WRTDS = c("Yes", "No", "", "", "", "", "", ""),
    Waterbody = "Stream",
    drainSqKm = 10,
    Discharge_File_Name = c(
      "missing_Q", "good_Q", "good_Q", "good_Q", "missing_Q", "zero_Q", "gap_Q", "good_Q"
    ),
    Units = "cfs",
    GlASS_2.0 = c("Yes", "Yes", "No", "No", "No", "No", "No", "No"),
    `New-or-Updated_since-GlASS_2.0` = "",
    GlASS_First_Release = c(2, 2, 3, 3, 3, 3, 3, 3),
    CQ_Data_Version = 3,
    Spatial_Data_Version = 3,
    Alt_Stream_Name = "",
    Original_Stream_Name = "",
    New_Solute_Stream_Name = "",
    Discharge_Site_Name = "test gauge",
    Site_Row = seq_along(site_names),
    Match_LTER = "TEST",
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  sites$Site_Reference_Use_WRTDS <- normalize_decision(sites$Use_WRTDS)
  sites$Decision_Reference_Use_WRTDS <- ""
  sites$Decision_Reference_Source <- ""
  sites$Decision_Reference_Conflict <- "No"
  sites$Decision_Check_Use_WRTDS <- ""
  sites$Decision_Confirmation_Status <- "Not checked"

  # name matching must prefer exact names and expose alternate names shared by sites
  shared_alias_sites <- sites[1:2, , drop = FALSE]
  shared_alias_sites$New_Solute_Stream_Name <- "shared chemistry"
  shared_aliases <- site_aliases(shared_alias_sites)
  shared_alias_key <- paste("TEST", "shared chemistry", sep = "\r")
  shared_alias_match <- shared_aliases[shared_aliases$Alias_Key == shared_alias_key]
  stopifnot(
    nrow(shared_alias_match) == 2L,
    all(shared_alias_match$Chemistry_Alias_Ambiguous)
  )

  preferred_alias_sites <- sites[1:2, , drop = FALSE]
  preferred_alias_sites$New_Solute_Stream_Name[[1]] <- preferred_alias_sites$Stream_Name[[2]]
  preferred_aliases <- site_aliases(preferred_alias_sites)
  preferred_alias_key <- paste("TEST", preferred_alias_sites$Stream_Name[[2]], sep = "\r")
  preferred_alias_match <- preferred_aliases[preferred_aliases$Alias_Key == preferred_alias_key]
  stopifnot(
    nrow(preferred_alias_match) == 1L,
    preferred_alias_match$Site_Row == preferred_alias_sites$Site_Row[[2]],
    !preferred_alias_match$Chemistry_Alias_Ambiguous
  )
  secondary_alias_sites <- sites[1:2, , drop = FALSE]
  secondary_alias_sites$Alt_Stream_Name[[1]] <- "shared secondary; split alternate"
  secondary_alias_sites$New_Solute_Stream_Name[[2]] <- "shared secondary"
  secondary_aliases <- site_aliases(secondary_alias_sites)
  shared_secondary_key <- paste("TEST", "shared secondary", sep = "\r")
  shared_secondary_match <- secondary_aliases[secondary_aliases$Alias_Key == shared_secondary_key]
  split_alternate_key <- paste("TEST", "split alternate", sep = "\r")
  split_alternate_match <- secondary_aliases[secondary_aliases$Alias_Key == split_alternate_key]
  stopifnot(
    nrow(shared_secondary_match) == 2L,
    all(shared_secondary_match$Chemistry_Alias_Ambiguous),
    nrow(split_alternate_match) == 1L,
    split_alternate_match$Site_Row == secondary_alias_sites$Site_Row[[1]],
    !split_alternate_match$Chemistry_Alias_Ambiguous
  )
  reference <- data.table(
    Site_Key = site_key("TEST", c("manual_no", "reference_yes")),
    Decision_Reference_Use_WRTDS = "Yes",
    Decision_Reference_Conflict = "No",
    Decision_Check_Use_WRTDS = "Yes",
    Decision_Confirmation_Status = "Supported by decision check"
  )
  sites <- apply_decision_reference(sites, reference, "reviewed-decisions.csv")
  dates <- as.IDate("2000-01-01") + round(seq(0, 6 * 365, length.out = 50))
  chemistry_row <- function(site_row, site_dates = dates) data.table(
    Site_Row = site_row,
    Date = site_dates,
    Unit = "uM",
    Value = 1,
    Remark = "",
    Censored = FALSE,
    DSi_Basis_Documented = TRUE,
    DSi_Unit_Code_Compatible = TRUE,
    Censor_Source_Available = TRUE,
    Chemistry_Alias_Ambiguous = FALSE,
    DSi_Duplicate_Date = FALSE,
    DSi_Conflicting_Duplicate_Date = FALSE,
    Match_Source = "Stream_Name",
    Chemistry_Source_File = "test"
  )
  chemistry <- rbindlist(list(
    chemistry_row(2L),
    chemistry_row(3L),
    chemistry_row(4L, dates[1:20]),
    chemistry_row(6L),
    chemistry_row(7L),
    chemistry_row(8L, as.IDate(paste0(rep(c(2000, 2002, 2004, 2006, 2008), each = 10L), "-06-01")) +
      rep(0:9, times = 5L))
  ))

  # discharge examples cover a complete series, zero flow, and a long gap
  good_discharge <- data.table(
    Discharge_File_Name = "good_Q",
    Date = seq(as.IDate("1998-01-01"), as.IDate("2008-12-31"), by = "day"),
    Qcms = 1,
    Discharge_Source_File = "test",
    Q_Duplicate_Date = FALSE,
    Q_Conflicting_Duplicate_Date = FALSE
  )
  zero_discharge <- copy(good_discharge)
  zero_discharge[, Discharge_File_Name := "zero_Q"]
  zero_discharge[Date == as.IDate("2003-01-01"), Qcms := 0]
  gap_discharge <- copy(good_discharge)
  gap_discharge[, Discharge_File_Name := "gap_Q"]
  gap_discharge <- gap_discharge[Date < as.IDate("2002-01-01") | Date > as.IDate("2002-12-31")]
  discharge <- rbindlist(list(good_discharge, zero_discharge, gap_discharge))
  result <- audit_sites(sites, chemistry, discharge)
  no_discharge_result <- audit_sites(sites, chemistry, discharge[0])
  row <- function(name) result[result$Stream_Name == name, , drop = FALSE]
  stopifnot(
    nrow(no_discharge_result) == nrow(sites),
    all(no_discharge_result$WRTDS_Readiness_Status == "Not runnable from supplied inputs"),
    all(no_discharge_result$Discharge_File_Found == "No"),
    row("manual_yes")$Suggested_Use_WRTDS == "Yes",
    row("manual_yes")$Manual_Yes_Conflict == "Yes",
    row("manual_no")$Suggested_Use_WRTDS == "No",
    row("manual_no")$Decision_Reference_Conflict == "Yes",
    row("manual_no")$Automated_Candidate == "Yes",
    row("new_ready")$Suggested_Use_WRTDS == "Yes",
    row("new_ready")$WRTDS_Readiness_Status == "Ready",
    row("new_short")$Suggested_Use_WRTDS == "",
    row("reference_yes")$Suggested_Use_WRTDS == "Yes",
    row("reference_yes")$Decision_Source == "Supported decision inherited from decision reference",
    row("zero_flow")$WRTDS_Readiness_Status == "Hold for documented review",
    row("zero_flow")$Automated_Candidate == "No",
    row("long_gap")$WRTDS_Readiness_Status == "Hold for documented review",
    row("long_gap")$Automated_Candidate == "No",
    row("nonconsecutive")$WRTDS_Readiness_Status == "Hold for documented review",
    row("nonconsecutive")$DSi_Years_Within_Q == 5L,
    row("nonconsecutive")$DSi_Consecutive_Years_Within_Q == 1L
  )

  # chemistry counts use only the part covered by available discharge
  boundary_summary <- summarize_chemistry(
    chemistry_row(1L, as.IDate(c("2000-01-01", "2000-01-02"))),
    data.table(
      Site_Row = 1L,
      Q_Available_Start = as.IDate("2000-01-01"),
      Q_Available_End = as.IDate("2000-01-02")
    )
  )
  stopifnot(boundary_summary$DSi_Dates_Within_Q == 2L)
  censor_scope <- chemistry_row(1L, as.IDate(c("1999-01-01", "2000-01-01")))
  censor_scope$Censored <- c(NA, FALSE)
  censor_scope$Censor_Source_Available <- c(FALSE, TRUE)
  censor_scope_summary <- summarize_chemistry(
    censor_scope,
    data.table(
      Site_Row = 1L,
      Q_Available_Start = as.IDate("2000-01-01"),
      Q_Available_End = as.IDate("2000-01-01")
    )
  )
  stopifnot(censor_scope_summary$DSi_Censoring_Documented)

  test_dir <- tempfile("wrtds-audit-")
  dir.create(test_dir)
  on.exit(unlink(test_dir, recursive = TRUE), add = TRUE)

  # site-reference readers ignore empty rows but reject incomplete site names
  incomplete_site_path <- file.path(test_dir, "incomplete-site-reference.csv")
  incomplete_sites <- sites[1:2, , drop = FALSE]
  incomplete_sites$Stream_Name[[2]] <- ""
  fwrite(incomplete_sites, incomplete_site_path)
  stopifnot(has_error(read_sites(incomplete_site_path)))
  blank_site_path <- file.path(test_dir, "blank-site-reference-row.csv")
  blank_site <- sites[1, , drop = FALSE]
  blank_site[1, ] <- NA
  fwrite(rbind(sites[1, , drop = FALSE], blank_site), blank_site_path)
  stopifnot(nrow(read_sites(blank_site_path)) == 1L)
  test_aliases <- data.table(
    Alias_Key = paste("TEST", "censor", sep = "\r"),
    Site_Row = 1L,
    Match_Source = "Stream_Name",
    Site_MDL_Si_mgL = NA_real_,
    Chemistry_Alias_Ambiguous = FALSE
  )

  # chemistry examples cover measurement flags, limits, duplicates, and bad records
  chemistry_path <- file.path(test_dir, "chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = c("2020-01-01", "2020-01-02"),
    variable = "DSi",
    units = "uM",
    value = c(1, 2),
    DSi_Detection_Limit_mg_Si_L = 0.03
  ), chemistry_path)
  censor_check <- read_chemistry_file(chemistry_path, test_aliases)
  stopifnot(identical(censor_check$Censored, c(TRUE, FALSE)))

  duplicate_path <- file.path(test_dir, "duplicate-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "2020-01-01",
    variable = "DSi",
    units = "uM",
    value = 1
  ), duplicate_path)
  duplicate_second_path <- file.path(test_dir, "duplicate-chemistry-second-source.csv")
  file.copy(duplicate_path, duplicate_second_path)
  duplicate_check <- read_chemistry(c(duplicate_path, duplicate_second_path), test_aliases)
  stopifnot(
    nrow(duplicate_check) == 1L,
    isTRUE(duplicate_check$DSi_Duplicate_Date),
    !isTRUE(duplicate_check$DSi_Conflicting_Duplicate_Date),
    grepl(basename(duplicate_path), duplicate_check$Chemistry_Source_File, fixed = TRUE),
    grepl(basename(duplicate_second_path), duplicate_check$Chemistry_Source_File, fixed = TRUE)
  )

  site_mdl_aliases <- copy(test_aliases)
  site_mdl_aliases[, Site_MDL_Si_mgL := 0.03]
  site_mdl_path <- file.path(test_dir, "site-mdl-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = c("2020-01-01", "2020-01-02"),
    variable = "DSi",
    units = "uM",
    value = c(1, 2)
  ), site_mdl_path)
  site_mdl_check <- read_chemistry_file(site_mdl_path, site_mdl_aliases)
  stopifnot(identical(site_mdl_check$Censored, c(TRUE, FALSE)))

  boolean_censor_path <- file.path(test_dir, "boolean-censor-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = c("2020-01-01", "2020-01-02"),
    variable = "DSi",
    units = "uM",
    value = c(1, 2),
    censored = c(TRUE, FALSE)
  ), boolean_censor_path)
  boolean_censor_check <- read_chemistry_file(boolean_censor_path, test_aliases)
  stopifnot(identical(boolean_censor_check$Censored, c(TRUE, FALSE)))

  complementary_censor_path <- file.path(test_dir, "complementary-censor-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = c("2020-01-01", "2020-01-02"),
    variable = "DSi",
    units = "uM",
    value = c(1, 2),
    remarks = c("", "uncensored"),
    Qualifier = c("<", "")
  ), complementary_censor_path)
  complementary_censor_check <- read_chemistry_file(complementary_censor_path, test_aliases)
  stopifnot(identical(complementary_censor_check$Censored, c(TRUE, FALSE)))

  conflicting_censor_path <- file.path(test_dir, "conflicting-censor-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "2020-01-01",
    variable = "DSi",
    units = "uM",
    value = 1,
    censored = FALSE,
    Qualifier = "<"
  ), conflicting_censor_path)
  stopifnot(has_error(read_chemistry_file(conflicting_censor_path, test_aliases)))

  generic_path <- file.path(test_dir, "generic-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "2020-01-01",
    units = "uM",
    value = 99
  ), generic_path)
  stopifnot(has_error(read_chemistry_file(generic_path, test_aliases)))

  dual_limit_path <- file.path(test_dir, "dual-limit-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "2020-01-01",
    variable = "DSi",
    units = "uM",
    value = 1,
    DSi_Detection_Limit_mg_SiO2_L = NA_real_,
    DSi_Detection_Limit_mg_Si_L = 0.03
  ), dual_limit_path)
  dual_limit_check <- read_chemistry_file(dual_limit_path, test_aliases)
  stopifnot(isTRUE(dual_limit_check$Censored))

  conflicting_limit_path <- file.path(test_dir, "conflicting-limit-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "2020-01-01",
    variable = "DSi",
    units = "uM",
    value = 1,
    DSi_Detection_Limit_mg_SiO2_L = 0.03,
    DSi_Detection_Limit_mg_Si_L = 0.03
  ), conflicting_limit_path)
  stopifnot(has_error(read_chemistry_file(conflicting_limit_path, test_aliases)))

  malformed_path <- file.path(test_dir, "malformed-chemistry.csv")
  fwrite(data.table(
    LTER = "TEST",
    Stream_Name = "censor",
    date = "bad date",
    variable = "DSi",
    units = "uM",
    value = "bad value"
  ), malformed_path)
  stopifnot(has_error(read_chemistry_file(malformed_path, test_aliases)))

  # discharge readers reject mismatched names and conflicting duplicate files
  mismatch_path <- file.path(test_dir, "Mismatch_Q.csv")
  fwrite(data.table(
    Discharge_File_Name = "Other_Q",
    Date = c("2020-01-01", "2020-01-02"),
    Qcms = 1
  ), mismatch_path)
  stopifnot(has_error(read_discharge_file(mismatch_path)))

  first_dir <- file.path(test_dir, "first")
  second_dir <- file.path(test_dir, "second")
  dir.create(first_dir)
  dir.create(second_dir)
  first_copy <- file.path(first_dir, "Conflict_Q.csv")
  second_copy <- file.path(second_dir, "Conflict_Q.csv")
  fwrite(data.table(Date = "2020-01-01", Qcms = 1), first_copy)
  fwrite(data.table(Date = "2020-01-01", Qcms = 2), second_copy)
  stopifnot(has_error(read_discharge(c(first_copy, second_copy))))
  message("WRTDS eligibility self-test passed.")
}

# ---- run ----

validate_audit_args(args)

if (identical(args, "--self-test")) {
  run_self_test()
} else {
  site_reference_path <- cli_value(args, "--site-reference", required = TRUE)
  site_reference_sheet <- cli_value(args, "--site-reference-sheet", "")
  decision_reference_path <- cli_value(args, "--decision-reference", "")
  decision_reference_sheet <- cli_value(args, "--decision-reference-sheet", "")
  decision_check_path <- cli_value(args, "--decision-check", "")
  decision_check_sheet <- cli_value(args, "--decision-check-sheet", "")
  validate_decision_paths(decision_reference_path, decision_check_path)
  chemistry_cropping_path <- cli_value(args, "--chemistry-cropping", "")
  chemistry_cropping_sheet <- cli_value(args, "--chemistry-cropping-sheet", "")
  discharge_cropping_path <- cli_value(args, "--discharge-cropping", "")
  discharge_cropping_sheet <- cli_value(args, "--discharge-cropping-sheet", "")
  output_path <- cli_value(args, "--output", required = TRUE)
  overwrite <- cli_boolean(args, "--overwrite", FALSE)
  minimum_observations <- strict_cli_integer(args, "--minimum-observations", "46", 1L)
  minimum_years <- strict_cli_integer(args, "--minimum-years", "5", 1L)
  gap_review_days <- strict_cli_integer(args, "--gap-review-days", "30", 0L)
  if (file.exists(output_path) && !overwrite) {
    stop("Output exists. Use --overwrite true to replace it: ", output_path, call. = FALSE)
  }
  if (tolower(tools::file_ext(output_path)) != "tsv") {
    stop("The audit output must use a .tsv extension.", call. = FALSE)
  }

  # load the live site table before attaching optional reviewed decisions
  sites <- read_sites(site_reference_path, site_reference_sheet)
  if (nzchar(decision_reference_path)) {
    decision_reference_path <- require_input_file(decision_reference_path)
    decision_reference <- read_decision_reference(decision_reference_path, decision_reference_sheet)
    if (nzchar(decision_check_path)) {
      decision_check_path <- require_input_file(decision_check_path)
      decision_check <- read_decision_check(decision_check_path, decision_check_sheet)
      decision_reference <- confirm_decision_reference(decision_reference, decision_check)
    } else {
      decision_reference$Decision_Check_Use_WRTDS <- ""
      decision_reference$Decision_Confirmation_Status <- "Not checked"
    }
    sites <- apply_decision_reference(sites, decision_reference, decision_reference_path)
  }
  aliases <- site_aliases(sites)
  chemistry_cropping <- attach_cropping(
    sites,
    read_chemistry_cropping(chemistry_cropping_path, chemistry_cropping_sheet),
    "Chemistry"
  )
  discharge_cropping <- attach_cropping(
    sites,
    read_discharge_cropping(discharge_cropping_path, discharge_cropping_sheet),
    "Discharge"
  )
  chemistry_files <- collect_files(
    cli_values(args, "--chemistry"), cli_values(args, "--chemistry-dir"), "chemistry"
  )
  discharge_files <- collect_files(
    cli_values(args, "--discharge"), cli_values(args, "--discharge-dir"), "discharge"
  )

  # align the supplied records without altering their source files
  chemistry <- read_chemistry(chemistry_files, aliases)
  chemistry <- apply_chemistry_cropping(chemistry, chemistry_cropping)
  discharge <- read_discharge(discharge_files)
  result <- audit_sites(
    sites,
    chemistry,
    discharge,
    chemistry_cropping,
    discharge_cropping,
    minimum_observations,
    minimum_years,
    gap_review_days
  )

  # stop before writing if any site or manual decision was lost
  if (nrow(result) != nrow(sites)) stop("The audit did not retain one row per site.", call. = FALSE)
  if (any(result$Current_Use_WRTDS == "Yes" & result$Suggested_Use_WRTDS != "Yes")) {
    stop("A manual Yes decision was changed.", call. = FALSE)
  }
  if (any(result$Current_Use_WRTDS == "No" & result$Suggested_Use_WRTDS != "No")) {
    stop("A manual No decision was changed.", call. = FALSE)
  }

  prepare_output_dir(output_path, is_file = TRUE)
  fwrite(result, output_path, sep = "\t", quote = FALSE, na = "")
  message(
    "Wrote ", nrow(result), " rows to ", normalizePath(output_path),
    ". Effective Yes decisions: ", sum(result$Current_Use_WRTDS == "Yes"),
    "; effective No decisions: ", sum(result$Current_Use_WRTDS == "No"),
    "; supported decisions inherited: ", sum(
      nzchar(result$Decision_Reference_Use_WRTDS) & !nzchar(result$Site_Reference_Use_WRTDS) &
        result$Decision_Confirmation_Status == "Supported by decision check"
    ),
    "; data ready: ", sum(result$WRTDS_Data_Ready == "Yes"),
    "; new automated candidates: ", sum(result$Current_Use_WRTDS == "" & result$Suggested_Use_WRTDS == "Yes"),
    "; manual Yes rows held by readiness checks: ", sum(result$Manual_Yes_Conflict == "Yes"), "."
  )
}
