# ---- offline checks for source values and saved-input guards ----

script <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]))
folder <- normalizePath(file.path(dirname(script), ".."))
repo <- normalizePath(file.path(folder, "..", ".."))
source(file.path(repo, "workflow", "lib", "workflow_helpers.R"))
source(file.path(folder, "vegetation_helpers.R"))
source(file.path(folder, "bess_helpers.R"))
source(file.path(folder, "bess_monthly_helpers.R"))
source(file.path(repo, "workflow", "release", "recover_saved_spatial_results.R"))

run_checks <- function() {
  temporary <- tempfile("vegetation-checks-")
  dir.create(temporary)
  on.exit(unlink(temporary, recursive = TRUE), add = TRUE)
  fails <- function(expression) inherits(tryCatch(force(expression), error = identity), "error")
  stopifnot(identical(vegetation_years("1982:2022", 1982L, 2022L), 1982:2022))
  stopifnot(fails(vegetation_years("2022:1982", 1982L, 2022L)))

  # monthly means become annual totals using the actual calendar-day counts
  months <- bess_months(c(2019L, 2020L))
  stopifnot(length(months) == 24L, sum(bess_month_days(months[1:12])) == 365L,
    sum(bess_month_days(months[13:24])) == 366L,
    bess_month_days(as.Date("2020-02-01")) == 29L)
  monthly_points <- data.frame(site = c("sample", "sample"), weight = c(1, 3))
  annual <- bess_annual_totals(monthly_points, c(732, 1098), c(12L, 12L), c(366L, 366L), 2020L)
  stopifnot(annual$gpp_gC_m2_year == 1006.5, annual$valid_days == 366L, annual$valid_area_fraction == 1)
  partial_annual <- bess_annual_totals(monthly_points, c(732, 900), c(12L, 11L), c(366L, 335L), 2020L)
  stopifnot(is.na(partial_annual$gpp_gC_m2_year), partial_annual$valid_area_fraction == .25)
  aliases <- data.frame(site = c("sample", "sample", NA), LTER = c("one", "two", "none"),
    Stream_Name = c("a", "b", "c"), Shapefile_Name = c("shared", "shared", ""),
    Has_Spatial_Data = c("Yes", "Yes", "No"))
  expanded <- bess_site_totals(annual, monthly_points, aliases)
  stopifnot(nrow(expanded) == 2L, all(expanded$gpp_gC_m2_year == 1006.5))

  # flag the reviewed watershed histories, including their positive years
  reviewed <- data.frame(LTER = c("Canada", "Canada", "Canada", "Canada"),
    Shapefile_Name = c("sisyn_canada_eccc_wsc_nw10uf0003", "sisyn_canada_eccc_wsc_nw10uf0003",
      "sisyn_canada_eccc_wsc_nw10vk0002", "another_watershed"),
    year = c(1982L, 2001L, 2000L, 2001L), gpp_gC_m2_year = c(35.6, 0, 18, 0))
  flagged <- bess_trend_flags(reviewed)
  stopifnot(identical(flagged[names(reviewed)], reviewed),
    identical(flagged$bess_trend_flag, c(rep("source_zero_history", 3), "not_flagged")),
    identical(bess_trend_flags(flagged), flagged))

  # bess releases exclude retired predictors while preserving zeros and missing sites
  combined <- data.frame(LTER = aliases$LTER, Stream_Name = aliases$Stream_Name,
    evapotrans_2020 = c(5, 0, NA), npp_2020 = 1, greenup_2020 = 100,
    ndvi_2020 = .6, vipphen_2020 = 100, galsp_2020 = 100)
  checked <- expanded
  checked$gpp_gC_m2_year[2] <- 0
  merged <- add_bess_gpp(combined, checked, aliases)
  stopifnot(!any(bess_excluded_columns(names(merged))),
    identical(merged$evapotrans_2020, combined$evapotrans_2020),
    identical(merged$LTER, combined$LTER), merged$bess_gpp_2020_gC_m2_year[2] == 0,
    is.na(merged$bess_gpp_2020_gC_m2_year[3]),
    identical(merged$bess_gpp_2020_trend_flag[1:2], checked$bess_trend_flag))

  # changing the requested years or file contents must prevent checkpoint reuse
  input <- file.path(temporary, "input.txt")
  writeLines("reviewed input", input)
  output <- file.path(temporary, "output")
  dir.create(output)
  record <- vegetation_run_record(output, input, list(years = 2002L), script)
  stopifnot(identical(record, vegetation_run_record(output, input, list(years = 2002L), script)))
  stopifnot(fails(vegetation_run_record(output, input, list(years = 2003L), script)))
  writeLines("changed input", input)
  stopifnot(fails(vegetation_run_record(output, input, list(years = 2002L), script)))

  # edge cells must retain their overlap area even when their centers fall outside
  ring <- rbind(c(0, 0), c(.13, 0), c(.13, .08), c(0, .08), c(0, 0))
  watershed <- sf::st_sf(site_id = "sample", geometry = sf::st_sfc(sf::st_polygon(list(ring)), crs = 4326))
  polygon_path <- file.path(temporary, "watershed.geojson")
  sf::st_write(watershed, polygon_path, quiet = TRUE)
  product <- "bess"
  point_path <- file.path(temporary, paste0(product, ".geojson"))
  status <- system2(file.path(R.home("bin"), "Rscript"), c(shQuote(file.path(folder, "prepare_vegetation_points.R")),
    "--watersheds", shQuote(polygon_path), "--id-column", "site_id", "--product", product, "--output", shQuote(point_path)))
  stopifnot(status == 0L)
  step <- .05
  native_points <- read_vegetation_points(point_path, step)
  stopifnot(abs(sum(native_points$weight) / native_points$watershed_area_m2[1] - 1) < .0001)
  table_path <- file.path(temporary, paste0(product, ".rds"))
  status <- system2(file.path(R.home("bin"), "Rscript"), c(shQuote(file.path(folder, "prepare_vegetation_points.R")),
    "--watersheds", shQuote(polygon_path), "--id-column", "site_id", "--product", product, "--output", shQuote(table_path)))
  stopifnot(status == 0L)
  table_points <- read_vegetation_points(table_path, step)
  stopifnot(isTRUE(all.equal(table_points$weight, native_points$weight)),
    isTRUE(all.equal(table_points$longitude, native_points$longitude)))

  # a sparse native-grid netcdf verifies scaling and missing-value handling
  if (!requireNamespace("ncdf4", quietly = TRUE)) stop("Install ncdf4 to run the BESS source-value checks")
  lat <- ncdf4::ncdim_def("lat", "degrees_north", seq(89.975, -89.975, by = -.05))
  lon <- ncdf4::ncdim_def("lon", "degrees_east", seq(-179.975, 179.975, by = .05))
  variable <- ncdf4::ncvar_def("GPP", "gC m-2 d-1", list(lat, lon), -9999,
    prec = "short", compression = 1, chunksizes = c(100, 100)
  )
  path <- file.path(temporary, "sample.nc")
  file <- ncdf4::nc_create(path, variable)
  ncdf4::ncvar_put(file, "GPP", 100L, start = c(1L, 1L), count = c(1L, 1L))
  ncdf4::ncvar_put(file, "GPP", -9999L, start = c(2L, 2L), count = c(1L, 1L))
  ncdf4::nc_close(file)
  native <- data.frame(
    site = c("first", "missing"), latitude = c(89.975, 89.925),
    longitude = c(-179.975, -179.925)
  )
  value <- read_gpp(path, native)
  stopifnot(value[1] == 1, is.na(value[2]))
  stopifnot(identical(value, read_gpp(path, native, whole_grid = TRUE)))
  file <- ncdf4::nc_open(path, write = TRUE)
  ncdf4::ncatt_put(file, "GPP", "scale_factor", .02)
  ncdf4::nc_close(file)
  stopifnot(fails(read_gpp(path, native)))

  # resume a cached monthly extraction and verify the final leap-year total
  file <- ncdf4::nc_open(path, write = TRUE)
  ncdf4::ncatt_put(file, "GPP", "scale_factor", .01)
  ncdf4::ncvar_put(file, "GPP", 300L, start = c(2L, 2L), count = c(1L, 1L))
  ncdf4::nc_close(file)
  monthly_output <- file.path(temporary, "monthly-output")
  cache <- file.path(monthly_output, "monthly-files")
  dir.create(cache, recursive = TRUE)
  dates <- bess_months(2020L)
  catalog <- data.frame(name = paste0("BESS_GPP_Monthly.A", format(dates, "%Y%m"), ".nc"))
  catalog$drive_resource <- rep(list(list(size = file.info(path)$size,
    md5Checksum = unname(tools::md5sum(path)))), 12)
  for (name in catalog$name) stopifnot(file.copy(path, file.path(cache, name)))
  saveRDS(catalog, file.path(monthly_output, "source-files.rds"))
  native$site <- "sample"
  native$weight <- c(1, 3)
  record <- list(files = tools::md5sum(input))
  settings <- list(folder = "unused", download_pause_seconds = 0)
  run_bess_monthly(native, 2020L, settings, monthly_output, record, test = TRUE)
  stopifnot(sum(readRDS(file.path(monthly_output, "monthly-checkpoint.rds"))$completed) == 1L)
  run_bess_monthly(native, 2020L, settings, monthly_output, record)
  annual <- readRDS(file.path(monthly_output, "annual-gpp.rds"))
  stopifnot(nrow(annual) == 1L, annual$gpp_gC_m2_year == 915,
    annual$valid_days == 366L, annual$valid_area_fraction == 1)
  invisible(TRUE)
}
run_checks()
