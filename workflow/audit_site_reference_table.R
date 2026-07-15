suppressPackageStartupMessages({
  library(dplyr)
  library(stringi)
})

# Audit every row in the current Site Reference Table


# Settings ----------------------------------------------------------------

spatial_root <- paste0(
  "/Users/sidneybush/Library/CloudStorage/Box-Box/",
  "Sidney_Bush/SiSyn/spatial-data-extractions"
)

site_reference_url <- paste0(
  "https://docs.google.com/spreadsheets/d/",
  "11t9YYTzN_T12VAQhHuY5TpVjGS50ymNmKznJK4rKTIU/",
  "export?format=csv&gid=357814834"
)

spatial_file <- file.path(
  spatial_root,
  "spatial-data-files",
  "appeears-nasa",
  "all-data_si-extract_3_20260629.csv"
)

watershed_check_file <- file.path(
  spatial_root,
  "spatial-data-files",
  "gee",
  "earth-engine-input-files",
  "20260715-gee-watersheds",
  "watershed-geometry-check_20260715.csv"
)

output_file <- file.path(
  spatial_root,
  "qaqc",
  "site-reference-audit_20260715.csv"
)


# Clean names and coordinates ---------------------------------------------

clean_text <- function(x) {
  x <- trimws(gsub("\u00A0", " ", as.character(x), fixed = TRUE))
  x[x == ""] <- NA_character_
  x
}

clean_lter <- function(x) {
  x <- clean_text(x)
  x[tolower(x) %in% c("swedish goverment", "swedish government", "sweden")] <- "Sweden"
  x[tolower(x) == "cameroon"] <- "Congo Basin"
  x[tolower(x) == "eastriversfa"] <- "Coal Creek"
  x
}

clean_stream <- function(x) {
  x <- clean_text(x)
  x[tolower(x) %in% c("east fork", "eastfork")] <- "east fork"
  x[tolower(x) %in% c("west fork", "westfork")] <- "west fork"

  dplyr::recode(
    x,
    "Amazon River at Obidos" = "Obidos",
    "MGWEIR" = "MG_WEIR",
    "ORlow" = "OR_low",
    "OR_WEIR" = "OR_low",
    "coal_11" = "Coal Creek",
    .default = x
  )
}

norm_key <- function(x) {
  x <- stringi::stri_trans_general(clean_text(x), "Latin-ASCII")
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x <- gsub("_+", "_", x)
  x[x == ""] <- NA_character_
  x
}

parse_coordinate <- function(x) {
  x <- gsub("\u2212", "-", as.character(x), fixed = TRUE)
  suppressWarnings(as.numeric(x))
}

regional_file <- function(latitude, longitude) {
  case_when(
    !is.finite(latitude) | !is.finite(longitude) ~ NA_character_,
    !between(latitude, -90, 90) | !between(longitude, -180, 180) ~ NA_character_,
    latitude < -60 ~ NA_character_,
    latitude >= 58 & longitude >= -75 & longitude <= -5 ~ "gr",
    latitude >= 60 & longitude < -50 ~ "ar",
    longitude >= -170 & longitude < -25 & latitude >= 15 ~ "na",
    longitude >= -170 & longitude < -25 & latitude < 15 ~ "sa",
    longitude >= -20 & longitude < 60 & latitude < 30 ~ "af",
    longitude >= -20 & longitude < 60 & latitude >= 30 ~ "eu",
    longitude >= 60 & longitude < 180 & latitude < -12 ~ "au",
    longitude >= 60 & longitude < 180 & latitude >= 50 ~ "si",
    longitude >= 60 & longitude < 180 ~ "as",
    longitude < -170 ~ "na",
    TRUE ~ NA_character_
  )
}

make_key <- function(lter, value) {
  ifelse(
    is.na(lter) | is.na(value),
    NA_character_,
    paste(lter, value, sep = "||")
  )
}

lookup_value <- function(key, lookup_key, lookup_value) {
  lookup_value[match(key, lookup_key)]
}


# Read the three workflow tables ------------------------------------------

reference_raw <- read.csv(
  site_reference_url,
  check.names = TRUE,
  stringsAsFactors = FALSE
)

