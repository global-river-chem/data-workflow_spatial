# ---- saved spatial results ----

# keep the missing-data note with the other site flags in every spatial product
spatial_site_flags <- function(reference) {
  flags <- trimws(as.character(reference$Flag))
  flags[is.na(flags)] <- ""
  if (any(!reference$Has_Spatial_Data %in% c("Yes", "No"))) {
    stop("each site needs a yes or no spatial-data status")
  }
  note <- "spatial data not yet available"
  for (row in which(reference$Has_Spatial_Data == "No")) {
    entries <- trimws(strsplit(flags[row], ";", fixed = TRUE)[[1]])
    if (!note %in% entries) {
      flags[row] <- if (nzchar(flags[row])) paste(flags[row], note, sep = "; ") else note
    }
  }
  flags
}

# use the chemistry sites and current reference table, not an extraction roster
recover_saved_spatial_results <- function(modis, era5, reference, chemistry_path, data_root, class_key,
    boundary_updates_path = "", era5_updates_path = "", download_boundary = TRUE) {
  # use one table type here so column selection is the same for every caller
  modis <- as.data.frame(modis)
  era5 <- as.data.frame(era5)
  reference <- as.data.frame(reference)
  sites <- unique(as.data.frame(data.table::fread(
    chemistry_path, select = c("LTER", "Stream_Name"), showProgress = FALSE
  )))
  site_key <- function(x) paste(x$LTER, x$Stream_Name, sep = "\r")
  reference_key <- site_key(reference)
  if (anyDuplicated(reference_key)) stop("duplicate site names in the reference table")
  matched <- match(site_key(sites), reference_key)
  if (anyNA(matched)) stop("chemistry sites are missing from the reference table")
  reference <- reference[matched, , drop = FALSE]
  if (any(!reference$Has_Spatial_Data %in% c("Yes", "No"))) {
    stop("each chemistry site needs a yes or no spatial-data status")
  }
  missing <- reference$Has_Spatial_Data == "Yes" &
    (!site_key(sites) %in% site_key(modis) | !site_key(sites) %in% site_key(era5))
  target_keys <- site_key(sites)[missing]
  # old predictors must not be attached to a replacement watershed with the same site name
  corrected <- rep(FALSE, nrow(sites))
  verified <- read_verified_boundary_updates(boundary_updates_path,
    required = any(needs_verified_boundary(reference)), download = download_boundary)
  if (!is.null(verified)) {
    updates <- verified$boundaries
    corrected <- reference$Shapefile_Name %in% updates$Shapefile_Name
    if (any(needs_verified_boundary(reference) & !corrected)) {
      stop("Ferguson's shape name does not match the corrected boundary")
    }
    target_keys <- setdiff(target_keys, site_key(sites)[corrected])
  }

  # retain every chemistry site and leave unavailable predictors blank
  align_sites <- function(data) {
    if (anyDuplicated(site_key(data))) stop("duplicate sites in a spatial input")
    out <- data[match(site_key(sites), site_key(data)), , drop = FALSE]
    out$LTER <- sites$LTER
    out$Stream_Name <- sites$Stream_Name
    for (column in c("Latitude", "Longitude", "drainSqKm")) {
      out[[column]] <- suppressWarnings(as.numeric(reference[[column]]))
    }
    out$Site_Flag <- spatial_site_flags(reference)
    predictors <- setdiff(names(out), c("LTER", "Stream_Name", "Latitude",
      "Longitude", "drainSqKm", "Site_Flag"))
    out[reference$Has_Spatial_Data == "No" | corrected, predictors] <- NA
    rownames(out) <- NULL
    out
  }
  modis <- align_sites(modis)
  era5 <- align_sites(era5)
  recovered <- rep(FALSE, nrow(sites))

  # these reviewed chunks retain the existing product names and units
  chunk_root <- file.path(data_root, "spatial-data/raw/appeears-modis/source-chunks")
  chunks <- c(
    "standard-modis-extractions-20260728-followups/extracted-data",
    "standard-modis-extractions-20260729-verified-july/coverage-2002-2025/extracted-data"
  )
  prefixes <- c("^evapotrans_", "^npp_", "^greenup_", "^snow_")
  for (directory in chunks) {
    files <- list.files(file.path(chunk_root, directory), pattern = "[.]csv$", full.names = TRUE)
    if (!length(files)) stop("missing reviewed MODIS source folder: ", directory)
    for (path in files) {
      saved <- read.csv(path, check.names = FALSE, stringsAsFactors = FALSE)
      if (!all(c("LTER", "Stream_Name", "Shapefile_Name") %in% names(saved))) next
      saved <- saved[site_key(saved) %in% target_keys, , drop = FALSE]
      if (!nrow(saved)) next
      if (anyDuplicated(site_key(saved))) stop("duplicate source sites in ", path)
      rows <- match(site_key(saved), site_key(sites))
      if (any(saved$Shapefile_Name != reference$Shapefile_Name[rows])) {
        stop("saved MODIS results use a different watershed: ", path)
      }
      columns <- grep(paste(prefixes, collapse = "|"), names(saved), value = TRUE)
      for (column in columns) {
        # fill missing cells only, never replace an existing extraction
        if (!column %in% names(modis)) modis[[column]] <- NA
        if (!column %in% names(era5)) era5[[column]] <- NA
        fill_modis <- is.na(modis[[column]][rows]) & !is.na(saved[[column]])
        fill_era5 <- is.na(era5[[column]][rows]) & !is.na(saved[[column]])
        modis[[column]][rows[fill_modis]] <- saved[[column]][fill_modis]
        era5[[column]][rows[fill_era5]] <- saved[[column]][fill_era5]
        recovered[rows[fill_modis | fill_era5]] <- TRUE
      }
    }
  }

  # recover observed land-cover years using the existing class translation
  # do not invent values for the intervening years in the older five-year product
  land_path <- file.path(data_root, paste0("spatial-data/raw/gee/earth-engine-outputs/",
    "glc-fcs30d/glc_fcs30d_all_637_updated_watersheds_20260811.csv"))
  land <- read.csv(land_path, check.names = FALSE, stringsAsFactors = FALSE)
  classes <- read.csv(class_key, stringsAsFactors = FALSE)
  if (anyDuplicated(classes$LC_ID)) stop("duplicate land-cover class codes")
  land <- land[site_key(land) %in% target_keys, , drop = FALSE]
  keys <- paste(site_key(land), land$Year, land$LC_ID, sep = "\r")
  if (anyDuplicated(keys)) stop("duplicate source land-cover site, year, and class")
  land$Simple_Class <- classes$Simple_Class[match(land$LC_ID, classes$LC_ID)]
  if (anyNA(land$Simple_Class)) stop("unmapped source land-cover class")
  for (key in unique(site_key(land))) {
    source_rows <- land[site_key(land) == key, , drop = FALSE]
    row <- match(key, site_key(sites))
    if (any(source_rows$Shapefile_Name != reference$Shapefile_Name[row])) {
      stop("saved land cover uses a different watershed")
    }
    for (year in unique(source_rows$Year)) {
      if (year < 1985L || year > 2022L) stop("unexpected saved land-cover year")
      annual <- source_rows[source_rows$Year == year, , drop = FALSE]
      if (anyNA(annual$Area_m2) || any(annual$Area_m2 < 0)) stop("invalid land-cover areas")
      total <- sum(annual$Area_m2)
      if (total <= 0) stop("saved land cover has no measured area")
      areas <- tapply(annual$Area_m2, annual$Simple_Class, sum)
      for (class in names(areas)) {
        column <- paste("gee_glc", year, class, sep = "_")
        if (!column %in% names(era5)) stop("source class is absent from the release columns: ", column)
        value <- unname(areas[[class]] / total)
        if (is.na(era5[[column]][row])) era5[[column]][row] <- value
        if (column %in% names(modis) && is.na(modis[[column]][row])) modis[[column]][row] <- value
        recovered[row] <- TRUE
      }
    }
  }

  # add reviewed extractions after removing predictors from the old boundary
  updated <- rep(FALSE, nrow(sites))
  if (nzchar(era5_updates_path)) {
    if (!file.exists(era5_updates_path)) stop("missing downloaded ERA5-Land results: ", era5_updates_path)
    annual <- readRDS(era5_updates_path)
    era5 <- merge_annual_era5_results(era5, annual, reference)
    updated <- site_key(sites) %in% paste(annual$lter, annual$stream_name, sep = "\r")
  }

  # distinguish missing saved exports from sites where spatial data are not expected
  era5_columns <- grep("^era5_land_", names(era5), value = TRUE)
  has_era5 <- if (length(era5_columns)) rowSums(!is.na(era5[era5_columns])) > 0L else rep(FALSE, nrow(sites))
  coverage <- ifelse(reference$Has_Spatial_Data == "No", "spatial data not available",
    ifelse(has_era5, "ERA5-Land values present", "ERA5-Land values absent from assembled inputs"))
  coverage[corrected] <- "spatial predictors need re-extraction for corrected watershed"
  coverage[corrected & updated] <- "ERA5-Land values present; other predictors need re-extraction for corrected watershed"
  notes <- ifelse(recovered,
    "Saved spatial results recovered without replacing existing values; observed land-cover years only", "")
  notes[corrected] <- "Verified watershed boundary replaces the old polygon; old spatial predictors are not reused"
  notes[updated & !corrected] <- "Missing annual ERA5-Land results added for 2000-2025"
  notes[corrected & updated] <- "ERA5-Land re-extracted using verified watershed boundary; other old spatial predictors are not reused"
  list(modis = modis, era5 = era5, has_spatial = reference$Has_Spatial_Data,
    coverage = coverage, recovery_note = notes)
}

