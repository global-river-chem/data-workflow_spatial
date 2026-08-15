### Shared watersheds

read_shared_watershed_aliases <- function(path) {
  aliases <- read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  required <- c(
    "source_LTER", "Shapefile_Name", "source_Stream_Name",
    "alias_LTER", "alias_Stream_Name", "alias_site_id"
  )
  missing <- setdiff(required, names(aliases))
  if (length(missing)) {
    stop(
      "The shared-watershed file is missing: ",
      paste(missing, collapse = ", ")
    )
  }

  aliases[required] <- lapply(aliases[required], trimws)
  if (any(!nzchar(as.matrix(aliases[required])))) {
    stop("The shared-watershed file has blank required values")
  }
  if (anyDuplicated(aliases$alias_site_id)) {
    stop("The shared-watershed file has duplicate alias site IDs")
  }
  aliases
}

add_shared_watershed_aliases <- function(data, alias_file) {
  required <- c("site_id", "LTER", "Stream_Name", "Shapefile_Name")
  missing <- setdiff(required, names(data))
  if (length(missing)) {
    stop(
      "The GLC data is missing shared-watershed fields: ",
      paste(missing, collapse = ", ")
    )
  }

  data$watershed_alias_flag <- FALSE
  data$watershed_alias_source_site_id <- NA_character_
  data$watershed_alias_source_stream_name <- NA_character_
  aliases <- read_shared_watershed_aliases(alias_file)
  copies <- list()

  for (index in seq_len(nrow(aliases))) {
    alias <- aliases[index, ]
    source <- data$LTER == alias$source_LTER &
      data$Shapefile_Name == alias$Shapefile_Name &
      data$Stream_Name == alias$source_Stream_Name
    existing <- data$LTER == alias$alias_LTER &
      data$Shapefile_Name == alias$Shapefile_Name &
      data$Stream_Name == alias$alias_Stream_Name

    if (!any(source)) {
      next
    }
    source_ids <- unique(data$site_id[source])
    if (length(source_ids) != 1L) {
      stop("The shared-watershed source has more than one site ID")
    }
    copy <- data[source, , drop = FALSE]
    copy$site_id <- alias$alias_site_id
    copy$LTER <- alias$alias_LTER
    copy$Stream_Name <- alias$alias_Stream_Name
    copy$watershed_alias_flag <- TRUE
    copy$watershed_alias_source_site_id <- source_ids
    copy$watershed_alias_source_stream_name <- alias$source_Stream_Name
    copies[[length(copies) + 1L]] <- copy
    if (any(existing)) {
      data <- data[!existing, , drop = FALSE]
    }
  }

  if (!length(copies)) {
    return(data)
  }
  dplyr::bind_rows(c(list(data), copies))
}
