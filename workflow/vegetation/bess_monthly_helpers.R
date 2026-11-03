# ---- calendar months and complete annual totals ----

bess_months <- function(years) {
  as.Date(unlist(lapply(years, function(year) sprintf("%04d-%02d-01", year, 1:12))))
}

bess_month_days <- function(dates) {
  as.integer(as.Date(format(dates + 32, "%Y-%m-01")) - dates)
}

# use the same cells for all twelve months of each annual total
bess_annual_totals <- function(points, total, valid_months, valid_days, year, minimum_area = .8) {
  expected_days <- as.integer(as.Date(paste0(year + 1L, "-01-01")) - as.Date(paste0(year, "-01-01")))
  rows <- lapply(split(seq_len(nrow(points)), points$site), function(index) {
    weights <- points$weight[index]
    complete <- valid_months[index] == 12L & valid_days[index] == expected_days
    area <- sum(weights[complete]) / sum(weights)
    value <- if (area >= minimum_area) weighted.mean(total[index][complete], weights[complete]) else NA_real_
    data.frame(site = points$site[index[1]], year = year, source = "BESSv2",
      gpp_gC_m2_year = value,
      valid_days = if (any(complete)) expected_days else max(valid_days[index]),
      valid_area_fraction = area)
  })
  do.call(rbind, rows)
}

# flag reviewed source-zero histories without changing source values
bess_trend_flags <- function(result) {
  result$bess_trend_flag <- "not_flagged"
  result$bess_trend_note <- ""
  shapes <- c("sisyn_canada_eccc_wsc_nw10uf0003", "sisyn_canada_eccc_wsc_nw10vk0002")
  notes <- c(
    "source cells are zero throughout 2001–2022 after positive values in 1982–2000; do not interpret this history as a reliable vegetation trend",
    "source cells are zero except June–September 2000; do not interpret this history as a reliable vegetation trend"
  )
  if (!all(c("LTER", "Shapefile_Name") %in% names(result))) return(result)
  for (i in seq_along(shapes)) {
    selected <- which(result$LTER == "Canada" & result$Shapefile_Name == shapes[i])
    result$bess_trend_flag[selected] <- "source_zero_history"
    result$bess_trend_note[selected] <- notes[i]
  }
  result
}

# keep the full site list and write results for sites with reviewed watersheds
bess_site_totals <- function(annual, points, roster = NULL) {
  if (is.null(roster)) {
    columns <- intersect(c("site", "LTER", "Stream_Name", "Shapefile_Name"), names(points))
    aliases <- unique(points[, columns, drop = FALSE])
  } else {
    assert_required_columns(roster, c("site", "LTER", "Stream_Name", "Shapefile_Name", "Has_Spatial_Data"), "site roster")
    aliases <- roster[roster$Has_Spatial_Data == "Yes", c("site", "LTER", "Stream_Name", "Shapefile_Name")]
    if (anyNA(aliases) || any(!nzchar(aliases$site)) || !setequal(aliases$site, points$site)) {
      stop("The spatial site roster and sample points do not match")
    }
    if (anyDuplicated(paste(aliases$LTER, aliases$Stream_Name, sep = "\r"))) stop("Duplicate site names in the roster")
  }
  result <- merge(aliases, annual, by = "site", all.x = TRUE, sort = FALSE)
  bess_trend_flags(result[order(result$site, result$year), ])
}

# ---- checked monthly downloads and resumable annual extraction ----