spatial_raw <- read.csv(
  spatial_file,
  check.names = TRUE,
  stringsAsFactors = FALSE
)

watershed_check_raw <- read.csv(
  watershed_check_file,
  check.names = TRUE,
  stringsAsFactors = FALSE
)


# Prepare the current spatial and watershed keys --------------------------

spatial <- spatial_raw %>%
  transmute(
    lter_key = norm_key(clean_lter(LTER)),
    stream_key = norm_key(clean_stream(Stream_Name)),
    shapefile_key = norm_key(Shapefile_Name),
    spatial_stream_key = make_key(lter_key, stream_key),
    spatial_shapefile_key = make_key(lter_key, shapefile_key)
  )

watersheds <- watershed_check_raw %>%
  transmute(
    lter_key = norm_key(clean_lter(LTER)),
    stream_key = norm_key(clean_stream(Stream_Name)),
    shapefile_key = norm_key(Shapefile_Name),
    watershed_stream_key = make_key(lter_key, stream_key),
    watershed_shapefile_key = make_key(lter_key, shapefile_key),
    watershed_status = clean_text(match_status),
    watershed_exclusion_reason = clean_text(watershed_exclusion_reason)
  )

watershed_stream_lookup <- watersheds %>%
  filter(!is.na(watershed_stream_key)) %>%
  arrange(desc(watershed_status == "matched")) %>%
  distinct(watershed_stream_key, .keep_all = TRUE)

watershed_shapefile_lookup <- watersheds %>%
  filter(!is.na(watershed_shapefile_key)) %>%
  arrange(desc(watershed_status == "matched")) %>%
  distinct(watershed_shapefile_key, .keep_all = TRUE)

# Audit every reference row -----------------------------------------------

