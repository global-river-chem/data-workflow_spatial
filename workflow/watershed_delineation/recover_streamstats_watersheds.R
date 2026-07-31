# Screen unresolved U.S. river and stream sites with the official USGS
# StreamStats delineation service. Successful delineations remain candidates
# until the outlet, site identity, and drainage area pass the checks below.

suppressPackageStartupMessages({
  library(data.table)
  library(httr2)
  library(jsonlite)
  library(sf)
})

sf_use_s2(FALSE)

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
audit_path <- cli_value(args, "--audit", required = TRUE)
accepted_gpkg <- cli_value(args, "--existing-watersheds", required = TRUE)
output_dir <- cli_value(args, "--output-root", required = TRUE)
shapefile_root <- cli_value(args, "--shapefile-root", required = TRUE)
cache_dir <- cli_value(args, "--cache-root", file.path(tempdir(), "streamstats-recovery"))

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(audit_path), file.exists(accepted_gpkg))

safe_name <- function(x) {
  x <- iconv(x, to = "ASCII//TRANSLIT")
  x <- tolower(gsub("[^A-Za-z0-9]+", "_", x))
  gsub("(^_+|_+$)", "", x)
}

site_key <- function(lter, stream) {
  paste(tolower(trimws(lter)), tolower(trimws(stream)), sep = "||")
}

haversine_m <- function(lon1, lat1, lon2, lat2) {
  rad <- pi / 180
  a <- sin((lat2 - lat1) * rad / 2)^2 +
    cos(lat1 * rad) * cos(lat2 * rad) * sin((lon2 - lon1) * rad / 2)^2
  6371008.8 * 2 * atan2(sqrt(a), sqrt(1 - a))
}

first_named_item <- function(items, target) {
  names_found <- vapply(items, function(x) tolower(x$name %||% ""), character(1))
  index <- which(names_found == tolower(target))
  if (!length(index)) return(NULL)
  items[[index[[1]]]]
}

`%||%` <- function(x, y) {
  if (is.null(x) || !length(x)) y else x
}

extract_streamstats <- function(response_path) {
  parsed <- fromJSON(response_path, simplifyVector = FALSE)
  if (!is.null(parsed$detail)) {
    return(list(ok = FALSE, error = as.character(parsed$detail)))
  }

  collections <- parsed$bcrequest$wsresp$featurecollection
  if (is.null(collections) || !length(collections) || !length(collections[[1]])) {
    return(list(ok = FALSE, error = "StreamStats returned no feature collections"))
  }
  items <- collections[[1]]
  point_item <- first_named_item(items, "globalwatershedpoint")
  basin_item <- first_named_item(items, "globalwatershed")
  if (is.null(point_item) || is.null(basin_item)) {
    return(list(ok = FALSE, error = "StreamStats response lacks a pour point or watershed"))
  }

  point_features <- point_item$feature$features
  basin_features <- basin_item$feature$features
  if (!length(point_features) || !length(basin_features)) {
    return(list(ok = FALSE, error = "StreamStats returned an empty pour point or watershed"))
  }

  global_index <- which(vapply(basin_features, function(x) {
    props <- x$properties
    value <- props$GlobalWshd %||% props$globalWshd %||% props$GLOBALWSHD %||% 0
    isTRUE(as.numeric(value) == 1)
  }, logical(1)))
  if (!length(global_index)) global_index <- 1L

  point_feature <- point_features[[1]]
  basin_feature <- basin_features[[global_index[[1]]]]
  geometry_json <- as.character(toJSON(basin_feature$geometry, auto_unbox = TRUE))
  geometry <- st_as_sfc(geometry_json, GeoJSON = TRUE, crs = 4326)
  geometry <- st_make_valid(geometry)

  point_coords <- unlist(point_feature$geometry$coordinates, use.names = FALSE)
  point_warning <- point_feature$properties$WarningMsg %||% ""
  basin_warning <- basin_feature$properties$WarningMsg %||% ""
  warning <- trimws(paste(point_warning, basin_warning))
  shape_area <- basin_feature$properties$Shape_Area %||%
    basin_feature$properties$shape_area %||% NA_real_

  list(
    ok = TRUE,
    geometry = geometry,
    snapped_lon = as.numeric(point_coords[[1]]),
    snapped_lat = as.numeric(point_coords[[2]]),
    warning = warning,
    shape_area_km2 = as.numeric(shape_area) / 1e6,
    huc_id = as.character(point_feature$properties$HUCID %||% ""),
    exclusion_type = as.character(point_feature$properties$ExclusionType %||% "")
  )
}

