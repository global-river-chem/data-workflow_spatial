"""Plan and safely submit native-scale ERA5-Land watershed summaries.

Every Earth Engine task covers one vector payload and one year or month. The
default is a dry-run annual plan; a submission requires a fresh quota-preflight
receipt whose fingerprint matches the exact tasks about to start.
"""

from __future__ import annotations

import argparse
import calendar
import csv
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import date
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable


try:
    import ee
except ImportError:  # Keep pure planning helpers importable in unit tests.
    ee = None


HELPER_ROOT = Path(__file__).resolve().parents[1]


MAX_EFFECTIVE_PIXELS_PER_TASK = 100_000_000
MAX_TASKS_PER_LAUNCH = 5


DEFAULT_PROJECT = os.getenv("SILICA_GEE_PROJECT", "silica-synthesis")
SOURCE_COLLECTION = "ECMWF/ERA5_LAND/DAILY_AGGR"
NATIVE_SCALE_M = 11_100.0
EXTRACTION_VERSION = "native_polygon_fine_scale_retry_v2"
DEFAULT_PRODUCTS = (
    "precip",
    "temp",
    "evapotrans",
    "potential_evap",
    "snow_cover",
    "snow_water_equiv",
)
METADATA_PROPERTIES = ("site_id", "LTER", "Stream_Name", "Shapefile_Name")
ACTIVE_STATES = {
    "READY",
    "RUNNING",
    "PENDING",
    "CANCEL_REQUESTED",
    "CANCELLING",
}
LABEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_]*$")
ASSET_PART_PATTERN = re.compile(r"[^a-z0-9_-]+")
TRANSIENT_ERROR_MARKERS = (
    "429",
    "500",
    "502",
    "503",
    "504",
    "internal error",
    "temporar",
    "timed out",
    "timeout",
)


# ---- Products and task records ----


@dataclass(frozen=True)
class ProductSpec:
    key: str
    source_band: str
    output_property: str
    daily_scale: float
    daily_offset: float
    monthly_reducer: str
    annual_reducer: str
    units: str


PRODUCTS = {
    "precip": ProductSpec(
        "precip",
        "total_precipitation_sum",
        "precip_mm",
        1_000.0,
        0.0,
        "sum",
        "sum",
        "mm/day, mm/month, or mm/year",
    ),
    "temp": ProductSpec(
        "temp",
        "temperature_2m",
        "temp_degC",
        1.0,
        -273.15,
        "mean",
        "mean",
        "degrees C",
    ),
    "evapotrans": ProductSpec(
        "evapotrans",
        "total_evaporation_sum",
        "evapotrans_mm",
        -1_000.0,
        0.0,
        "sum",
        "sum",
        "positive mm/day, mm/month, or mm/year",
    ),
    "snow_cover": ProductSpec(
        "snow_cover",
        "snow_cover",
        "snow_cover_fraction",
        0.01,
        0.0,
        "mean",
        "max",
        "fraction from 0 to 1",
    ),
    "snow_water_equiv": ProductSpec(
        "snow_water_equiv",
        "snow_depth_water_equivalent",
        "snow_water_equiv_mm",
        1_000.0,
        0.0,
        "mean",
        "max",
        "mm",
    ),
    "potential_evap": ProductSpec(
        "potential_evap",
        "potential_evaporation_sum",
        "potential_evap_mm",
        -1_000.0,
        0.0,
        "sum",
        "sum",
        "positive mm/day, mm/month, or mm/year",
    ),
}


@dataclass(frozen=True)
class Payload:
    name: str
    path: Path
    sites: int
    area_km2: float
    sha256: str


@dataclass(frozen=True)
class TaskPlan:
    description: str
    asset_id: str
    payload: Payload
    year: int
    month: int | None
    days: int
    period: str
    products: tuple[str, ...]
    effective_pixel_band_days: float


# ---- Input parsing ----


def parse_integer_selection(value: str, minimum: int, maximum: int) -> tuple[int, ...]:
    """Parse comma-separated integers and inclusive ``start:end`` ranges."""
    selected: set[int] = set()
    for raw_piece in value.split(","):
        piece = raw_piece.strip()
        if not piece:
            raise ValueError("Selections cannot contain an empty item.")
        if ":" in piece:
            parts = piece.split(":")
            if len(parts) != 2:
                raise ValueError(f"Invalid range: {piece!r}.")
            start, end = (int(item) for item in parts)
            if start > end:
                raise ValueError(f"Range starts after it ends: {piece!r}.")
            selected.update(range(start, end + 1))
        else:
            selected.add(int(piece))
    if not selected or min(selected) < minimum or max(selected) > maximum:
        raise ValueError(f"Selection must stay between {minimum} and {maximum}.")
    return tuple(sorted(selected))


