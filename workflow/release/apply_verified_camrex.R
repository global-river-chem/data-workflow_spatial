# ---- verified watershed additions ----

apply_verified_camrex <- function(data, metadata, inputs, targets) {
  key <- function(d) paste(d$LTER, d$Stream_Name, sep = "\r")
  read_table <- function(product) {
    table <- inputs[[product]]
    stopifnot(is.data.frame(table), !anyDuplicated(key(table)))
    table
  }
  match_camrex <- function(d) {
    rows <- match(key(targets), key(d))
    stopifnot(!anyNA(rows), !anyDuplicated(rows),
      all(abs(d$Latitude[rows] - targets$Latitude) < 1e-5),
      all(abs(d$Longitude[rows] - targets$Longitude) < 1e-5))
    rows
  }
  rows <- match_camrex(data)
  meta_rows <- match_camrex(metadata)
  source_metadata <- read_table("site-metadata")
  source_rows <- match_camrex(source_metadata)
  expected <- list(
    "bess-gpp" = unlist(lapply(1982:2022, function(year) {
      paste0("bess_gpp_", year, "_", c("gC_m2_year", "valid_days",
        "area_fraction", "trend_flag", "trend_note"))
    })),
    "modis-npp" = c(paste0("npp_", 2001:2025, "_kgC_m2_year"),
      paste0("npp_", 2001:2025, "_gapfilled_input_days_pct"), "modis_npp_status"),
    "modis-greenup" = c(unlist(lapply(0:1, function(cycle) {
      prefix <- paste0("greenup_cycle", cycle, "_", 2001:2024)
      c(paste0(prefix, "MMDD"), paste0(prefix, "_coverage_pct"),
        paste0(prefix, "_coverage_flag"))
    })), "modis_greenup_status")
  )

  # retain the earlier match status for sites outside the verified additions
  if ("modis_vegetation_status" %in% names(data)) {
    data$modis_npp_status <- data$modis_vegetation_status
    data$modis_greenup_status <- data$modis_vegetation_status
    data$modis_vegetation_status <- NULL
  }
  for (product in names(expected)) {
    values <- read_table(product)
    source <- match_camrex(values)
    columns <- expected[[product]]
    stopifnot(all(columns %in% names(values)))
    for (column in columns) {
      if (!column %in% names(data)) data[[column]] <- values[[column]][NA_integer_]
      data[[column]][rows] <- values[[column]][source]
    }
  }

  # copy the verified coverage notes for the reviewed watersheds
  fields <- c("Site_Flag", "Has_Spatial_Data", "ERA5_Coverage", "Spatial_Recovery_Note")
  stopifnot(all(fields %in% names(source_metadata)))
  for (field in setdiff(fields, names(metadata))) metadata[[field]] <- NA_character_
  for (field in fields) {
    metadata[[field]][meta_rows] <- source_metadata[[field]][source_rows]
  }
  data$Site_Flag[rows] <- metadata$Site_Flag[meta_rows]
  ferguson <- "WesternAustralia\rFerguson River - Dowdells Rd Bridge"
  target <- match(ferguson, key(metadata))
  source <- match(ferguson, key(source_metadata))
  if (!is.na(target)) {
    stopifnot(!is.na(source),
      abs(metadata$drainSqKm[target] - source_metadata$drainSqKm[source]) < .001)
    for (field in c("ERA5_Coverage", "Spatial_Recovery_Note")) {
      metadata[[field]][target] <- source_metadata[[field]][source]
    }
  }
  list(data = data, metadata = metadata)
}