query_streamstats <- function(region, lat, lon, cache_path) {
  if (!file.exists(cache_path) || file.info(cache_path)$size < 20L) {
    url <- sprintf(
      "https://streamstats.usgs.gov/ss-delineate/v1/delineate/sshydro/%s",
      region
    )
    result <- tryCatch(
      request(url) |>
        req_url_query(lat = sprintf("%.8f", lat), lon = sprintf("%.8f", lon)) |>
        req_retry(max_tries = 3, backoff = function(...) 2) |>
        req_error(is_error = function(resp) FALSE) |>
        req_timeout(180) |>
        req_perform(),
      error = function(e) e
    )
    if (inherits(result, "error")) {
      return(list(ok = FALSE, error = conditionMessage(result)))
    }
    writeBin(resp_body_raw(result), cache_path)
  }

  tryCatch(
    extract_streamstats(cache_path),
    error = function(e) list(ok = FALSE, error = conditionMessage(e))
  )
}

streamstats_request_url <- function(region, lat, lon) {
  sprintf(
    paste0(
      "https://streamstats.usgs.gov/ss-delineate/v1/delineate/sshydro/%s",
      "?lat=%.8f&lon=%.8f"
    ),
    tolower(region), lat, lon
  )
}

audit <- fread(audit_path)
accepted <- st_read(accepted_gpkg, quiet = TRUE)
accepted_keys <- site_key(accepted$LTER, accepted$Stream_Name)

us_lters <- c(
  "AND", "ARC", "BNZ", "BcCZO", "Catalina Jemez", "ColoradoAlpine",
  "EastRiverSFA", "HBR", "KNZ", "KRR", "LMP", "LUQ", "PIE",
  "Sagehen", "UMR", "USGS", "Walker Branch"
)

candidates <- audit[
  LTER %in% us_lters &
    include_under_user_rule == TRUE &
    has_valid_coordinates == TRUE &
    has_accepted_geometry != TRUE &
    recommended_action != "already in current spatial table"
]
candidates <- candidates[
  !site_key(LTER, Stream_Name) %in% accepted_keys
]

candidates[, region := fcase(
  LTER %in% c("BcCZO", "ColoradoAlpine"), "CO",
  LTER == "Catalina Jemez", "AZ",
  LTER == "LMP", "NH",
  LTER %in% c("ARC", "BNZ"), "AK",
  LTER == "LUQ", "PR",
  default = ""
)]

colorado_lakes <- c(
  "sky", "emerald", "louise", "haiyaha", "glass", "husted", "andrewstarn"
)
candidates[, waterbody_exclusion := ""]
candidates[
  LTER == "ColoradoAlpine" & tolower(Stream_Name) %in% colorado_lakes,
  waterbody_exclusion := "exclude: lake or tarn, not a river or stream site"
]
candidates[
  grepl("seep", Stream_Name, ignore.case = TRUE),
  waterbody_exclusion := "exclude: seep, not a river or stream site"
]
candidates[
  grepl("swamp", Stream_Name, ignore.case = TRUE),
  waterbody_exclusion := "exclude: wetland/swamp site"
]
candidates[
  LTER == "BcCZO" & Stream_Name %in% c("GGU_SPW_1", "GGU_SPW_2"),
  waterbody_exclusion := "exclude: spring sampling site, not a river or stream site"
]

alias_of <- c(
  "BcCZO||GGL_SW_0_ISCO" = "BcCZO||GGL_SW_0",
  "BcCZO||GGU_SW_0_ISCO" = "BcCZO||GGU_SW_0"
)
candidates[, alias_key := paste(LTER, Stream_Name, sep = "||")]
candidates[, alias_of := unname(alias_of[alias_key])]
candidates[is.na(alias_of), alias_of := ""]
candidates[, request_streamstats :=
  region != "" & waterbody_exclusion == "" & alias_of == ""]

setorder(candidates, region, LTER, Stream_Name)

status_rows <- vector("list", nrow(candidates))
polygon_rows <- list()
polygon_index <- 0L

