### Constants

gee_api_root <- "https://earthengine.googleapis.com/v1"
gee_token_uri <- "https://oauth2.googleapis.com/token"
gee_client_id <- paste0(
  "517222506229-vsmmajv00ul0bs7p89v5m89qs8eb9359.",
  "apps.googleusercontent.com"
)
gee_client_secret <- "RUP0RZ6e0pPhDzsqIJ7KlNd1"

`%||%` <- function(value, fallback) {
  if (is.null(value) || length(value) == 0) fallback else value
}

### Authentication

gee_access_token <- function(
  credentials_path = path.expand("~/.config/earthengine/credentials")
) {
  if (!file.exists(credentials_path)) {
    stop("Earth Engine credentials are missing: ", credentials_path)
  }
  credentials <- jsonlite::fromJSON(
    credentials_path,
    simplifyVector = FALSE
  )
  refresh_token <- credentials$refresh_token %||% ""
  if (!nzchar(refresh_token)) {
    stop("Earth Engine credentials do not contain a refresh token")
  }
  request <- httr2::request(gee_token_uri)
  request <- httr2::req_body_form(
    request,
    client_id = credentials$client_id %||% gee_client_id,
    client_secret = credentials$client_secret %||% gee_client_secret,
    refresh_token = refresh_token,
    grant_type = "refresh_token"
  )
  response <- httr2::req_perform(request)
  token <- httr2::resp_body_json(response, simplifyVector = FALSE)$access_token
  if (is.null(token) || !nzchar(token)) {
    stop("Earth Engine authentication did not return an access token")
  }
  token
}

gee_request <- function(
  method,
  url,
  token,
  project,
  query = list(),
  body = NULL
) {
  request <- httr2::request(url)
  request <- httr2::req_method(request, method)
  request <- httr2::req_headers(
    request,
    Authorization = paste("Bearer", token),
    `X-Goog-User-Project` = project
  )
  if (length(query)) {
    request <- do.call(httr2::req_url_query, c(list(request), query))
  }
  if (!is.null(body)) {
    request <- httr2::req_body_json(
      request,
      body,
      auto_unbox = TRUE,
      null = "null",
      digits = NA
    )
  }
  request <- httr2::req_retry(request, max_tries = 3)
  response <- httr2::req_perform(request)
  httr2::resp_body_json(response, simplifyVector = FALSE)
}

### Operations

gee_list_operations <- function(project, token = gee_access_token()) {
  operations <- list()
  page_token <- NULL
  repeat {
    query <- list(pageSize = 1000)
    if (!is.null(page_token)) {
      query$pageToken <- page_token
    }
    payload <- gee_request(
      "GET",
      sprintf("%s/projects/%s/operations", gee_api_root, project),
      token,
      project,
      query = query
    )
    operations <- c(operations, payload$operations %||% list())
    page_token <- payload$nextPageToken %||% NULL
    if (is.null(page_token) || !nzchar(page_token)) {
      break
    }
  }
  operations
}

gee_cancel_operation <- function(name, project, token = gee_access_token()) {
  gee_request(
    "POST",
    sprintf("%s/%s:cancel", gee_api_root, name),
    token,
    project,
    body = structure(list(), names = character())
  )
  invisible(TRUE)
}

gee_operation_description <- function(operation) {
  as.character(operation$metadata$description %||% "")
}

gee_operation_state <- function(operation) {
  toupper(as.character(operation$metadata$state %||% ""))
}

gee_operation_eecu_seconds <- function(operation) {
  metadata <- operation$metadata %||% list()
  value <- metadata$batchEecuUsageSeconds %||%
    metadata$batch_eecu_usage_seconds %||% 0
  max(0, as.numeric(value))
}

### Assets

gee_list_assets <- function(parent, project, token = gee_access_token()) {
  assets <- list()
  page_token <- NULL
  repeat {
    query <- list(pageSize = 1000)
    if (!is.null(page_token)) {
      query$pageToken <- page_token
    }
    payload <- gee_request(
      "GET",
      sprintf("%s/%s:listAssets", gee_api_root, parent),
      token,
      project,
      query = query
    )
    assets <- c(assets, payload$assets %||% list())
    page_token <- payload$nextPageToken %||% NULL
    if (is.null(page_token) || !nzchar(page_token)) {
      break
    }
  }
  assets
}

gee_collection_expression <- function(asset_id) {
  list(
    result = "0",
    values = structure(
      list(
        list(
          functionInvocationValue = list(
            functionName = "Collection.loadTable",
            arguments = list(
              tableId = list(constantValue = asset_id)
            )
          )
        )
      ),
      names = "0"
    )
  )
}

gee_compute_features <- function(
  asset_id,
  project,
  token = gee_access_token(),
  page_size = 1000
) {
  features <- list()
  page_token <- NULL
  repeat {
    body <- list(
      expression = gee_collection_expression(asset_id),
      pageSize = page_size
    )
    if (!is.null(page_token)) {
      body$pageToken <- page_token
    }
    payload <- gee_request(
      "POST",
      sprintf("%s/projects/%s/table:computeFeatures", gee_api_root, project),
      token,
      project,
      body = body
    )
    features <- c(features, payload$features %||% list())
    page_token <- payload$nextPageToken %||%
      payload$next_page_token %||% NULL
    if (is.null(page_token) || !nzchar(page_token)) {
      break
    }
  }
  features
}

### Monitoring

gee_monitoring_seconds <- function(
  project,
  metric,
  start_utc,
  end_utc,
  token = gee_access_token()
) {
  endpoint <- sprintf(
    "https://monitoring.googleapis.com/v3/projects/%s/timeSeries",
    project
  )
  seconds <- 0
  page_token <- NULL
  repeat {
    query <- list(
      filter = sprintf('metric.type="%s"', metric),
      `interval.startTime` = start_utc,
      `interval.endTime` = end_utc,
      `aggregation.alignmentPeriod` = "86400s",
      `aggregation.perSeriesAligner` = "ALIGN_SUM",
      `aggregation.crossSeriesReducer` = "REDUCE_SUM",
      view = "FULL",
      pageSize = 1000
    )
    if (!is.null(page_token)) {
      query$pageToken <- page_token
    }
    payload <- gee_request(
      "GET",
      endpoint,
      token,
      project,
      query = query
    )
    for (series in payload$timeSeries %||% list()) {
      for (point in series$points %||% list()) {
        value <- point$value$doubleValue %||%
          point$value$int64Value %||% 0
        seconds <- seconds + as.numeric(value)
      }
    }
    page_token <- payload$nextPageToken %||% NULL
    if (is.null(page_token) || !nzchar(page_token)) {
      break
    }
  }
  seconds
}