audit <- reference_raw %>%
  transmute(
    reference_row = row_number(),
    LTER_original = clean_text(LTER),
    LTER = clean_lter(LTER),
    Original_Stream_Name = clean_text(Original_Stream_Name),
    Stream_Name = clean_stream(Stream_Name),
    Discharge_File_Name = clean_text(Discharge_File_Name),
    USGSGageNumber = clean_text(USGSGageNumber),
    Use_WRTDS = clean_text(Use_WRTDS),
    Shapefile_Name = clean_text(Shapefile_Name),
    Shapefile_Source = clean_text(Shapefile_Source),
    Shapefile_Link = clean_text(Shapefile_Link),
    Shapefile_CRS_EPSG = clean_text(Shapefile_CRS_EPSG),
    drainage_area_km2 = suppressWarnings(as.numeric(drainSqKm)),
    drainage_area_source = clean_text(drainSqKm_source),
    Latitude_original = clean_text(Latitude),
    Longitude_original = clean_text(Longitude),
    latitude = parse_coordinate(Latitude),
    longitude = parse_coordinate(Longitude),
    unicode_minus = grepl("\u2212", as.character(Latitude), fixed = TRUE) |
      grepl("\u2212", as.character(Longitude), fixed = TRUE)
  ) %>%
  mutate(
    lter_key = norm_key(LTER),
    stream_key = norm_key(Stream_Name),
    original_stream_key = norm_key(Original_Stream_Name),
    shapefile_key = norm_key(Shapefile_Name),
    discharge_key = norm_key(Discharge_File_Name),
    reference_stream_key = make_key(lter_key, stream_key),
    reference_original_stream_key = make_key(lter_key, original_stream_key),
    reference_shapefile_key = make_key(lter_key, shapefile_key),
    reference_discharge_key = make_key(lter_key, discharge_key),
    confirmed_coordinate_error = case_when(
      LTER == "PIE" & Stream_Name == "Aberjona" ~ "Aberjona longitude sign",
      LTER == "HYBAM" & tolower(Stream_Name) == "labrea" ~ "Labrea latitude sign",
      LTER == "Sweden" & Stream_Name == "Raan Helsingborg" ~ "Raan Helsingborg location",
      TRUE ~ NA_character_
    ),
    latitude = case_when(
      confirmed_coordinate_error == "Aberjona longitude sign" ~ 42.4474568,
      confirmed_coordinate_error == "Labrea latitude sign" ~ -7.254421,
      confirmed_coordinate_error == "Raan Helsingborg location" ~ 55.99957,
      TRUE ~ latitude
    ),
    longitude = case_when(
      confirmed_coordinate_error == "Aberjona longitude sign" ~ -71.1380816,
      confirmed_coordinate_error == "Labrea latitude sign" ~ -64.801287,
      confirmed_coordinate_error == "Raan Helsingborg location" ~ 12.77950,
      TRUE ~ longitude
    ),
    region_as_supplied = regional_file(latitude, longitude),
    region_if_swapped = regional_file(longitude, latitude),
    reversed_coordinates = is.na(confirmed_coordinate_error) &
      (
        (abs(latitude) > 90 & abs(longitude) <= 90) |
          (is.na(region_as_supplied) & !is.na(region_if_swapped))
      ),
    supplied_latitude = latitude,
    latitude = ifelse(reversed_coordinates, longitude, latitude),
    longitude = ifelse(reversed_coordinates, supplied_latitude, longitude),
    coordinate_status = case_when(
      !is.finite(latitude) | !is.finite(longitude) ~ "missing",
      !between(latitude, -90, 90) | !between(longitude, -180, 180) ~ "invalid",
      !is.na(confirmed_coordinate_error) ~ "corrected_confirmed_error",
      reversed_coordinates ~ "corrected_reversed",
      unicode_minus ~ "parsed_unicode_minus",
      TRUE ~ "valid"
    ),
    Latitude_checked = latitude,
    Longitude_checked = longitude,
    in_spatial_by_stream = !is.na(reference_stream_key) &
      reference_stream_key %in%
        spatial$spatial_stream_key[!is.na(spatial$spatial_stream_key)],
    in_spatial_by_original_stream = !is.na(reference_original_stream_key) &
      reference_original_stream_key %in%
        spatial$spatial_stream_key[!is.na(spatial$spatial_stream_key)],
    in_spatial_by_shapefile = !is.na(reference_shapefile_key) &
      reference_shapefile_key %in%
        spatial$spatial_shapefile_key[!is.na(spatial$spatial_shapefile_key)],
    spatial_match_method = case_when(
      in_spatial_by_stream ~ "stream_name",
      in_spatial_by_original_stream ~ "original_stream_name",
      in_spatial_by_shapefile ~ "shapefile_name",
      TRUE ~ NA_character_
    ),
    in_current_spatial = !is.na(spatial_match_method)
  )


# Add the current GEE watershed status ------------------------------------

audit$watershed_status <- coalesce(
  lookup_value(
    audit$reference_stream_key,
    watershed_stream_lookup$watershed_stream_key,
    watershed_stream_lookup$watershed_status
  ),
  lookup_value(
    audit$reference_original_stream_key,
    watershed_stream_lookup$watershed_stream_key,
    watershed_stream_lookup$watershed_status
  ),
  lookup_value(
    audit$reference_shapefile_key,
    watershed_shapefile_lookup$watershed_shapefile_key,
    watershed_shapefile_lookup$watershed_status
  )
)

audit$watershed_exclusion_reason <- coalesce(
  lookup_value(
    audit$reference_stream_key,
    watershed_stream_lookup$watershed_stream_key,
    watershed_stream_lookup$watershed_exclusion_reason
  ),
  lookup_value(
    audit$reference_original_stream_key,
    watershed_stream_lookup$watershed_stream_key,
    watershed_stream_lookup$watershed_exclusion_reason
  ),
  lookup_value(
    audit$reference_shapefile_key,
    watershed_shapefile_lookup$watershed_shapefile_key,
    watershed_shapefile_lookup$watershed_exclusion_reason
  )
)

audit <- audit %>%
  mutate(
    watershed_status = case_when(
      !in_current_spatial ~ "not_in_current_spatial",
      is.na(watershed_status) ~ "missing_from_watershed_check",
      TRUE ~ watershed_status
    )
  )


# Identify repeated records and missing metadata --------------------------