for (i in seq_len(nrow(candidates))) {
  site <- candidates[i]
  base <- list(
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Latitude = as.numeric(site$Latitude),
    Longitude = as.numeric(site$Longitude),
    drainSqKm = as.numeric(site$drainSqKm),
    region = site$region,
    chemistry_years_any = as.integer(site$chemistry_years_any),
    chemistry_years_dsi = as.integer(site$chemistry_years_dsi),
    use_wrtds = isTRUE(site$use_wrtds_yes),
    waterbody_exclusion = site$waterbody_exclusion,
    alias_of = site$alias_of,
    streamstats_requested = isTRUE(site$request_streamstats),
    streamstats_status = "not requested",
    streamstats_warning = "",
    snapped_latitude = NA_real_,
    snapped_longitude = NA_real_,
    snap_distance_m = NA_real_,
    streamstats_area_km2 = NA_real_,
    reference_area_error_pct = NA_real_,
    huc_id = "",
    proposed_shapefile_name = "",
    qa_status = if (nzchar(site$waterbody_exclusion)) site$waterbody_exclusion else
      if (nzchar(site$alias_of)) "hold: duplicate site alias; use the primary site review" else
        "not screened",
    source_url = streamstats_request_url(
      site$region, as.numeric(site$Latitude), as.numeric(site$Longitude)
    )
  )

  if (!isTRUE(site$request_streamstats)) {
    status_rows[[i]] <- base
    next
  }

  cache_path <- file.path(
    cache_dir,
    sprintf("%s_%s.json", tolower(site$region), safe_name(paste(site$LTER, site$Stream_Name)))
  )
  cat(sprintf(
    "StreamStats %d/%d: %s — %s\n",
    i, nrow(candidates), site$LTER, site$Stream_Name
  ))
  result <- query_streamstats(
    site$region, as.numeric(site$Latitude), as.numeric(site$Longitude), cache_path
  )

  if (!isTRUE(result$ok)) {
    base$streamstats_status <- "no watershed returned"
    base$qa_status <- paste0("not recovered: ", result$error)
    status_rows[[i]] <- base
    next
  }

  snap_distance <- haversine_m(
    as.numeric(site$Longitude), as.numeric(site$Latitude),
    result$snapped_lon, result$snapped_lat
  )
  area_km2 <- result$shape_area_km2
  if (!is.finite(area_km2)) {
    area_km2 <- as.numeric(st_area(st_transform(result$geometry, 6933))) / 1e6
  }
  area_error <- if (is.finite(as.numeric(site$drainSqKm))) {
    100 * (area_km2 - as.numeric(site$drainSqKm)) / as.numeric(site$drainSqKm)
  } else {
    NA_real_
  }

  warning_present <- nzchar(trimws(result$warning))
  qa_status <- "candidate needs independent outlet and drainage-area validation"
  if (warning_present) {
    qa_status <- "hold: StreamStats returned a snapping or delineation warning"
  } else if (!is.finite(area_km2) || area_km2 < 0.01) {
    qa_status <- "hold: implausibly small or missing watershed area"
  } else if (snap_distance > 100) {
    qa_status <- "hold: StreamStats snapped more than 100 m from the reference coordinate"
  } else if (is.finite(area_error) && abs(area_error) <= 25) {
    qa_status <- "accepted candidate: StreamStats area agrees with the reference area"
  }

  proposed_name <- paste0(safe_name(site$Stream_Name), "_streamstats")
  base$streamstats_status <- "watershed returned"
  base$streamstats_warning <- result$warning
  base$snapped_latitude <- result$snapped_lat
  base$snapped_longitude <- result$snapped_lon
  base$snap_distance_m <- snap_distance
  base$streamstats_area_km2 <- area_km2
  base$reference_area_error_pct <- area_error
  base$huc_id <- result$huc_id
  base$proposed_shapefile_name <- proposed_name
  base$qa_status <- qa_status
  status_rows[[i]] <- base

  polygon_index <- polygon_index + 1L
  polygon_rows[[polygon_index]] <- st_sf(
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Shapefile_Name = proposed_name,
    polygon_source = "USGS StreamStats watershed delineation",
    source_url = streamstats_request_url(
      site$region, as.numeric(site$Latitude), as.numeric(site$Longitude)
    ),
    huc_id = result$huc_id,
    area_km2 = area_km2,
    reference_area_km2 = as.numeric(site$drainSqKm),
    area_error_pct = area_error,
    snap_distance_m = snap_distance,
    streamstats_warning = result$warning,
    qa_status = qa_status,
    geometry = result$geometry
  )
}