# replace annual era5 values only for the reviewed sites in this download
merge_annual_era5_results <- function(data, annual, reference) {
  annual <- as.data.frame(annual)
  products <- c("precip_mm", "temp_degC", "evapotrans_mm", "potential_evap_mm",
    "snow_cover_fraction", "snow_water_equiv_mm")
  required <- c("site_id", "lter", "stream_name", "shapefile_name", "year",
    "source_image_count", "polygon_area_km2", "source_type", "hydrosheds_id", products)
  if (!all(required %in% names(annual))) stop("downloaded ERA5-Land results lack required fields")
  years <- 2000:2025
  if (anyNA(annual[required]) || any(!annual$year %in% years)) {
    stop("downloaded ERA5-Land results contain missing fields or unexpected years")
  }
  keys <- paste(annual$lter, annual$stream_name, sep = "\r")
  annual_keys <- paste(keys, annual$year, sep = "\r")
  expected <- as.vector(outer(unique(keys), years, paste, sep = "\r"))
  if (anyDuplicated(annual_keys) || !setequal(annual_keys, expected)) {
    stop("downloaded ERA5-Land results need one row per site and year for 2000-2025")
  }
  data_keys <- paste(data$LTER, data$Stream_Name, sep = "\r")
  reference_keys <- paste(reference$LTER, reference$Stream_Name, sep = "\r")
  if (anyDuplicated(data_keys) || anyDuplicated(reference_keys)) stop("duplicate spatial site names")
  rows <- match(keys, data_keys)
  reference_rows <- match(keys, reference_keys)
  if (anyNA(rows) || anyNA(reference_rows)) stop("ERA5-Land sites do not match the chemistry and reference sites")
  if (any(reference$Has_Spatial_Data[reference_rows] != "Yes") ||
      any(annual$shapefile_name != reference$Shapefile_Name[reference_rows])) {
    stop("downloaded ERA5-Land results use an unexpected site or watershed")
  }
  expected_days <- ifelse(annual$year %% 4L == 0L, 366L, 365L)
  if (any(annual$source_image_count != expected_days)) stop("incomplete daily coverage in annual ERA5-Land results")
  for (product in products) {
    if (!is.numeric(annual[[product]]) || any(!is.finite(annual[[product]]))) {
      stop("missing or invalid ERA5-Land values: ", product)
    }
  }
  if (any(annual$snow_cover_fraction < 0 | annual$snow_cover_fraction > 1)) {
    stop("ERA5-Land snow-cover fractions must be between zero and one")
  }
  ferguson <- annual$lter == "WesternAustralia" &
    annual$stream_name == "Ferguson River - Dowdells Rd Bridge"
  if (any(abs(annual$polygon_area_km2[ferguson] - 104.973609) > 0.1) ||
      any(annual$source_type[ferguson] != "BoM Geofabric upstream network catchments") ||
      any(annual$hydrosheds_id[ferguson] != "611026")) {
    stop("Ferguson ERA5-Land results do not use the verified boundary")
  }
  for (year in years) {
    selected <- which(annual$year == year)
    for (product in products) {
      column <- paste("era5_land", product, year, sep = "_")
      if (!column %in% names(data)) stop("missing ERA5-Land output column: ", column)
      data[[column]][rows[selected]] <- annual[[product]][selected]
    }
  }
  data
}