def parse_products(value: str) -> tuple[str, ...]:
    requested = tuple(item.strip() for item in value.split(",") if item.strip())
    if not requested:
        raise ValueError("At least one ERA5-Land product is required.")
    unknown = sorted(set(requested) - set(PRODUCTS))
    if unknown:
        raise ValueError(
            "Unknown products: " + ", ".join(unknown) + ". Available: "
            + ", ".join(PRODUCTS)
        )
    if len(set(requested)) != len(requested):
        raise ValueError("Each product may be listed only once.")
    return requested


def read_expected_site_ids(path: Path) -> tuple[int, tuple[str, ...]]:
    """Read current site IDs from a CSV or TSV, retaining alias row counts."""
    expected_path = path.resolve()
    if not expected_path.is_file():
        raise ValueError(f"Expected site-ID file does not exist: {expected_path}")
    delimiter = "\t" if expected_path.suffix.lower() == ".tsv" else ","
    with expected_path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        if not reader.fieldnames or "site_id" not in reader.fieldnames:
            raise ValueError("Expected site-ID file must contain a site_id column.")
        values = [str(row["site_id"]).strip() for row in reader]
    if not values or any(not value for value in values):
        raise ValueError("Expected site-ID file is empty or contains blank IDs.")
    return len(values), tuple(sorted(set(values)))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@lru_cache(maxsize=None)