stream_groups <- audit %>%
  filter(!is.na(reference_stream_key)) %>%
  group_by(reference_stream_key) %>%
  summarise(
    stream_key_rows = n(),
    stream_key_latitude_span = ifelse(
      all(is.na(Latitude_checked)),
      0,
      diff(range(Latitude_checked, na.rm = TRUE))
    ),
    stream_key_longitude_span = ifelse(
      all(is.na(Longitude_checked)),
      0,
      diff(range(Longitude_checked, na.rm = TRUE))
    ),
    .groups = "drop"
  )

coordinate_groups <- audit %>%
  filter(is.finite(Latitude_checked), is.finite(Longitude_checked)) %>%
  mutate(
    coordinate_key = paste(
      round(Latitude_checked, 6),
      round(Longitude_checked, 6),
      sep = "||"
    )
  ) %>%
  group_by(coordinate_key) %>%
  summarise(
    coordinate_rows = n(),
    coordinate_stream_count = n_distinct(reference_stream_key, na.rm = TRUE),
    .groups = "drop"
  )

audit <- audit %>%
  mutate(
    coordinate_key = ifelse(
      is.finite(Latitude_checked) & is.finite(Longitude_checked),
      paste(
        round(Latitude_checked, 6),
        round(Longitude_checked, 6),
        sep = "||"
      ),
      NA_character_
    )
  ) %>%
  left_join(stream_groups, by = "reference_stream_key") %>%
  left_join(coordinate_groups, by = "coordinate_key") %>%
  mutate(
    duplicate_status = case_when(
      stream_key_rows > 1 &
        (stream_key_latitude_span > 0.01 | stream_key_longitude_span > 0.01) ~
        "same_site_name_different_coordinates",
      stream_key_rows > 1 ~ "duplicate_site_row",
      coordinate_stream_count > 1 ~ "shared_coordinate_different_names",
      TRUE ~ "unique"
    ),
    discharge_status = case_when(
      tolower(Use_WRTDS) == "yes" & is.na(Discharge_File_Name) ~
        "wrtds_selected_but_discharge_file_missing",
      tolower(Use_WRTDS) == "yes" ~ "wrtds_selected_with_discharge_file",
      !is.na(Discharge_File_Name) ~ "discharge_file_listed_not_selected_for_wrtds",
      TRUE ~ "no_discharge_file_listed"
    ),
    drainage_area_status = case_when(
      is.finite(drainage_area_km2) & !is.na(drainage_area_source) ~
        "area_and_source_listed",
      is.finite(drainage_area_km2) ~ "area_listed_source_missing",
      TRUE ~ "area_missing"
    ),
    shapefile_metadata_status = case_when(
      is.na(Shapefile_Name) ~ "shapefile_name_missing",
      !is.na(Shapefile_Source) & !is.na(Shapefile_CRS_EPSG) ~
        "name_source_and_crs_listed",
      !is.na(Shapefile_Source) ~ "name_and_source_listed_crs_missing",
      TRUE ~ "shapefile_name_only"
    ),
    workflow_status = case_when(
      watershed_status == "matched" ~ "current_spatial_with_watershed",
      watershed_status == "excluded_from_recovery" ~
        "current_spatial_documented_watershed_exclusion",
      watershed_status == "missing_from_watershed_check" ~
        "current_spatial_missing_watershed_status",
      TRUE ~ "not_in_current_spatial"
    )
  )


# Summarize the reasons each row needs attention --------------------------