status <- rbindlist(status_rows, fill = TRUE)

# Copy primary-site results to explicit aliases without issuing duplicate API calls.
for (i in which(nzchar(status$alias_of))) {
  primary_parts <- strsplit(status$alias_of[[i]], "\\|\\|")[[1]]
  primary <- status[LTER == primary_parts[[1]] & Stream_Name == primary_parts[[2]]]
  if (nrow(primary) == 1L) {
    status[i, `:=`(
      streamstats_status = primary$streamstats_status,
      streamstats_warning = primary$streamstats_warning,
      snapped_latitude = primary$snapped_latitude,
      snapped_longitude = primary$snapped_longitude,
      snap_distance_m = primary$snap_distance_m,
      streamstats_area_km2 = primary$streamstats_area_km2,
      reference_area_error_pct = primary$reference_area_error_pct,
      huc_id = primary$huc_id,
      proposed_shapefile_name = primary$proposed_shapefile_name,
      qa_status = "hold: duplicate site alias; use the primary site's watershed"
    )]
  }
}

polygons <- if (length(polygon_rows)) do.call(rbind, polygon_rows) else NULL

if (!is.null(polygons) && nrow(polygons)) {
  duplicate_group <- rep("", nrow(polygons))
  group_number <- 0L
  if (nrow(polygons) > 1L) {
    for (i in seq_len(nrow(polygons) - 1L)) {
      for (j in seq.int(i + 1L, nrow(polygons))) {
        if (lengths(st_equals(polygons[i, ], polygons[j, ])) > 0L) {
          labels <- unique(c(duplicate_group[[i]], duplicate_group[[j]]))
          labels <- labels[nzchar(labels)]
          if (length(labels)) {
            label <- labels[[1]]
          } else {
            group_number <- group_number + 1L
            label <- paste0("identical_streamstats_geometry_", group_number)
          }
          duplicate_group[c(i, j)] <- label
        }
      }
    }
  }
  polygons$duplicate_geometry_group <- duplicate_group
  duplicate_sites <- st_drop_geometry(polygons)
  duplicate_sites <- duplicate_sites[
    nzchar(duplicate_sites$duplicate_geometry_group),
    c("LTER", "Stream_Name", "duplicate_geometry_group"),
    drop = FALSE
  ]
  if (nrow(duplicate_sites)) {
    status[duplicate_sites, on = .(LTER, Stream_Name), `:=`(
      qa_status = "hold: identical watershed returned for multiple site labels"
    )]
    polygons$qa_status[nzchar(polygons$duplicate_geometry_group)] <-
      "hold: identical watershed returned for multiple site labels"
  }

  # These eight sites have independent project documentation and clean,
  # physically consistent StreamStats results. The nested-area checks guard
  # against accepting a polygon snapped to the wrong branch of the network.
  validation <- data.table(
    LTER = c(
      rep("BcCZO", 6),
      rep("Catalina Jemez", 2)
    ),
    Stream_Name = c(
      "BC_SW_20", "BC_SW_12", "BC_SW_4", "BC_SW_2",
      "GGL_SW_0", "GGU_SW_0", "OR_mid", "OR_up"
    ),
    published_area_km2 = c(
      NA, NA, NA, NA, 2.6252, 0.9466, NA, NA
    ),
    validation_source_url = c(
      rep("https://www.hydroshare.org/resource/6938ed69fb704022b40b194426cc8302/", 4),
      rep("https://czo-archive.criticalzone.org/boulder/infrastructure/field-area/gordon-gulch/", 2),
      rep("https://czo-archive.criticalzone.org/catalina-jemez/infrastructure/field-area/oracle-ridge-mid-elevation/", 2)
    ),
    validation_note = c(
      rep("Official Boulder Creek stream-sampling coordinate; watershed areas increase consistently downstream.", 4),
      "StreamStats area agrees with the published 2.6252 km2 lower Gordon Gulch area.",
      "StreamStats area agrees with the published 0.9466 km2 upper Gordon Gulch area.",
      rep("Nested Oracle Ridge stream subwatershed within the published 1.09 km2 field catchment.", 2)
    )
  )

  status[, `:=`(
    final_decision = "hold",
    validation_source_url = "",
    validation_note = ""
  )]
  status[validation, on = .(LTER, Stream_Name), `:=`(
    published_area_km2 = i.published_area_km2,
    validation_source_url = i.validation_source_url,
    validation_note = i.validation_note
  )]

  polygon_keys <- site_key(polygons$LTER, polygons$Stream_Name)
  status_keys <- site_key(status$LTER, status$Stream_Name)
  validation_keys <- site_key(validation$LTER, validation$Stream_Name)
  accepted_status <- status_keys %in% validation_keys &
    status$streamstats_status == "watershed returned" &
    !nzchar(trimws(status$streamstats_warning)) &
    is.finite(status$streamstats_area_km2) &
    status$streamstats_area_km2 >= 0.01 &
    is.finite(status$snap_distance_m) &
    status$snap_distance_m <= 100

  area_check <- !is.finite(status$published_area_km2) |
    abs(100 * (status$streamstats_area_km2 - status$published_area_km2) /
      status$published_area_km2) <= 25
  oracle_check <- !(status$LTER == "Catalina Jemez" &
    status$Stream_Name %in% c("OR_mid", "OR_up")) |
    status$streamstats_area_km2 <= 1.09
  accepted_status <- accepted_status & area_check & oracle_check

  containment_fraction <- function(inner_name, outer_name) {
    inner <- st_transform(polygons[polygons$Stream_Name == inner_name, ], 6933)
    outer <- st_transform(polygons[polygons$Stream_Name == outer_name, ], 6933)
    if (nrow(inner) != 1L || nrow(outer) != 1L) return(0)
    overlap <- suppressWarnings(st_intersection(inner, outer))
    sum(as.numeric(st_area(overlap))) / sum(as.numeric(st_area(inner)))
  }
  nested_checks <- c(
    containment_fraction("BC_SW_20", "BC_SW_12"),
    containment_fraction("BC_SW_12", "BC_SW_4"),
    containment_fraction("BC_SW_4", "BC_SW_2"),
    containment_fraction("GGU_SW_0", "GGL_SW_0"),
    containment_fraction("OR_up", "OR_mid")
  )
  stopifnot(all(nested_checks >= 0.99))

  status$final_decision[accepted_status] <- "accepted"
  status$qa_status[accepted_status] <-
    "accepted: official stream site and independently checked StreamStats watershed"

  polygon_status_index <- match(polygon_keys, status_keys)
  polygons$final_decision <- status$final_decision[polygon_status_index]
  polygons$validation_source_url <- status$validation_source_url[polygon_status_index]
  polygons$validation_note <- status$validation_note[polygon_status_index]
  polygons$qa_status <- status$qa_status[polygon_status_index]

  gpkg_path <- file.path(output_dir, "streamstats_candidate_watersheds.gpkg")
  if (file.exists(gpkg_path)) file.remove(gpkg_path)
  st_write(polygons, gpkg_path, layer = "streamstats_candidates", quiet = TRUE)

  accepted <- polygons[polygons$final_decision == "accepted", ]
  accepted_path <- file.path(output_dir, "streamstats_accepted_watersheds.gpkg")
  if (file.exists(accepted_path)) file.remove(accepted_path)
  st_write(accepted, accepted_path, layer = "streamstats_accepted", quiet = TRUE)

  dir.create(shapefile_root, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(accepted))) {
    shp_name <- accepted$Shapefile_Name[[i]]
    site_dir <- file.path(shapefile_root, shp_name)
    dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)
    shp_path <- file.path(site_dir, paste0(shp_name, ".shp"))
    if (file.exists(shp_path)) st_delete(shp_path, quiet = TRUE)
    st_write(accepted[i, ], shp_path, quiet = TRUE)
  }
}

setorder(status, LTER, Stream_Name)
fwrite(
  status,
  file.path(output_dir, "streamstats_site_review.tsv"),
  sep = "\t", na = ""
)

cat("Unresolved eligible U.S. rows reviewed: ", nrow(status), "\n", sep = "")
cat("Excluded non-river/non-stream rows: ", sum(nzchar(status$waterbody_exclusion)), "\n", sep = "")
cat("StreamStats requests made: ", sum(status$streamstats_requested), "\n", sep = "")
cat("Watersheds returned: ", sum(status$streamstats_status == "watershed returned"), "\n", sep = "")
cat("Accepted watersheds: ", sum(status$final_decision == "accepted"), "\n", sep = "")
print(status[, .N, by = .(region, streamstats_status, qa_status)][order(region, qa_status)])