def read_geojson(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("type") != "FeatureCollection":
        raise ValueError(f"Payload is not a GeoJSON FeatureCollection: {path}")
    features = payload.get("features")
    if not isinstance(features, list) or not features:
        raise ValueError(f"Payload has no features: {path}")
    for index, feature in enumerate(features, start=1):
        properties = feature.get("properties") or {}
        missing = [name for name in METADATA_PROPERTIES if name not in properties]
        if missing:
            raise ValueError(
                f"Payload {path}, feature {index}, lacks: {', '.join(missing)}"
            )
        if not feature.get("geometry"):
            raise ValueError(f"Payload {path}, feature {index}, has no geometry.")
    return payload


def load_payload_manifest(path: Path) -> list[Payload]:
    manifest_path = path.resolve()
    if not manifest_path.is_file():
        raise ValueError(f"Payload manifest does not exist: {manifest_path}")
    with manifest_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required = {"payload", "path", "sites", "polygon_area_km2_sum"}
    if not rows or not required.issubset(rows[0]):
        raise ValueError(
            f"Manifest must contain: {', '.join(sorted(required))}."
        )
    payloads: list[Payload] = []
    all_site_ids: set[str] = set()
    for row in rows:
        payload_path = Path(str(row["path"]))
        if not payload_path.is_absolute():
            payload_path = manifest_path.parent / payload_path
        payload_path = payload_path.resolve()
        if not payload_path.is_file():
            raise ValueError(f"Payload does not exist: {payload_path}")
        geojson = read_geojson(payload_path)
        site_ids = [
            str(feature["properties"]["site_id"]).strip()
            for feature in geojson["features"]
        ]
        if any(not site_id for site_id in site_ids) or len(set(site_ids)) != len(
            site_ids
        ):
            raise ValueError(
                f"Payload has blank or duplicate site_id values: {payload_path}"
            )
        repeated = sorted(set(site_ids) & all_site_ids)
        if repeated:
            raise ValueError(
                "Sites occur in multiple payloads; first duplicate is " + repeated[0]
            )
        all_site_ids.update(site_ids)
        declared_sites = int(row["sites"])
        if declared_sites != len(site_ids):
            raise ValueError(
                f"Manifest says {declared_sites} sites for {payload_path}; "
                f"GeoJSON contains {len(site_ids)}."
            )
        area_km2 = float(row["polygon_area_km2_sum"])
        if area_km2 <= 0:
            raise ValueError(f"Payload area must be positive: {payload_path}")
        payloads.append(
            Payload(
                name=str(row["payload"]),
                path=payload_path,
                sites=declared_sites,
                area_km2=area_km2,
                sha256=file_sha256(payload_path),
            )
        )
    names = [payload.name for payload in payloads]
    if len(set(names)) != len(names):
        raise ValueError("Payload names must be distinct.")
    return payloads


def payload_site_ids(payloads: Iterable[Payload]) -> tuple[str, ...]:
    return tuple(
        sorted(
            str(feature["properties"]["site_id"]).strip()
            for payload in payloads
            for feature in read_geojson(payload.path)["features"]
        )
    )


def validate_site_coverage(
    actual_ids: Iterable[str],
    *,
    expected_count: int | None,
    expected_ids: Iterable[str] | None,
) -> tuple[str, ...]:
    actual = tuple(actual_ids)
    if not actual or any(not value for value in actual):
        raise ValueError("ERA5 payloads contain no site IDs or a blank site ID.")
    if len(actual) != len(set(actual)):
        raise ValueError("ERA5 payloads contain duplicate site IDs.")
    if expected_count is not None and len(actual) != expected_count:
        raise RuntimeError(
            f"ERA5 payloads contain {len(actual)} unique sites; expected "
            f"{expected_count}."
        )
    if expected_ids is not None:
        expected = set(expected_ids)
        actual_set = set(actual)
        missing = sorted(expected - actual_set)
        unexpected = sorted(actual_set - expected)
        if missing or unexpected:
            raise RuntimeError(
                "ERA5 payload site IDs do not match the current accepted set. "
                f"Missing: {missing[:10]}; unexpected: {unexpected[:10]}."
            )
    return tuple(sorted(actual))


def geojson_feature_collection(payload: Payload) -> Any:
    if ee is None:
        raise RuntimeError("The Earth Engine Python API is required.")
    return ee.FeatureCollection(read_geojson(payload.path)["features"])


def is_transient_earth_engine_error(message: str) -> bool:
    normalized = message.strip().lower()
    return normalized == "ok" or any(
        marker in normalized for marker in TRANSIENT_ERROR_MARKERS
    )


def get_info_with_retries(value: Any, label: str, attempts: int = 4) -> Any:
    for attempt in range(1, attempts + 1):
        try:
            return value.getInfo()
        except ee.EEException as exc:
            if attempt == attempts or not is_transient_earth_engine_error(str(exc)):
                raise
            delay = min(30, 5 * 2 ** (attempt - 1))
            print(
                f"Transient Earth Engine error while verifying {label}; "
                f"retrying in {delay} seconds.",
                flush=True,
            )
            time.sleep(delay)
    raise RuntimeError(f"Earth Engine verification did not return for {label}.")


def verify_payload_geometry(payload: Payload) -> Payload:
    """Replace manifest estimates with Earth Engine's geodesic geometry area."""
    collection = geojson_feature_collection(payload)
    verified = collection.map(
        lambda feature: feature.set(
            "_safety_area_km2",
            feature.geometry().area(maxError=1).divide(1_000_000),
        )
    )
    result = get_info_with_retries(
        ee.Dictionary(
            {
                "sites": verified.size(),
                "area_km2": verified.aggregate_sum("_safety_area_km2"),
            }
        ),
        payload.name,
    )
    actual_sites = int(result["sites"])
    actual_area = float(result["area_km2"])
    if actual_sites != payload.sites:
        raise RuntimeError(
            f"Earth Engine read {actual_sites} sites from {payload.path}; "
            f"expected {payload.sites}."
        )
    relative_difference = abs(actual_area - payload.area_km2) / max(
        actual_area, 1e-12
    )
    if relative_difference > 0.01:
        raise RuntimeError(
            f"Manifest area for {payload.name} differs from Earth Engine by "
            f"{100 * relative_difference:.2f}%; rebuild the payload manifest."
        )
    return replace(payload, area_km2=actual_area)


def safe_asset_part(value: str) -> str:
    cleaned = ASSET_PART_PATTERN.sub("_", value.lower()).strip("_-")
    if not cleaned:
        raise ValueError(f"Cannot turn {value!r} into an Earth Engine asset name.")
    return cleaned


# ---- Task planning ----


def plan_tasks(
    *,
    payloads: Iterable[Payload],
    years: Iterable[int],
    months: Iterable[int],
    period: str,
    products: tuple[str, ...],
    run_label: str,
    output_folder: str,
) -> list[TaskPlan]:
    if period not in {"annual", "daily", "monthly"}:
        raise ValueError("Period must be annual, daily, or monthly.")
    short_period = {"annual": "a", "daily": "d", "monthly": "m"}[period]
    prefix = f"era5{short_period}{len(products)}_"
    plans: list[TaskPlan] = []
    for payload in payloads:
        payload_name = safe_asset_part(payload.name)
        for year in years:
            periods = ((None, 366 if calendar.isleap(year) else 365),)
            if period != "annual":
                periods = tuple(
                    (month, calendar.monthrange(year, month)[1])
                    for month in months
                )
            for month, days in periods:
                time_label = str(year) if month is None else f"{year}{month:02d}"
                description = f"{prefix}{run_label}_{payload_name}_{time_label}"
                if len(description) > 100:
                    raise ValueError(
                        f"Earth Engine task description exceeds 100 characters: {description}"
                    )
                estimated_work = (
                    payload.area_km2
                    * 1_000_000
                    / (NATIVE_SCALE_M * NATIVE_SCALE_M)
                    * days
                    * len(products)
                )
                plans.append(
                    TaskPlan(
                        description=description,
                        asset_id=f"{output_folder.rstrip('/')}/{description}",
                        payload=payload,
                        year=year,
                        month=month,
                        days=days,
                        period=period,
                        products=products,
                        effective_pixel_band_days=estimated_work,
                    )
                )
    # Finish each calendar month across every payload before moving forward.
    # Within a month, run the largest payload first as the smoke test.
    return sorted(
        plans,
        key=lambda item: (
            item.year,
            item.month or 0,
            -item.effective_pixel_band_days,
            item.description,
        ),
    )


def workload_fingerprint(plans: Iterable[TaskPlan]) -> str:
    exact = [
        {
            "description": plan.description,
            "asset_id": plan.asset_id,
            "payload_sha256": plan.payload.sha256,
            "payload_sites": plan.payload.sites,
            "year": plan.year,
            "month": plan.month,
            "days": plan.days,
            "period": plan.period,
            "products": list(plan.products),
            "scale_m": NATIVE_SCALE_M,
            "extraction_version": EXTRACTION_VERSION,
        }
        for plan in plans
    ]
    canonical = json.dumps(exact, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def attach_verified_payload(plan: TaskPlan, payload: Payload) -> TaskPlan:
    if payload.name != plan.payload.name:
        raise ValueError(
            f"Cannot attach verified payload {payload.name} to {plan.payload.name}."
        )
    effective_work = (
        payload.area_km2
        * 1_000_000
        / (NATIVE_SCALE_M * NATIVE_SCALE_M)
        * plan.days
        * len(plan.products)
    )
    return replace(
        plan,
        payload=payload,
        effective_pixel_band_days=effective_work,
    )


# ---- Earth Engine exports ----


def operation_list() -> list[dict[str, Any]]:
    response = ee.data.listOperations()
    if isinstance(response, dict):
        return list(response.get("operations", []))
    return list(response)


def active_descriptions() -> set[str]:
    return {
        str(operation.get("metadata", {}).get("description", ""))
        for operation in operation_list()
        if str(operation.get("metadata", {}).get("state", "")).upper()
        in ACTIVE_STATES
    }


def child_asset_ids(parent: str) -> set[str]:
    found: set[str] = set()
    request: dict[str, Any] = {"parent": parent, "pageSize": 1_000}
    while True:
        response = ee.data.listAssets(request)
        found.update(str(asset["name"]) for asset in response.get("assets", []))
        token = response.get("nextPageToken")
        if not token:
            return found
        request["pageToken"] = token


def transformed_daily_collection(
    specs: tuple[ProductSpec, ...], start: Any, end: Any
) -> Any:
    source = ee.ImageCollection(SOURCE_COLLECTION).filterDate(start, end)

    def transform(image: Any) -> Any:
        bands = [
            image.select(spec.source_band)
            .multiply(spec.daily_scale)
            .add(spec.daily_offset)
            .rename(spec.output_property)
            for spec in specs
        ]
        return ee.Image.cat(bands).copyProperties(image, ["system:time_start"])

    return source.map(transform)


def first_property(feature: Any, names: tuple[str, ...]) -> Any:
    value = feature.get(names[0])
    for name in names[1:]:
        value = ee.Algorithms.If(
            ee.Algorithms.IsEqual(value, None),
            feature.get(name),
            value,
        )
    return value


def reduce_image_for_feature(
    image: Any,
    feature: Any,
    output_properties: tuple[str, ...],
) -> Any:
    projection = image.select(0).projection()
    geometry = feature.geometry()
    centroid = geometry.centroid(maxError=1)
    polygon_values = image.reduceRegion(
        reducer=ee.Reducer.mean(),
        geometry=geometry,
        scale=NATIVE_SCALE_M,
        crs=projection,
        bestEffort=False,
        maxPixels=1_000_000,
        tileScale=2,
    )
    fine_scale_values = image.reduceRegion(
        reducer=ee.Reducer.mean(),
        geometry=geometry,
        scale=NATIVE_SCALE_M / 10,
        crs=projection,
        bestEffort=False,
        maxPixels=100_000_000,
        tileScale=4,
    )
    fallback_used = [
        ee.Algorithms.If(
            ee.Algorithms.IsEqual(polygon_values.get(name), None),
            ee.Algorithms.If(
                ee.Algorithms.IsEqual(fine_scale_values.get(name), None),
                False,
                True,
            ),
            False,
        )
        for name in output_properties
    ]
    values = {
        name: ee.Algorithms.If(
            ee.Algorithms.IsEqual(polygon_values.get(name), None),
            fine_scale_values.get(name),
            polygon_values.get(name),
        )
        for name in output_properties
    }
    values["used_fine_scale_fallback"] = ee.Algorithms.If(
        ee.List(fallback_used).contains(True), 1, 0
    )
    return ee.Feature(
        centroid,
        feature.toDictionary(),
    ).set(values)


def build_daily_export(plan: TaskPlan, watersheds: Any) -> tuple[Any, list[str]]:
    specs = tuple(PRODUCTS[key] for key in plan.products)
    outputs = tuple(spec.output_property for spec in specs)
    start = ee.Date.fromYMD(plan.year, plan.month, 1)
    end = start.advance(1, "month")
    daily = transformed_daily_collection(specs, start, end)
    offsets = ee.List.sequence(0, plan.days - 1)

    def summarize_day(offset: Any) -> Any:
        day_start = start.advance(ee.Number(offset), "day")
        image = ee.Image(
            daily.filterDate(day_start, day_start.advance(1, "day")).first()
        )

        def summarize_feature(feature: Any) -> Any:
            reduced = reduce_image_for_feature(image, feature, outputs)
            return reduced.set(
                {
                    "date": day_start.format("YYYY-MM-dd"),
                    "year": plan.year,
                    "month": plan.month,
                    "day": day_start.get("day"),
                    "day_of_year": day_start.getRelative("day", "year").add(1),
                    "source_image_count": 1,
                }
            )

        return watersheds.map(summarize_feature)

    table = ee.FeatureCollection(offsets.map(summarize_day)).flatten()
    selectors = [
        *METADATA_PROPERTIES,
        "date",
        "year",
        "month",
        "day",
        "day_of_year",
        *outputs,
        "used_fine_scale_fallback",
        "source_image_count",
    ]
    return table.select(selectors), selectors


def build_monthly_export(plan: TaskPlan, watersheds: Any) -> tuple[Any, list[str]]:
    specs = tuple(PRODUCTS[key] for key in plan.products)
    outputs = tuple(spec.output_property for spec in specs)
    start = ee.Date.fromYMD(plan.year, plan.month, 1)
    end = start.advance(1, "month")
    daily = transformed_daily_collection(specs, start, end)
    aggregated = []
    for spec in specs:
        selected = daily.select(spec.output_property)
        image = selected.sum() if spec.monthly_reducer == "sum" else selected.mean()
        aggregated.append(image.rename(spec.output_property))
    monthly_image = ee.Image.cat(aggregated)

    def summarize_feature(feature: Any) -> Any:
        reduced = reduce_image_for_feature(monthly_image, feature, outputs)
        return reduced.set(
            {
                "year": plan.year,
                "month": plan.month,
                "source_image_count": plan.days,
            }
        )

    table = watersheds.map(summarize_feature)
    selectors = [
        *METADATA_PROPERTIES,
        "year",
        "month",
        *outputs,
        "used_fine_scale_fallback",
        "source_image_count",
    ]
    return table.select(selectors), selectors


ANNUAL_METADATA = {
    "site_id": ("site_id",),
    "lter": ("lter", "LTER"),
    "shapefile_name": ("shapefile_name", "Shapefile_Name"),
    "stream_name": ("stream_name", "Stream_Name"),
    "Q_file_name": ("Q_file_name", "Discharge_File_Name"),
    "run_group": ("run_group",),
    "hydrosheds_used": ("hydrosheds_used",),
    "hydrosheds_id": ("hydrosheds_id",),
    "expected_area_km2": ("expected_area_km2",),
    "drainage_area_source": (
        "drainage_area_source",
        "drain_src",
        "drn_src",
    ),
    "polygon_area_km2": ("polygon_area_km2",),
    "tiny_watershed": ("tiny_watershed", "tiny_ws"),
    "source_type": ("source_type",),
}


def aggregate_images(
    daily: Any,
    specs: tuple[ProductSpec, ...],
    reducer_name: str,
) -> Any:
    images = []
    for spec in specs:
        selected = daily.select(spec.output_property)
        reducer = getattr(spec, reducer_name)
        if reducer == "sum":
            image = selected.sum()
        elif reducer == "mean":
            image = selected.mean()
        elif reducer == "max":
            image = selected.max()
        else:
            raise ValueError(f"Unsupported ERA5-Land reducer: {reducer}")
        images.append(image.rename(spec.output_property))
    return ee.Image.cat(images)


def build_annual_export(plan: TaskPlan, watersheds: Any) -> tuple[Any, list[str]]:
    specs = tuple(PRODUCTS[key] for key in plan.products)
    outputs = tuple(spec.output_property for spec in specs)
    start = ee.Date.fromYMD(plan.year, 1, 1)
    end = start.advance(1, "year")
    daily = transformed_daily_collection(specs, start, end)
    annual_image = aggregate_images(daily, specs, "annual_reducer")

    def summarize_feature(feature: Any) -> Any:
        reduced = reduce_image_for_feature(annual_image, feature, outputs)
        properties = {
            output: first_property(reduced, source_names)
            for output, source_names in ANNUAL_METADATA.items()
        }
        properties.update(
            {
                "period": "annual",
                "year": plan.year,
                "month": "",
                "used_fine_scale_fallback": reduced.get(
                    "used_fine_scale_fallback"
                ),
                "source_image_count": plan.days,
            }
        )
        properties.update({name: reduced.get(name) for name in outputs})
        return ee.Feature(reduced.geometry(), properties)

    table = watersheds.map(summarize_feature)
    selectors = [
        *ANNUAL_METADATA,
        "period",
        "year",
        "month",
        *outputs,
        "used_fine_scale_fallback",
        "source_image_count",
    ]
    return table.select(selectors), selectors


def verify_source_days(plan: TaskPlan) -> None:
    if plan.period == "annual":
        start = date(plan.year, 1, 1).isoformat()
        end = date(plan.year + 1, 1, 1).isoformat()
    elif plan.month is None:
        raise ValueError("Monthly and daily plans require a month.")
    elif plan.month == 12:
        start = date(plan.year, plan.month, 1).isoformat()
        end = date(plan.year + 1, 1, 1).isoformat()
    else:
        start = date(plan.year, plan.month, 1).isoformat()
        end = date(plan.year, plan.month + 1, 1).isoformat()
    actual = int(
        ee.ImageCollection(SOURCE_COLLECTION).filterDate(start, end).size().getInfo()
    )
    if actual != plan.days:
        raise RuntimeError(
            f"{plan.description} expected {plan.days} daily source images but "
            f"found {actual}; no task was started."
        )


def make_export_task(plan: TaskPlan) -> Any:
    watersheds = geojson_feature_collection(plan.payload)
    if plan.period == "daily":
        table, _ = build_daily_export(plan, watersheds)
    elif plan.period == "monthly":
        table, _ = build_monthly_export(plan, watersheds)
    else:
        table, _ = build_annual_export(plan, watersheds)
    return ee.batch.Export.table.toAsset(
        collection=table,
        description=plan.description,
        assetId=plan.asset_id,
    )


def launch_site_count(plans: Iterable[TaskPlan]) -> int:
    unique = {plan.payload.name: plan.payload.sites for plan in plans}
    return sum(unique.values())


# ---- Submission records ----


def print_plan(plans: list[TaskPlan], missing_count: int) -> None:
    print(
        f"Missing tasks: {missing_count}; tasks eligible in this launch: {len(plans)}."
    )
    for plan in plans:
        print(
            f"  {plan.description}: {plan.payload.sites} sites, "
            f"{plan.payload.area_km2:,.1f} km2, "
            f"{plan.effective_pixel_band_days:,.0f} pixel-band-days"
        )


def preflight_command(
    *,
    project: str,
    plans: list[TaskPlan],
    workflow: str,
    description_prefix: str,
    receipt: Path,
) -> str:
    fingerprint = workload_fingerprint(plans)
    maximum_area = max(plan.payload.area_km2 for plan in plans)
    maximum_days = max(plan.days for plan in plans)
    command = [
        "Rscript",
        str(HELPER_ROOT / "gee_quota_preflight.R"),
        "--project",
        project,
        "--workflow",
        workflow,
        "--description-prefix",
        description_prefix,
        "--proposed-task-count",
        str(len(plans)),
        "--site-count",
        str(launch_site_count(plans)),
        "--max-task-area-km2",
        f"{maximum_area:.6f}",
        "--scale-m",
        str(NATIVE_SCALE_M),
        "--time-slices-per-task",
        str(maximum_days),
        "--bands-per-slice",
        str(len(plans[0].products)),
        "--watchdog-cancel-eecu-hours",
        "0.01",
        "--workload-fingerprint",
        fingerprint,
        "--receipt",
        str(receipt),
    ]
    return " ".join(shlex.quote(part) for part in command)


def consume_preflight_receipt(
    receipt: Path,
    *,
    project: str,
    workflow: str,
    description_prefix: str,
    proposed_task_count: int,
    site_count: int,
    max_task_area_km2: float,
    scale_m: float,
    time_slices_per_task: int,
    bands_per_slice: int,
    workload_fingerprint: str,
) -> None:
    command = [
        "Rscript",
        str(HELPER_ROOT / "gee_quota_preflight.R"),
        "--consume",
        "--receipt",
        str(receipt),
        "--project",
        project,
        "--workflow",
        workflow,
        "--description-prefix",
        description_prefix,
        "--proposed-task-count",
        str(proposed_task_count),
        "--site-count",
        str(site_count),
        "--max-task-area-km2",
        f"{max_task_area_km2:.6f}",
        "--scale-m",
        str(scale_m),
        "--time-slices-per-task",
        str(time_slices_per_task),
        "--bands-per-slice",
        str(bands_per_slice),
        "--workload-fingerprint",
        workload_fingerprint,
    ]
    subprocess.run(command, check=True)


def write_task_log(path: Path, plans: list[TaskPlan], task_ids: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    records = [
        {
            "task_id": task_id,
            "description": plan.description,
            "asset_id": plan.asset_id,
            "payload": plan.payload.name,
            "payload_sha256": plan.payload.sha256,
            "year": plan.year,
            "month": plan.month,
            "period": plan.period,
            "products": list(plan.products),
            "effective_pixel_band_days": round(plan.effective_pixel_band_days),
        }
        for plan, task_id in zip(plans, task_ids, strict=True)
    ]
    path.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")


# ---- Command line ----


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-manifest", type=Path, required=True)
    parser.add_argument("--output-folder", required=True)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument(
        "--period",
        choices=("annual", "daily", "monthly"),
        default="annual",
    )
    parser.add_argument("--years", default="2000:2025")
    parser.add_argument("--months", default="1:12")
    parser.add_argument("--products", default=",".join(DEFAULT_PRODUCTS))
    parser.add_argument("--expected-site-count", type=int)
    parser.add_argument(
        "--expected-site-ids",
        type=Path,
        help=(
            "CSV or TSV containing the current accepted site_id set. Duplicate "
            "rows are allowed for site aliases, but every unique ID must match."
        ),
    )
    parser.add_argument(
        "--max-new-tasks",
        type=int,
        default=1,
        help="Maximum tasks to start; the hard limit is five and the default is one.",
    )
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--preflight-receipt", type=Path)
    parser.add_argument(
        "--receipt-output",
        type=Path,
        default=Path("generated_outputs/gee_preflight/era5_land.json"),
        help="Where the printed preflight command should write its receipt.",
    )
    parser.add_argument("--task-log", type=Path)
    args = parser.parse_args()
    if not LABEL_PATTERN.fullmatch(args.run_label):
        parser.error("--run-label may contain lowercase letters, numbers, and _.")
    try:
        args.years = parse_integer_selection(args.years, 1950, 2100)
        args.months = parse_integer_selection(args.months, 1, 12)
        args.products = parse_products(args.products)
    except ValueError as exc:
        parser.error(str(exc))
    if args.max_new_tasks < 1 or args.max_new_tasks > MAX_TASKS_PER_LAUNCH:
        parser.error(
            f"--max-new-tasks must be between 1 and {MAX_TASKS_PER_LAUNCH}."
        )
    if args.expected_site_count is not None and args.expected_site_count < 1:
        parser.error("--expected-site-count must be positive.")
    if args.submit and args.preflight_receipt is None:
        parser.error("--submit requires --preflight-receipt.")
    return args


def main() -> int:
    args = parse_args()
    if ee is None:
        raise RuntimeError("Install and authenticate the Earth Engine Python API.")
    ee.Initialize(project=args.project)

    folder = ee.data.getAsset(args.output_folder.rstrip("/"))
    if str(folder.get("type", "")).upper() != "FOLDER":
        raise RuntimeError(
            "--output-folder must be an existing Earth Engine folder asset."
        )

    payloads = load_payload_manifest(args.payload_manifest)
    expected_alias_rows = None
    expected_ids = None
    if args.expected_site_ids is not None:
        expected_alias_rows, expected_ids = read_expected_site_ids(
            args.expected_site_ids
        )
    site_ids = validate_site_coverage(
        payload_site_ids(payloads),
        expected_count=args.expected_site_count,
        expected_ids=expected_ids,
    )
    print(
        f"Verified ERA5 payload coverage: {len(site_ids)} unique site IDs"
        + (
            f" covering {expected_alias_rows} current site/alias rows."
            if expected_alias_rows is not None
            else "."
        )
    )
    all_plans = plan_tasks(
        payloads=payloads,
        years=args.years,
        months=args.months,
        period=args.period,
        products=args.products,
        run_label=args.run_label,
        output_folder=args.output_folder,
    )
    existing_assets = child_asset_ids(args.output_folder.rstrip("/"))
    active = active_descriptions()
    missing = [
        plan
        for plan in all_plans
        if plan.asset_id not in existing_assets and plan.description not in active
    ]
    launch_plan = missing[: args.max_new_tasks]
    if not launch_plan:
        print("No missing tasks remain; nothing was submitted.")
        return 0

    launch_payloads = {
        plan.payload.name: plan.payload for plan in launch_plan
    }
    with ThreadPoolExecutor(max_workers=min(5, len(launch_payloads))) as executor:
        verified = executor.map(
            verify_payload_geometry,
            launch_payloads.values(),
        )
        verified_payloads = {payload.name: payload for payload in verified}
    launch_plan = [
        attach_verified_payload(plan, verified_payloads[plan.payload.name])
        for plan in launch_plan
    ]
    print_plan(launch_plan, len(missing))

    unsafe = [
        plan
        for plan in launch_plan
        if plan.effective_pixel_band_days > MAX_EFFECTIVE_PIXELS_PER_TASK
    ]
    if unsafe:
        worst = unsafe[0]
        raise RuntimeError(
            f"{worst.description} estimates {worst.effective_pixel_band_days:,.0f} "
            f"pixel-band-days, above the hard {MAX_EFFECTIVE_PIXELS_PER_TASK:,} "
            "limit. Rebuild the vector payloads with workload balancing."
        )

    workflow = f"era5_land_{args.period}"
    period_code = {"annual": "a", "daily": "d", "monthly": "m"}[args.period]
    description_prefix = f"era5{period_code}{len(args.products)}_"
    print("Required preflight command:")
    print(
        "  "
        + preflight_command(
            project=args.project,
            plans=launch_plan,
            workflow=workflow,
            description_prefix=description_prefix,
            receipt=args.receipt_output,
        )
    )
    if not args.submit:
        print("Dry run complete. No Earth Engine task was submitted.")
        return 0

    fingerprint = workload_fingerprint(launch_plan)
    consume_preflight_receipt(
        args.preflight_receipt,
        project=args.project,
        workflow=workflow,
        description_prefix=description_prefix,
        proposed_task_count=len(launch_plan),
        site_count=launch_site_count(launch_plan),
        max_task_area_km2=max(plan.payload.area_km2 for plan in launch_plan),
        scale_m=NATIVE_SCALE_M,
        time_slices_per_task=max(plan.days for plan in launch_plan),
        bands_per_slice=len(args.products),
        workload_fingerprint=fingerprint,
    )

    tasks = []
    verified_windows: set[tuple[str, int, int | None]] = set()
    for plan in launch_plan:
        window = (plan.period, plan.year, plan.month)
        if window not in verified_windows:
            verify_source_days(plan)
            verified_windows.add(window)
        tasks.append(make_export_task(plan))
    task_ids: list[str] = []
    for index, task in enumerate(tasks, start=1):
        task.start()
        task_ids.append(str(task.id))
        print(f"Started {task.id}", flush=True)
        if args.task_log is not None:
            write_task_log(args.task_log, launch_plan[:index], task_ids)
    if args.task_log is not None and task_ids:
        print(f"Task log: {args.task_log}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"SAFE ERA5-LAND ERROR: {exc}", file=sys.stderr)
        raise
