# ---- migrated dataset ----

update_new_spatial_data <- function(data, glass, saved, metadata) {
  # reject incomplete inputs before matching sites or replacing any values
  tables <- list(updated = data, glass = glass, extraction = saved, metadata = metadata)
  required <- list(
    updated = c('LTER', 'Stream_Name', 'Latitude', 'Longitude', 'drainSqKm'),
    glass = c('LTER', 'Stream_Name', 'Latitude', 'Longitude', 'drainSqKm'),
    extraction = c('LTER', 'Stream_Name', 'Shapefile_Name', 'drainSqKm',
      'downstream_to_outlet_km', 'downstream_to_ocean_km', 'endorheic',
      'drains_to_ocean', 'coast_distance_status'),
    metadata = c('LTER', 'Stream_Name', 'Has_Spatial_Data', 'Watershed_File_Name')
  )
  key <- function(x) paste(x$LTER, x$Stream_Name, sep = '\r')
  for (name in names(tables)) {
    table <- tables[[name]]
    missing <- setdiff(required[[name]], names(table))
    if (length(missing)) stop(name, ' input is missing: ', paste(missing, collapse = ', '))
    if (anyNA(table[c('LTER', 'Stream_Name')]) ||
        any(!nzchar(trimws(table$LTER))) || any(!nzchar(trimws(table$Stream_Name)))) {
      stop(name, ' input has blank site keys')
    }
    if (anyDuplicated(key(table))) stop('duplicate site keys')
  }
  if (anyNA(metadata$Has_Spatial_Data) ||
      any(!metadata$Has_Spatial_Data %in% c('Yes', 'No'))) {
    stop('metadata need yes or no spatial-data status for every site')
  }

  # require each retained product rather than accepting a partial product list
  for (pattern in c('^era5_land_', '^bess_gpp_', '^gee_glc_', '^elevation_',
      '^basin_slope_', '^rocks_', '^soil_', '^permafrost_')) {
    if (!any(grepl(pattern, names(data)))) stop('updated input is missing product fields: ', pattern)
  }
  for (pattern in c('^human_population_', '^human_dam_', '^human_fertilizer_', '^human_wastewater_')) {
    if (!any(grepl(pattern, names(saved)))) stop('extraction input is missing product fields: ', pattern)
  }
  for (pattern in c('^npp_', '^greenup_')) {
    if (!any(grepl(pattern, names(glass)))) stop('glass input is missing product fields: ', pattern)
  }
  original <- data

  # ---- source matching ----

  # require current watershed identity and area before using older extractions
  rows <- match(key(data), key(saved))
  meta_rows <- match(key(data), key(metadata))
  if (anyNA(meta_rows)) stop('current metadata are missing sites')
  spatial <- metadata$Has_Spatial_Data[meta_rows] == 'Yes'
  same_area <- function(source, matched) {
    abs(data$drainSqKm - source$drainSqKm[matched]) <= pmax(.001, data$drainSqKm * .001)
  }
  same_watershed <- tolower(trimws(metadata$Watershed_File_Name[meta_rows])) ==
    tolower(trimws(saved$Shapefile_Name[rows]))
  matched <- !is.na(rows) & spatial & same_area(saved, rows) & same_watershed
  matched[is.na(matched)] <- FALSE

  # accept saved zeros and retain coverage and record-count fields for interpretation
  coast_pattern <- paste0('^(hydrorivers_|HYRIV_ID$|MAIN_RIV$|NEXT_DOWN$|HYBAS_L12$|',
    'downstream_|upland_skm$|reach_length_km$|discharge_est_cms$|endorheic$|',
    'drains_to_ocean$|coast_distance_status$|ORD_|snap_distance_km$|point_match_method$)')
  human <- grep('^human_', names(saved), value = TRUE)
  coast <- grep(coast_pattern, names(saved), value = TRUE)
  vegetation <- grep('^(npp_|greenup_)', names(glass), value = TRUE)
  if (!length(human) || !length(coast) || !length(vegetation)) stop('saved product fields are missing')
  if (!all(vapply(saved[human], is.numeric, logical(1)))) {
    stop('human-impact extraction fields must be numeric')
  }
  if (any(vapply(saved[human], function(x) any(!is.finite(x[!is.na(x)])) || any(x < 0, na.rm = TRUE), logical(1)))) {
    stop('invalid human-impact values')
  }
  coverage <- grep('coverage_fraction', human, value = TRUE)
  if (any(vapply(saved[coverage], function(x) any(x < 0 | x > 1, na.rm = TRUE), logical(1)))) stop('invalid coverage')
  for (column in c(human, coast)) {
    values <- saved[[column]][rows]
    values[!matched] <- NA
    data[[column]] <- values
  }
  data$human_results_status <- ifelse(matched, 'saved_watershed_match', 'not_available_for_current_watershed')
  # keep inland outlet distance while leaving ocean distance missing for closed basins
  inland <- !is.na(data$endorheic) & data$endorheic == TRUE
  if (any(!is.na(data$downstream_to_ocean_km[inland]))) stop('closed basins have ocean distances')

  # ---- modis vegetation ----

  # restore the original modis values without changing the glass source file
  old_rows <- match(key(data), key(glass))
  old_match <- !is.na(old_rows) & spatial & same_area(glass, old_rows) &
    abs(data$Latitude - glass$Latitude[old_rows]) < .001 &
    abs(data$Longitude - glass$Longitude[old_rows]) < .001
  old_match[is.na(old_match)] <- FALSE
  # a known watershed change also blocks reuse from the glass table
  changed_watershed <- !is.na(rows) & !is.na(same_watershed) & !same_watershed
  old_match[changed_watershed] <- FALSE
  for (column in vegetation) {
    values <- glass[[column]][old_rows]
    values[!old_match] <- NA
    # use the earlier saved source only where watershed identity was verified
    fallback <- !old_match & matched
    if (column %in% names(saved)) values[fallback] <- saved[[column]][rows[fallback]]
    data[[column]] <- values
  }
  data$modis_vegetation_status <- ifelse(old_match, 'GLASS_source_site_match',
    ifelse(matched, 'saved_watershed_match', 'not_available_for_current_watershed'))

  # ---- migrated product selection ----

  # era5-land replaces overlapping climate, evapotranspiration, and snow products
  removed <- grepl('^(temp_|precip_|evapotrans_|snow_|ndvi_|pku_|vipphen_|galsp_|gimms4g_greenup_|noaa_ndvi_|bess_greenup_)', names(data), ignore.case = TRUE)
  data <- data[, !removed, drop = FALSE]
  retained <- setdiff(intersect(names(original), names(data)), c(human, coast, vegetation, "human_results_status", "modis_vegetation_status"))
  stopifnot(identical(data[retained], original[retained]), nrow(data) == nrow(original))
  data
}

