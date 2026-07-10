#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(yaml)
})

`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_path <- if (length(script_arg)) sub("^--file=", "", script_arg[[1]]) else "scripts/check-product-config.R"
repo_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
product_config <- file.path(repo_root, "config", "driver-products.yml")

base_required <- c(
  "status",
  "source",
  "gee_id",
  "type",
  "source_temporal_resolution",
  "output_temporal_resolution",
  "output_name"
)

continuous_required <- c(
  "band",
  "output_units",
  "scale_factor",
  "offset",
  "reducer"
)

missing_fields <- function(product) {
  required <- base_required

  if (identical(product$type, "continuous")) {
    required <- c(required, continuous_required)
  }

  if (!identical(product$type, "source_list") &&
      !identical(product$source_temporal_resolution, "static")) {
    required <- c(required, "selected_spatial_resolution_m")
  }

  sort(setdiff(unique(required), names(product)))
}

config <- yaml::read_yaml(product_config)
products <- config$products

if (is.null(products) || !length(products)) {
  stop("No products found in config/driver-products.yml.", call. = FALSE)
}

issues <- lapply(names(products), function(name) {
  missing <- missing_fields(products[[name]] %||% list())
  if (!length(missing)) {
    return(NULL)
  }
  list(name = name, missing = missing)
})
issues <- Filter(Negate(is.null), issues)

status_values <- vapply(products, function(product) product$status %||% "missing", character(1))
type_values <- vapply(products, function(product) product$type %||% "missing", character(1))

cat("Products:", length(products), "\n")
cat("By status:", paste(names(sort(table(status_values))), as.integer(sort(table(status_values))), sep = "=", collapse = ", "), "\n")
cat("By type:", paste(names(sort(table(type_values))), as.integer(sort(table(type_values))), sep = "=", collapse = ", "), "\n")

if (length(issues)) {
  cat("\nMissing fields:\n")
  for (issue in issues) {
    cat("- ", issue$name, ": ", paste(issue$missing, collapse = ", "), "\n", sep = "")
  }
  quit(status = 1)
}

cat("\nProduct config looks OK\n")