run_bess_monthly <- function(points, years, settings, output, record, roster = NULL,
                             source_cache = file.path(output, "monthly-files"), test = FALSE) {
  dates <- bess_months(years)
  days <- bess_month_days(dates)
  expected_names <- paste0("BESS_GPP_Monthly.A", format(dates, "%Y%m"), ".nc")
  status <- function(text) writeLines(text, file.path(output, "status.txt"))
  dir.create(source_cache, recursive = TRUE, showWarnings = FALSE)
  catalog_path <- file.path(output, "source-files.rds")
  if (!file.exists(catalog_path)) {
    status("preparing: checking monthly source dates, file sizes, and checksums")
    catalog <- googledrive::drive_ls(googledrive::as_id(settings$folder), n_max = Inf)
    if (anyDuplicated(catalog$name) || !all(expected_names %in% catalog$name)) {
      stop("The source folder has duplicated or missing requested months")
    }
    catalog <- catalog[match(expected_names, catalog$name), ]
    size <- vapply(catalog$drive_resource, function(file) as.numeric(file$size), numeric(1))
    if (any(!is.finite(size)) || any(size <= 0) || sum(size) > 5e9) {
      stop("Unexpected file sizes. Check the monthly file list before downloading")
    }
    save_vegetation_rds(catalog, catalog_path)
  }
  catalog <- readRDS(catalog_path)
  stopifnot(identical(catalog$name, expected_names))
  source_hash <- unname(tools::md5sum(catalog_path))
  checkpoint <- file.path(output, "monthly-checkpoint.rds")
  if (file.exists(checkpoint)) {
    state <- readRDS(checkpoint)
    stopifnot(identical(state$run_inputs, record), identical(state$source_hash, source_hash),
      identical(state$dates, dates), length(state$total) == nrow(points))
    if (!identical(which(state$completed), seq_len(sum(state$completed)))) stop("Saved months must start with the first requested month and have no gaps")
  } else {
    state <- list(dates = dates, run_inputs = record, source_hash = source_hash,
      completed = rep(FALSE, length(dates)), md5 = rep(NA_character_, length(dates)),
      total = numeric(nrow(points)), valid_months = integer(nrow(points)),
      valid_days = integer(nrow(points)), annual = list())
  }
  # continue at the first unsaved month and start fresh totals each january
  for (i in which(!state$completed)) {
    year <- as.integer(format(dates[i], "%Y"))
    if (format(dates[i], "%m") == "01") {
      state$total[] <- 0
      state$valid_months[] <- 0L
      state$valid_days[] <- 0L
    }
    status(paste("running:", catalog$name[i], ";", sum(state$completed), "of", length(dates), "months saved"))
    path <- file.path(source_cache, catalog$name[i])
    expected <- catalog$drive_resource[[i]]
    check_file <- function(file) {
      file.exists(file) && file.info(file)$size == as.numeric(expected$size) &&
        identical(unname(tools::md5sum(file)), expected$md5Checksum)
    }
    if (file.exists(path) && !check_file(path)) stop("A cached source file failed its checksum: ", path)
    if (!file.exists(path)) {
      temporary <- paste0(path, ".partial")
      on.exit(unlink(temporary), add = TRUE)
      googledrive::drive_download(catalog[i, ], path = temporary, overwrite = TRUE)
      if (!check_file(temporary)) stop("The monthly download failed its size or checksum check")
      if (!file.rename(temporary, path)) stop("Could not retain the checked monthly source file")
    }
    value <- read_gpp(path, points, whole_grid = TRUE)
    valid <- is.finite(value)
    # multiply the mean daily rate by the number of days in this month
    state$total[valid] <- state$total[valid] + value[valid] * days[i]
    state$valid_months[valid] <- state$valid_months[valid] + 1L
    state$valid_days[valid] <- state$valid_days[valid] + days[i]
    state$md5[i] <- expected$md5Checksum
    state$completed[i] <- TRUE
    if (format(dates[i], "%m") == "12") {
      state$annual[[as.character(year)]] <- bess_annual_totals(points, state$total,
        state$valid_months, state$valid_days, year)
    }
    save_vegetation_rds(state, checkpoint)
    if (test) {
      status("test passed: one monthly file checked and extracted; annual totals remain incomplete")
      return(invisible(TRUE))
    }
    if (sum(state$completed) %% 12L == 0L) cat("saved", sum(state$completed), "of", length(dates), "monthly files\n")
    if (i < length(dates)) Sys.sleep(settings$download_pause_seconds)
  }
  if (!identical(record$files, tools::md5sum(names(record$files)))) stop("Inputs or code changed during extraction")
  annual <- do.call(rbind, state$annual)
  stopifnot(all(state$completed), nrow(annual) == length(unique(points$site)) * length(years))
  result <- bess_site_totals(annual, points, roster)
  save_vegetation_rds(result, file.path(output, "annual-gpp.rds"))
  status(paste("complete:", length(dates), "monthly files checked;", nrow(result), "annual site-year rows saved"))
  invisible(result)
}
