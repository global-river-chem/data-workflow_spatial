# ---- inputs ----

argument <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script <- normalizePath(sub("^--file=", "", argument[[1]]))
repo <- normalizePath(file.path(dirname(script), "../.."))
source(file.path(repo, "workflow/lib/workflow_helpers.R"))
source(file.path(repo, "workflow/release/recover_saved_spatial_results.R"))
args <- commandArgs(trailingOnly = TRUE)
path <- require_input_file(cli_value(args, "--combined-input", required = TRUE), "combined spatial dataset")
glass_path <- require_input_file(cli_value(args, "--glass-input", required = TRUE), "unchanged glass dataset")
if (normalizePath(path) == normalizePath(glass_path)) stop("the glass input must remain untouched")
glass_hash <- tools::md5sum(glass_path)
annual <- readRDS(require_input_file(cli_value(args, "--bess-input", required = TRUE), "BESS annual results"))
reference <- readRDS(require_input_file(cli_value(args, "--site-reference", required = TRUE), "BESS site roster"))
if (!cli_boolean(args, "--overwrite", FALSE)) stop("use --overwrite to update the combined input")

# ---- merge and verify ----

original <- read.csv(path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = "")
retained <- names(original)[!bess_excluded_columns(names(original)) &
  !grepl("^bess_gpp_", names(original), ignore.case = TRUE)]
result <- add_bess_gpp(original, annual, reference)
stopifnot(identical(result[retained], original[retained]), nrow(result) == nrow(original),
  !any(bess_excluded_columns(names(result))))
key <- function(x) paste(x$LTER, x$Stream_Name, sep = "\r")
rows <- match(key(annual), key(result))
fields <- c(gC_m2_year = "gpp_gC_m2_year", valid_days = "valid_days",
  area_fraction = "valid_area_fraction", trend_flag = "bess_trend_flag", trend_note = "bess_trend_note")
verify <- function(data) {
  stopifnot(isTRUE(all.equal(data[retained], original[retained], tolerance = 0)),
    !any(bess_excluded_columns(names(data))))
  for (year in 1982:2022) {
    selected <- which(annual$year == year)
    for (field in names(fields)) {
      values <- data[[paste("bess_gpp", year, field, sep = "_")]]
      expected <- annual[[fields[[field]]]][selected]
      # empty notes and missing fields share the existing csv blank representation
      if (is.character(expected)) expected[expected == ""] <- NA_character_
      stopifnot(isTRUE(all.equal(values[rows[selected]], expected, tolerance = 1e-12)))
      stopifnot(all(is.na(values[!seq_len(nrow(data)) %in% rows[selected]])))
    }
  }
}

# ---- replace only after the written values pass readback ----

temporary <- paste0(path, ".partial")
tryCatch({
  write.csv(result, temporary, row.names = FALSE, na = "")
  checked <- read.csv(temporary, check.names = FALSE, stringsAsFactors = FALSE, na.strings = "")
  verify(checked)
  stopifnot(identical(tools::md5sum(glass_path), glass_hash))
  if (!file.rename(temporary, path)) stop("could not replace the combined dataset")
}, finally = if (file.exists(temporary)) unlink(temporary))
cat("BESS values, coverage, and trend flags checked; retired predictors excluded; other columns unchanged\n")
