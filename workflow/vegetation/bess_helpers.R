# ---- read gpp values from a source file ----

read_gpp <- function(path, points, whole_grid = FALSE) {
  n <- ncdf4::nc_open(path)
  on.exit(ncdf4::nc_close(n))
  stopifnot(
    identical(names(n$var), "GPP"), n$dim$lat$len == 3600L,
    n$dim$lon$len == 7200L,
    identical(vapply(n$var$GPP$dim, `[[`, "", "name"), c("lat", "lon")),
    ncdf4::ncatt_get(n, "GPP", "units")$value == "gC m-2 d-1",
    ncdf4::ncatt_get(n, "GPP", "_FillValue")$value == -9999
  )
  # the provider specifies scaling outside the netcdf attributes
  scale <- ncdf4::ncatt_get(n, "GPP", "scale_factor")
  stopifnot(!scale$hasatt || scale$value == 0.01)
  lat <- ncdf4::ncvar_get(n, "lat")
  lon <- ncdf4::ncvar_get(n, "lon")
  stopifnot(
    max(abs(lat - seq(89.975, -89.975, by = -0.05))) < 0.00002,
    max(abs(lon - seq(-179.975, 179.975, by = 0.05))) < 0.00002
  )
  row <- round((89.975 - points$latitude) / 0.05) + 1L
  column <- round((points$longitude + 179.975) / 0.05) + 1L
  stopifnot(
    max(abs(lat[row] - points$latitude)) < 0.00002,
    max(abs(lon[column] - points$longitude)) < 0.00002
  )
  raw <- rep(NA_real_, nrow(points))
  if (whole_grid) {
    # read once when many overlapping watersheds share the same global file
    values <- ncdf4::ncvar_get(n, "GPP", raw_datavals = TRUE, collapse_degen = FALSE)
    raw <- values[cbind(row, column)]
  } else for (site in unique(points$site)) {
    i <- which(points$site == site)
    row_range <- range(row[i])
    column_range <- range(column[i])
    block <- ncdf4::ncvar_get(n, "GPP",
      start = c(row_range[1], column_range[1]),
      count = c(diff(row_range) + 1L, diff(column_range) + 1L), raw_datavals = TRUE,
      collapse_degen = FALSE
    )
    raw[i] <- block[cbind(row[i] - row_range[1] + 1L, column[i] - column_range[1] + 1L)]
  }
  stopifnot(all(is.finite(raw)), all(raw == -9999 | raw >= 0))
  raw[raw == -9999] <- NA_real_
  raw * 0.01
}
