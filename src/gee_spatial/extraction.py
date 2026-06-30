"""Reusable pieces for GEE watershed extractions."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any, Dict, Optional

import yaml


def load_run_config(path: str | Path) -> Dict[str, Any]:
    with Path(path).open(encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def load_watersheds(asset_id: str):
    if not asset_id or asset_id.startswith("REPLACE_"):
        raise ValueError("Set watersheds.asset_id in config/gee-assets.yml before running")

    import ee

    watersheds = ee.FeatureCollection(asset_id)
    try:
        watersheds.limit(1).size().getInfo()
    except Exception as exc:
        raise RuntimeError(
            "Could not read the watershed asset. Upload the current watershed file listed in "
            "config/gee-assets.yml before launching exports."
        ) from exc

    return watersheds


def get_product(products_config: Dict[str, Any], product_name: str) -> Dict[str, Any]:
    products = products_config.get("products") or {}

    if product_name not in products:
        raise KeyError(f"Product not found in config: {product_name}")

    return products[product_name]


def date_window(year: int, month: Optional[int] = None) -> tuple[str, str]:
    if month is None:
        return f"{year}-01-01", f"{year + 1}-01-01"

    if month < 1 or month > 12:
        raise ValueError("month must be between 1 and 12")

    start = date(year, month, 1)
    if month == 12:
        end = date(year + 1, 1, 1)
    else:
        end = date(year, month + 1, 1)

    return start.isoformat(), end.isoformat()


def ee_reducer(name: str):
    import ee

    reducers = {
        "mean": ee.Reducer.mean,
        "median": ee.Reducer.median,
        "sum": ee.Reducer.sum,
        "min": ee.Reducer.min,
        "max": ee.Reducer.max,
    }

    if name not in reducers:
        raise ValueError(f"Unsupported reducer: {name}")

    return reducers[name]()


def aggregate_collection(collection, method: str):
    methods = {
        "mean": collection.mean,
        "median": collection.median,
        "sum": collection.sum,
        "min": collection.min,
        "max": collection.max,
        "first": collection.first,
    }

    if method not in methods:
        raise ValueError(f"Unsupported image aggregation: {method}")

    return methods[method]()


def apply_scale_offset(image, product: Dict[str, Any]):
    scale_factor = product.get("scale_factor", 1)
    offset = product.get("offset", 0)
    output_name = product.get("output_name", product.get("band", "value"))

    return image.multiply(scale_factor).add(offset).rename(output_name)


def build_continuous_image(
    product: Dict[str, Any],
    year: Optional[int] = None,
    month: Optional[int] = None,
):
    if product.get("type") != "continuous":
        raise ValueError("build_continuous_image only supports continuous products")

    import ee

    temporal_resolution = product.get("source_temporal_resolution")
    gee_id = product["gee_id"]
    band = product.get("band")

    if temporal_resolution == "static":
        image = ee.Image(gee_id).select(band)
    else:
        if year is None:
            raise ValueError("year is required for non-static products")

        start_date, end_date = date_window(year, month)
        collection = ee.ImageCollection(gee_id).filterDate(start_date, end_date).select(band)

        if temporal_resolution == "daily":
            method_key = "daily_to_monthly" if month is not None else "daily_to_annual"
            method = product.get(method_key, "mean")
            image = aggregate_collection(collection, method)
        elif temporal_resolution == "annual":
            image = aggregate_collection(collection, product.get("annual_image", "first"))
        else:
            raise ValueError(f"Unsupported temporal resolution: {temporal_resolution}")

    image = apply_scale_offset(image, product)

    properties = {
        "driver": product.get("output_name"),
        "source": product.get("source"),
        "gee_id": product.get("gee_id"),
        "units": product.get("output_units"),
    }

    if year is not None:
        properties["year"] = year

    if month is not None:
        properties["month"] = month

    return image.set(properties)


def summarize_image_by_watersheds(
    image,
    watersheds,
    reducer=None,
    scale: Optional[float] = None,
    crs: Optional[str] = None,
    tile_scale: int = 4,
):
    import ee

    export_reducer = reducer or ee.Reducer.mean()
    kwargs = {
        "collection": watersheds,
        "reducer": export_reducer,
        "tileScale": tile_scale,
    }

    if scale is not None:
        kwargs["scale"] = scale

    if crs is not None:
        kwargs["crs"] = crs

    return image.reduceRegions(**kwargs)


def extract_continuous_product(
    product_name: str,
    products_config: Dict[str, Any],
    watersheds,
    year: Optional[int] = None,
    month: Optional[int] = None,
):
    product = get_product(products_config, product_name)
    image = build_continuous_image(product, year=year, month=month)

    scale = product.get("selected_spatial_resolution_m")
    summary = summarize_image_by_watersheds(
        image=image,
        watersheds=watersheds,
        reducer=ee_reducer(product.get("reducer", "mean")),
        scale=scale,
    )

    properties = {
        "driver": product_name,
        "output_name": product.get("output_name"),
        "units": product.get("output_units"),
        "period": "monthly" if month is not None else "annual",
    }

    if year is not None:
        properties["year"] = year

    if month is not None:
        properties["month"] = month

    return summary.map(lambda feature: feature.set(properties))
