"""Reusable pieces for GEE watershed extractions."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any, Dict, Optional

import yaml


EXPORT_COLUMNS = [
    "site_id",
    "lter",
    "shapefile_name",
    "stream_name",
    "Q_file_name",
    "run_group",
    "hydrosheds_used",
    "hydrosheds_id",
    "expected_area_km2",
    "drainage_area_source",
    "polygon_area_km2",
    "tiny_watershed",
    "source_type",
    "driver",
    "output_name",
    "period",
    "year",
    "month",
    "units",
    "value",
    "used_fine_scale_fallback",
]


ERA5_METADATA_COLUMNS = [
    "site_id",
    "lter",
    "shapefile_name",
    "stream_name",
    "Q_file_name",
    "run_group",
    "hydrosheds_used",
    "hydrosheds_id",
    "expected_area_km2",
    "drainage_area_source",
    "polygon_area_km2",
    "tiny_watershed",
    "source_type",
    "period",
    "year",
    "month",
]


ERA5_DEFAULT_VALUE_COLUMNS = [
    "precip_mm",
    "temp_degC",
    "evapotrans_mm",
    "potential_evap_mm",
    "snow_cover_fraction",
    "snow_water_equiv_mm",
]


ERA5_EXPORT_COLUMNS = [
    *ERA5_METADATA_COLUMNS,
    *ERA5_DEFAULT_VALUE_COLUMNS,
    "used_fine_scale_fallback",
]


PROPERTY_NAMES = {
    "site_id": ["site_id"],
    "lter": ["LTER", "lter"],
    "shapefile_name": ["Shapefile_Name", "Shpfl_N"],
    "stream_name": ["Stream_Name", "Strm_Nm"],
    "Q_file_name": ["Discharge_File_Name", "Dsc_F_N"],
    "run_group": ["run_group", "run_grp"],
    "hydrosheds_used": ["hydrosheds_used", "hydrshds_s"],
    "hydrosheds_id": ["hydrosheds_id", "hydrshds_d"],
    "expected_area_km2": ["expected_area_km2", "expc__2"],
    "drainage_area_source": ["drainage_area_source", "drain_src", "drn_src"],
    "polygon_area_km2": ["polygon_area_km2", "plyg__2"],
    "tiny_watershed": ["tiny_watershed", "tiny_ws"],
    "source_type": ["source_type", "src_typ"],
}


DEFAULT_ERA5_PRODUCTS = [
    "precip",
    "temp",
    "evapotrans",
    "potential_evap",
    "snow_cover",
    "snow_water_equiv",
]
TINY_WATERSHED_AREA_KM2 = 10


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

    def summarize_feature(feature):
        kwargs = {
            "reducer": export_reducer,
            "geometry": feature.geometry(),
            "tileScale": tile_scale,
            "maxPixels": 100000000,
        }

        if scale is not None:
            kwargs["scale"] = scale

        if crs is not None:
            kwargs["crs"] = crs

        values = image.reduceRegion(**kwargs)
        return feature.set(values)

    return watersheds.map(summarize_feature)


def fallback_scale_value(scale: Optional[float], divisor: int = 10):
    if scale is None:
        return None

    return scale / divisor


def fill_missing_values_at_fine_scale(
    summary,
    image,
    output_names: list[str],
    reducer=None,
    scale: Optional[float] = None,
    fine_scale: Optional[float] = None,
    tile_scale: int = 4,
):
    import ee

    export_reducer = reducer or ee.Reducer.mean()
    retry_scale = fine_scale if fine_scale is not None else fallback_scale_value(scale)

    def fill_feature(feature):
        kwargs = {
            "reducer": export_reducer,
            "geometry": feature.geometry(),
            "tileScale": tile_scale,
            "maxPixels": 100000000,
        }

        if retry_scale is not None:
            kwargs["scale"] = retry_scale

        fine_scale_values = image.reduceRegion(**kwargs)

        fallback_checks = [
            ee.Algorithms.If(
                ee.Algorithms.IsEqual(feature.get(output_name), None),
                ee.Algorithms.If(
                    ee.Algorithms.IsEqual(fine_scale_values.get(output_name), None),
                    False,
                    True,
                ),
                False,
            )
            for output_name in output_names
        ]

        updates = {
            output_name: ee.Algorithms.If(
                ee.Algorithms.IsEqual(feature.get(output_name), None),
                fine_scale_values.get(output_name),
                feature.get(output_name),
            )
            for output_name in output_names
        }
        updates["used_fine_scale_fallback"] = ee.List(fallback_checks).contains(True)

        return feature.set(updates)

    return summary.map(fill_feature)


def get_first_property(feature, names: list[str]):
    import ee

    value = feature.get(names[0])

    for name in names[1:]:
        value = ee.Algorithms.If(
            ee.Algorithms.IsEqual(value, None),
            feature.get(name),
            value,
        )

    return value


def tiny_watershed_value(feature, threshold_km2: float = TINY_WATERSHED_AREA_KM2):
    import ee

    existing_value = get_first_property(feature, PROPERTY_NAMES["tiny_watershed"])
    geometry_area_km2 = feature.geometry().area(1).divide(1000000)

    return ee.Algorithms.If(
        ee.Algorithms.IsEqual(existing_value, None),
        geometry_area_km2.lte(threshold_km2),
        existing_value,
    )


def polygon_area_km2_value(feature):
    import ee

    existing_value = get_first_property(feature, PROPERTY_NAMES["polygon_area_km2"])
    geometry_area_km2 = feature.geometry().area(1).divide(1000000)

    return ee.Algorithms.If(
        ee.Algorithms.IsEqual(existing_value, None),
        geometry_area_km2,
        existing_value,
    )


def clean_continuous_feature(feature, product_name: str, product: Dict[str, Any], year, month):
    import ee

    reducer_name = product.get("reducer", "mean")
    value = get_first_property(
        feature,
        [
            product.get("output_name", "value"),
            reducer_name,
            "mean",
            "sum",
            "median",
            "min",
            "max",
        ],
    )

    properties = {
        output_name: get_first_property(feature, source_names)
        for output_name, source_names in PROPERTY_NAMES.items()
    }
    properties["polygon_area_km2"] = polygon_area_km2_value(feature)
    properties["tiny_watershed"] = tiny_watershed_value(feature)
    properties.update(
        {
            "driver": product_name,
            "output_name": product.get("output_name"),
            "period": "monthly" if month is not None else "annual",
            "year": year if year is not None else "",
            "month": month if month is not None else "",
            "units": product.get("output_units"),
            "value": value,
            "used_fine_scale_fallback": ee.Algorithms.If(
                ee.Algorithms.IsEqual(feature.get("used_fine_scale_fallback"), None),
                False,
                feature.get("used_fine_scale_fallback"),
            ),
        }
    )

    return ee.Feature(None, properties)


def product_group_members(
    products_config: Dict[str, Any],
    group_name: str,
    product_names: Optional[list[str]] = None,
) -> list[str]:
    products = products_config.get("products") or {}

    if product_names:
        names = product_names
    else:
        names = [
            name
            for name, product in products.items()
            if (product or {}).get("product_group") == group_name
        ]

    missing = [name for name in names if name not in products]
    if missing:
        raise KeyError(f"Products not found in config: {missing}")

    return names


def era5_export_columns(
    products_config: Dict[str, Any],
    product_names: Optional[list[str]] = None,
) -> list[str]:
    selected_products = product_group_members(
        products_config,
        group_name="era5_land",
        product_names=product_names or DEFAULT_ERA5_PRODUCTS,
    )
    value_columns = [
        get_product(products_config, product_name).get("output_name")
        for product_name in selected_products
    ]

    return [
        *ERA5_METADATA_COLUMNS,
        *value_columns,
        "used_fine_scale_fallback",
    ]


def build_multi_product_image(
    product_names: list[str],
    products_config: Dict[str, Any],
    year: Optional[int] = None,
    month: Optional[int] = None,
):
    if not product_names:
        raise ValueError("At least one product is required")

    import ee

    images = []
    for product_name in product_names:
        product = get_product(products_config, product_name)
        images.append(build_continuous_image(product, year=year, month=month))

    return ee.Image.cat(images)


def clean_multi_product_feature(
    feature,
    product_names: list[str],
    products_config: Dict[str, Any],
    year,
    month,
):
    import ee

    properties = {
        output_name: get_first_property(feature, source_names)
        for output_name, source_names in PROPERTY_NAMES.items()
    }
    properties["polygon_area_km2"] = polygon_area_km2_value(feature)
    properties["tiny_watershed"] = tiny_watershed_value(feature)
    properties.update(
        {
            "period": "monthly" if month is not None else "annual",
            "year": year if year is not None else "",
            "month": month if month is not None else "",
            "used_fine_scale_fallback": ee.Algorithms.If(
                ee.Algorithms.IsEqual(feature.get("used_fine_scale_fallback"), None),
                False,
                feature.get("used_fine_scale_fallback"),
            ),
        }
    )

    for product_name in product_names:
        product = get_product(products_config, product_name)
        output_name = product.get("output_name")
        properties[output_name] = feature.get(output_name)

    return ee.Feature(None, properties)


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
    summary = fill_missing_values_at_fine_scale(
        summary=summary,
        image=image,
        output_names=[product.get("output_name", "value")],
        reducer=ee_reducer(product.get("reducer", "mean")),
        scale=scale,
    )

    return summary.map(lambda feature: clean_continuous_feature(feature, product_name, product, year, month))


def extract_era5_land_products(
    products_config: Dict[str, Any],
    watersheds,
    year: int,
    month: Optional[int] = None,
    product_names: Optional[list[str]] = None,
):
    selected_products = product_group_members(
        products_config,
        group_name="era5_land",
        product_names=product_names or DEFAULT_ERA5_PRODUCTS,
    )
    image = build_multi_product_image(selected_products, products_config, year=year, month=month)

    scale_values = [
        get_product(products_config, product_name).get("selected_spatial_resolution_m")
        for product_name in selected_products
    ]
    scale = max(value for value in scale_values if value is not None)

    summary = summarize_image_by_watersheds(
        image=image,
        watersheds=watersheds,
        reducer=ee_reducer("mean"),
        scale=scale,
    )
    output_names = [
        get_product(products_config, product_name).get("output_name")
        for product_name in selected_products
    ]
    summary = fill_missing_values_at_fine_scale(
        summary=summary,
        image=image,
        output_names=output_names,
        reducer=ee_reducer("mean"),
        scale=scale,
    )

    return summary.map(
        lambda feature: clean_multi_product_feature(
            feature,
            selected_products,
            products_config,
            year,
            month,
        )
    )


def extract_era5_land_monthly_year_products(
    products_config: Dict[str, Any],
    watersheds,
    year: int,
    months: Any = "all",
    product_names: Optional[list[str]] = None,
):
    from .runs import month_values

    month_list = month_values(months)
    if not month_list:
        raise ValueError("At least one month is required for a monthly-by-year export")

    monthly_rows = None
    for month in month_list:
        month_rows = extract_era5_land_products(
            products_config=products_config,
            watersheds=watersheds,
            year=year,
            month=month,
            product_names=product_names,
        )
        monthly_rows = month_rows if monthly_rows is None else monthly_rows.merge(month_rows)

    return monthly_rows
