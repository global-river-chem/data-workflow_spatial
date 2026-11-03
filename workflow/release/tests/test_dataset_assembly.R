# ---- test inputs ----

source('workflow/release/update_new_spatial_dataset.R')

fails <- function(expression) {
  inherits(tryCatch(force(expression), error = identity), 'error')
}

# matched, changed-boundary, and unavailable sites exercise different reuse rules
updated <- data.frame(
  LTER = rep('sample', 3), Stream_Name = c('matched', 'changed', 'unavailable'),
  Latitude = 1:3, Longitude = 4:6, drainSqKm = rep(10, 3),
  era5_land_precip_mm_2000 = c(100, 200, NA),
  bess_gpp_1982_gC_m2_year = c(0, 50, NA),
  bess_gpp_1982_trend_flag = c('source_zero_history', 'not_flagged', NA),
  gee_glc_1985_forest = c(60, 40, NA), elevation_mean_m = c(1, 2, NA),
  basin_slope_mean_deg = c(1, 2, NA), rocks_volcanic = c(.2, .3, NA),
  soil_alfisols = c(.5, .6, NA), permafrost_mean_m = c(0, 0, NA),
  temp_2000_degC = c(10, 20, NA), snow_2000_num_days = c(5, 6, NA)
)
glass <- updated[c('LTER', 'Stream_Name', 'Latitude', 'Longitude', 'drainSqKm')]
glass$npp_2001_kgC_m2_year <- c(.4, .5, .6)
glass$greenup_cycle0_2001MMDD <- rep('2001-05-01', 3)
extraction <- glass
extraction$Shapefile_Name <- c('same', 'old', 'absent')
extraction$human_population_total_people_2000 <- c(20, 30, 40)
extraction$human_population_data_coverage_fraction_2000 <- c(1, .9, 1)
extraction$human_dam_barrier_count <- c(0, 1, 2)
extraction$human_fertilizer_n_crop_layers <- c(2, 2, 2)
extraction$human_wastewater_plant_count <- c(0, 1, 2)
extraction$downstream_to_outlet_km <- c(12, 20, 30)
extraction$downstream_to_ocean_km <- c(NA, 20, 30)
extraction$endorheic <- c(TRUE, FALSE, FALSE)
extraction$drains_to_ocean <- c(FALSE, TRUE, TRUE)
extraction$coast_distance_status <- c('endorheic_no_ocean_outlet', 'ocean_connected', 'ocean_connected')
metadata <- data.frame(
  LTER = updated$LTER, Stream_Name = updated$Stream_Name,
  Has_Spatial_Data = c('Yes', 'Yes', 'No'),
  Watershed_File_Name = c('same', 'corrected', 'absent')
)

# ---- product and watershed checks ----

original_glass <- glass
result <- update_new_spatial_data(updated, glass, extraction, metadata)
stopifnot(
  identical(glass, original_glass), identical(result$Stream_Name, updated$Stream_Name),
  identical(result$bess_gpp_1982_gC_m2_year, updated$bess_gpp_1982_gC_m2_year),
  identical(result$bess_gpp_1982_trend_flag, updated$bess_gpp_1982_trend_flag),
  identical(result$era5_land_precip_mm_2000, updated$era5_land_precip_mm_2000),
  !any(grepl('^(temp_|snow_)', names(result))),
  result$human_dam_barrier_count[1] == 0,
  all(is.na(result$human_dam_barrier_count[2:3])),
  all(is.na(result$npp_2001_kgC_m2_year[2:3])),
  result$greenup_cycle0_2001MMDD[1] == '2001-05-01',
  result$downstream_to_outlet_km[1] == 12,
  is.na(result$downstream_to_ocean_km[1]),
  identical(result, update_new_spatial_data(result, glass, extraction, metadata))
)

# missing products, invalid quality fields, and duplicate keys must stop assembly
stopifnot(fails(update_new_spatial_data(updated, glass[!grepl('^npp_', names(glass))], extraction, metadata)))
stopifnot(fails(update_new_spatial_data(updated, glass, extraction[!grepl('^human_dam_', names(extraction))], metadata)))
invalid <- extraction
invalid$human_population_data_coverage_fraction_2000[1] <- 1.1
stopifnot(fails(update_new_spatial_data(updated, glass, invalid, metadata)))
stopifnot(fails(update_new_spatial_data(updated, glass, extraction, rbind(metadata, metadata[1, ]))))

# ---- file protection checks ----

check_protected_paths <- function() {
  path <- tempfile('protected-assembly-input-')
  file.create(path)
  on.exit(unlink(path), add = TRUE)
  before <- tools::md5sum(path)
  for (script in c('add_bess_to_combined.R', 'update_new_spatial_dataset.R')) {
    args <- c(file.path('workflow/release', script), '--combined-input', path,
      '--glass-input', path, '--saved-input', path, '--metadata', path, '--overwrite', 'true')
    output <- suppressWarnings(system2('Rscript', shQuote(args), stdout = TRUE, stderr = TRUE))
    stopifnot(!is.null(attr(output, 'status')), any(grepl('must remain untouched|must be separate', output)),
      identical(before, tools::md5sum(path)))
  }
}
check_protected_paths()
cat('Dataset assembly checks passed\n')
