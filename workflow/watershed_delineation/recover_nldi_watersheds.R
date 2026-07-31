# Recover USGS NLDI watersheds for selected site-table rows. Registered USGS
# sites and COMIDs can be supplied in the override table; other rows use the
# point-specific split-catchment service.

suppressPackageStartupMessages({
  library(httr2)
  library(sf)
})

source(file.path("workflow", "lib", "workflow_helpers.R"))

args <- commandArgs(trailingOnly = TRUE)
sites_path <- cli_value(args, "--sites", required = TRUE)
output_root <- cli_value(args, "--output-root", required = TRUE)
override_path <- cli_value(
  args,
  "--source-overrides",
  file.path("workflow", "watershed_delineation", "config", "nldi_source_overrides.tsv")
)
maximum_area_difference_pct <- as.numeric(
  cli_value(args, "--maximum-area-difference-pct", "25")
)
maximum_outlet_distance_m <- as.numeric(cli_value(args, "--maximum-outlet-distance-m", "100"))
strict_area_check <- cli_boolean(args, "--strict-area-check", FALSE)
dir.create(output_root, recursive = TRUE, showWarnings = FALSE)

sites <- read_workflow_table(sites_path)
require_columns(
  sites,
  c("LTER", "Stream_Name", "Shapefile_Name", "Latitude", "Longitude", "drainSqKm"),
  "site table"
)
sites <- select_site_rows(sites, args)
sites$Reference_Area_km2 <- independent_reference_area(sites)
sites$NLDI_Source_Type <- ""
sites$NLDI_Source_ID <- ""

if (nzchar(override_path) && file.exists(override_path)) {
  overrides <- read_workflow_table(override_path)
  require_columns(
    overrides,
    c("LTER", "Stream_Name", "NLDI_Source_Type", "NLDI_Source_ID"),
    "NLDI source overrides"
  )
  override_key <- paste(overrides$LTER, overrides$Stream_Name, sep = "::")
  site_key <- paste(sites$LTER, sites$Stream_Name, sep = "::")
  matched <- match(site_key, override_key)
  use_override <- !is.na(matched)
  sites$NLDI_Source_Type[use_override] <- overrides$NLDI_Source_Type[matched[use_override]]
  sites$NLDI_Source_ID[use_override] <- overrides$NLDI_Source_ID[matched[use_override]]
}

if ("USGSGageNumber" %in% names(sites)) {
  has_gage <- !nzchar(sites$NLDI_Source_Type) & nzchar(trimws(sites$USGSGageNumber))
  sites$NLDI_Source_Type[has_gage] <- "nwissite"
  sites$NLDI_Source_ID[has_gage] <- paste0(
    "USGS-",
    sub("^USGS-", "", trimws(sites$USGSGageNumber[has_gage]))
  )
}
sites$NLDI_Source_Type[!nzchar(sites$NLDI_Source_Type)] <- "point"

api_root <- "https://api.water.usgs.gov/nldi"

read_response <- function(response) {
  path <- tempfile(fileext = ".geojson")
  on.exit(unlink(path), add = TRUE)
  writeBin(resp_body_raw(response), path)
  st_read(path, quiet = TRUE)
}