audit <- audit %>%
  mutate(
    coordinate_issue = case_when(
      coordinate_status == "missing" ~ "coordinates missing",
      coordinate_status == "invalid" ~ "coordinates invalid",
      coordinate_status == "corrected_confirmed_error" ~
        paste0("confirmed coordinate correction: ", confirmed_coordinate_error),
      coordinate_status == "corrected_reversed" ~
        "latitude and longitude reversed in source table",
      coordinate_status == "parsed_unicode_minus" ~
        "Unicode minus sign in source table",
      TRUE ~ NA_character_
    ),
    discharge_issue = ifelse(
      discharge_status == "wrtds_selected_but_discharge_file_missing",
      "selected for WRTDS but discharge file name is missing",
      NA_character_
    ),
    duplicate_issue = case_when(
      duplicate_status == "same_site_name_different_coordinates" ~
        "same site name has different coordinates",
      duplicate_status == "duplicate_site_row" ~ "duplicate site row",
      duplicate_status == "shared_coordinate_different_names" ~
        "coordinate shared by different site names",
      TRUE ~ NA_character_
    ),
    watershed_issue = case_when(
      workflow_status == "current_spatial_documented_watershed_exclusion" ~
        watershed_exclusion_reason,
      workflow_status == "current_spatial_missing_watershed_status" ~
        "current spatial row is missing from watershed check",
      TRUE ~ NA_character_
    )
  )

reason_columns <- c(
  "coordinate_issue",
  "discharge_issue",
  "duplicate_issue",
  "watershed_issue"
)

audit$audit_reason <- apply(
  audit[, reason_columns, drop = FALSE],
  1,
  function(reasons) {
    reasons <- reasons[!is.na(reasons) & nzchar(reasons)]
    if (!length(reasons)) "none" else paste(reasons, collapse = "; ")
  }
)

reference_stream_keys <- unique(na.omit(c(
  audit$reference_stream_key,
  audit$reference_original_stream_key
)))
reference_shapefile_keys <- unique(na.omit(audit$reference_shapefile_key))

audit <- audit %>%
  mutate(
    review_priority = case_when(
      discharge_status == "wrtds_selected_but_discharge_file_missing" ~ "high",
      coordinate_status %in% c("missing", "invalid", "corrected_confirmed_error") &
        (in_current_spatial | tolower(Use_WRTDS) == "yes") ~ "high",
      workflow_status == "current_spatial_missing_watershed_status" ~ "high",
      coordinate_status %in% c("missing", "invalid", "corrected_confirmed_error") ~
        "medium",
      coordinate_status == "corrected_reversed" & in_current_spatial ~ "medium",
      duplicate_status == "same_site_name_different_coordinates" ~ "medium",
      workflow_status == "current_spatial_documented_watershed_exclusion" ~
        "medium",
      audit_reason != "none" ~ "low",
      TRUE ~ "none"
    )
  ) %>%
  select(
    reference_row,
    LTER_original,
    LTER,
    Original_Stream_Name,
    Stream_Name,
    Discharge_File_Name,
    USGSGageNumber,
    Use_WRTDS,
    drainage_area_km2,
    drainage_area_source,
    Shapefile_Name,
    Shapefile_Source,
    Shapefile_Link,
    Shapefile_CRS_EPSG,
    Latitude_original,
    Longitude_original,
    Latitude_checked,
    Longitude_checked,
    coordinate_status,
    duplicate_status,
    discharge_status,
    drainage_area_status,
    shapefile_metadata_status,
    in_current_spatial,
    spatial_match_method,
    watershed_status,
    workflow_status,
    review_priority,
    audit_reason
  )


# Save one complete audit table -------------------------------------------

dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
write.csv(audit, output_file, row.names = FALSE, na = "")

spatial$represented_in_reference <-
  (!is.na(spatial$spatial_stream_key) &
    spatial$spatial_stream_key %in% reference_stream_keys) |
  (!is.na(spatial$spatial_shapefile_key) &
    spatial$spatial_shapefile_key %in% reference_shapefile_keys)

cat("Rows audited:", nrow(audit), "\n")
cat("Rows represented in the current spatial table:", sum(audit$in_current_spatial), "\n")
cat(
  "Current spatial rows represented in the reference table:",
  sum(spatial$represented_in_reference),
  "of",
  nrow(spatial),
  "\n"
)
cat("Rows linked to a current GEE watershed:", sum(audit$watershed_status == "matched"), "\n")
cat("Rows with documented watershed exclusions:", sum(audit$watershed_status == "excluded_from_recovery"), "\n")
cat("Coordinate status:\n")
print(table(audit$coordinate_status, useNA = "ifany"))
cat("Review priority:\n")
print(table(audit$review_priority, useNA = "ifany"))
cat("Wrote:", output_file, "\n")