# ---- command line ----

if (sys.nframe() == 0L) {
  # ---- inputs ----

  # update only the migrated dataset from saved, reviewed source tables
  argument <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  repo <- normalizePath(file.path(dirname(sub('^--file=', '', argument[[1]])), '../..'))
  source(file.path(repo, 'workflow/lib/workflow_helpers.R'))
  args <- commandArgs(trailingOnly = TRUE)
  input <- require_input_file(cli_value(args, '--combined-input', required = TRUE), 'new dataset')
  glass_path <- require_input_file(cli_value(args, '--glass-input', required = TRUE), 'unchanged GLASS dataset')
  saved_path <- require_input_file(cli_value(args, '--saved-input', required = TRUE), 'saved human and river results')
  metadata_path <- require_input_file(cli_value(args, '--metadata', required = TRUE), 'current site metadata')
  source_paths <- normalizePath(c(glass_path, saved_path, metadata_path))
  if (normalizePath(input) %in% source_paths) {
    stop('the updated output must be separate from the GLASS, extraction, and metadata inputs')
  }
  if (!cli_boolean(args, '--overwrite', FALSE)) stop('use --overwrite true to update the new dataset')
  read_table <- function(path) read.csv(path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = '')
  data <- read_table(input)
  glass <- read_table(glass_path)
  saved <- read_table(saved_path)
  metadata <- read_table(metadata_path)
  glass_hash <- tools::md5sum(glass_path)
  data <- update_new_spatial_data(data, glass, saved, metadata)
  # ---- verified replacement ----

  # read back the temporary output before replacing the requested dataset
  partial <- paste0(input, '.partial')
  tryCatch({
    write.csv(data, partial, row.names = FALSE, na = '')
    checked <- read_table(partial)
    stopifnot(isTRUE(all.equal(data, checked, check.attributes = FALSE, tolerance = 1e-12)),
      identical(tools::md5sum(glass_path), glass_hash))
    if (!file.rename(partial, input)) stop('could not replace the new dataset')
  }, finally = if (file.exists(partial)) unlink(partial))
  cat(nrow(data), 'sites;', ncol(data), 'fields\n')
}