fetch_polygon <- function(site) {
  source_type <- trimws(site$NLDI_Source_Type)
  source_id <- trimws(site$NLDI_Source_ID)
  if (source_type == "point") {
    body <- list(inputs = list(
      list(id = "lat", value = as.character(site$Latitude), type = "text/plain"),
      list(id = "lon", value = as.character(site$Longitude), type = "text/plain"),
      list(id = "upstream", value = "True", type = "text/plain")
    ))
    response <- request(paste0(
      api_root,
      "/pygeoapi/processes/nldi-splitcatchment/execution?f=json"
    )) |>
      req_method("POST") |>
      req_headers(`Content-Type` = "application/json") |>
      req_body_json(body, auto_unbox = TRUE) |>
      req_retry(max_tries = 5) |>
      req_timeout(300) |>
      req_perform()
    returned <- read_response(response)
    if ("id" %in% names(returned) && "drainageBasin" %in% returned$id) {
      returned <- returned[returned$id == "drainageBasin", , drop = FALSE]
    }
    source_url <- paste0(api_root, "/pygeoapi/processes/nldi-splitcatchment")
  } else {
    if (!source_type %in% c("nwissite", "comid") || !nzchar(source_id)) {
      stop("Unsupported or incomplete NLDI source for ", site$LTER, " / ", site$Stream_Name)
    }
    source_url <- sprintf(
      "%s/linked-data/%s/%s/basin?f=json&simplified=false",
      api_root,
      source_type,
      source_id
    )
    response <- request(source_url) |>
      req_retry(max_tries = 5) |>
      req_timeout(300) |>
      req_perform()
    returned <- read_response(response)
  }
  if (!nrow(returned)) stop("NLDI returned no polygon for ", site$LTER, " / ", site$Stream_Name)
  list(
    polygon = st_transform(st_make_valid(st_sf(geometry = st_union(st_geometry(returned)))), 4326),
    source_url = source_url
  )
}

build_one <- function(site) {
  fetched <- fetch_polygon(site)
  polygon <- fetched$polygon
  point <- st_sfc(
    st_point(c(as.numeric(site$Longitude), as.numeric(site$Latitude))),
    crs = 4326
  )
  area_km2 <- as.numeric(st_area(st_transform(polygon, 6933))) / 1e6
  outlet_distance_m <- as.numeric(st_distance(st_transform(point, 6933), st_transform(polygon, 6933)))
  reference_area_km2 <- suppressWarnings(as.numeric(site$Reference_Area_km2))
  area_difference_pct <- if (is.finite(reference_area_km2) && reference_area_km2 > 0) {
    100 * (area_km2 - reference_area_km2) / reference_area_km2
  } else {
    NA_real_
  }
  status <- if (!is.finite(outlet_distance_m) || outlet_distance_m > maximum_outlet_distance_m) {
    "outlet_mismatch"
  } else if (is.finite(area_difference_pct) &&
      abs(area_difference_pct) > maximum_area_difference_pct) {
    "reference_area_mismatch"
  } else if (!is.finite(reference_area_km2)) {
    "no_independent_area_check"
  } else {
    "passed"
  }
  if (status == "outlet_mismatch" || (strict_area_check && status == "reference_area_mismatch")) {
    stop(site$LTER, " / ", site$Stream_Name, " failed NLDI QA: ", status)
  }

  output_dir <- file.path(output_root, site$Shapefile_Name)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  output_path <- file.path(output_dir, paste0(site$Shapefile_Name, ".shp"))
  polygon$site_id <- paste(normalize_key(site$LTER), normalize_key(site$Stream_Name), sep = "__")
  polygon$LTER <- site$LTER
  polygon$stream <- site$Stream_Name
  polygon$shp_name <- site$Shapefile_Name
  polygon$src_type <- site$NLDI_Source_Type
  polygon$source_id <- site$NLDI_Source_ID
  polygon$area_km2 <- area_km2
  st_write(polygon, output_path, delete_layer = TRUE, quiet = TRUE)

  data.frame(
    LTER = site$LTER,
    Stream_Name = site$Stream_Name,
    Shapefile_Name = site$Shapefile_Name,
    source_type = site$NLDI_Source_Type,
    source_id = site$NLDI_Source_ID,
    source_url = fetched$source_url,
    area_km2 = area_km2,
    reference_area_km2 = reference_area_km2,
    area_difference_pct = area_difference_pct,
    outlet_distance_m = outlet_distance_m,
    status = status,
    output_path = output_path,
    stringsAsFactors = FALSE
  )
}

qa <- do.call(rbind, lapply(seq_len(nrow(sites)), function(index) build_one(sites[index, ])))
write.table(
  qa,
  file.path(output_root, "nldi_delineation_qa.tsv"),
  sep = "\t",
  quote = FALSE,
  row.names = FALSE,
  na = ""
)
saveRDS(qa, file.path(output_root, "nldi_delineation_qa.rds"))
print(qa, row.names = FALSE)
