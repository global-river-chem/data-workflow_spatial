"""Safely export all 26 GLC-FCS30D land-class dates by watershed.

Each task covers one watershed and all configured GLC-FCS30D dates. Small
watersheds use an exact native-30 m pixel-area census. Large watersheds use a
deterministic fixed-size point sample of the same 30 m product, which prevents
task cost from growing with watershed area. Submission is fail-closed behind
an exact, one-use Earth Engine quota-preflight receipt.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, replace
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable


try:
    import ee
except ImportError:  # Keep pure planning functions importable in tests.
    ee = None


HELPER_ROOT = Path(__file__).resolve().parents[1]


MAX_EFFECTIVE_PIXELS_PER_TASK = 100_000_000
MAX_TASKS_PER_LAUNCH = 5


DEFAULT_PROJECT = os.getenv("SILICA_GEE_PROJECT", "silica-synthesis")
FIVE_YEAR_COLLECTION = (
    "projects/sat-io/open-datasets/GLC-FCS30D/five-years-map"
)
ANNUAL_COLLECTION = "projects/sat-io/open-datasets/GLC-FCS30D/annual"
YEARS = (1985, 1990, 1995, *range(2000, 2023))
GLC_CLASSES = (
    0,
    10,
    11,
    12,
    20,
    50,
    51,
    52,
    61,
    62,
    71,
    72,
    81,
    82,
    91,
    92,
    120,
    121,
    122,
    130,
    140,
    150,
    152,
    153,
    181,
    182,
    183,
    184,
    185,
    186,
    187,
    190,
    200,
    201,
    202,
    210,
    220,
)
METADATA_PROPERTIES = ("site_id", "LTER", "Stream_Name", "Shapefile_Name")
NATIVE_SCALE_M = 30.0
DEFAULT_SAMPLE_POINTS = 100_000
# In auto mode exact work is used only when it is no larger than sampling.
# Consequently every default task is bounded to the same 2.6 million
# pixel/point x date observations.
DEFAULT_EXACT_MAX_WORK = DEFAULT_SAMPLE_POINTS * len(YEARS)
SAMPLER_VERSION = "local_equal_area_points_v1"
SAMPLED_REDUCER_VERSION = "multipoint_frequency_histogram_v2"
DEFAULT_RUN_ROOT = Path("generated_outputs/gee/glc-fcs30d-safe")
ACTIVE_STATES = {
    "READY",
    "RUNNING",
    "PENDING",
    "CANCEL_REQUESTED",
    "CANCELLING",
}
LABEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_]*$")
ASSET_PART_PATTERN = re.compile(r"[^a-z0-9_-]+")
UNSAFE_LEGACY_PREFIXES = ("glc_followup_other_targets_",)


# ---- Site and task records ----


@dataclass(frozen=True)
class Site:
    site_id: str
    area_km2: float
    feature: dict[str, Any]
    feature_sha256: str


@dataclass(frozen=True)
class LocalPointSample:
    site_id: str
    path: Path
    file_sha256: str
    sample_n: int
    sampling_seed: int
    sampling_crs: str
    polygon_area_km2: float
    source_geometry_sha256: str
    bounds: tuple[float, float, float, float]


@dataclass(frozen=True)
class TaskPlan:
    description: str
    asset_id: str
    site: Site
    method: str
    sample_points: int
    sampling_seed: int
    native_pixel_estimate: float
    effective_pixel_band_time: float
    local_point_sample: LocalPointSample | None = None


# ---- Input parsing ----


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


@lru_cache(maxsize=None)
def read_geojson(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("type") != "FeatureCollection":
        raise ValueError(f"Not a GeoJSON FeatureCollection: {path}")
    features = value.get("features")
    if not isinstance(features, list) or not features:
        raise ValueError(f"GeoJSON contains no features: {path}")
    return value


def load_sites(manifest_path: Path) -> list[Site]:
    manifest = manifest_path.resolve()
    if not manifest.is_file():
        raise ValueError(f"Payload manifest does not exist: {manifest}")
    with manifest.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required = {"path", "sites"}
    if not rows or not required.issubset(rows[0]):
        raise ValueError("Payload manifest must contain path and sites columns.")

    sites: list[Site] = []
    seen: set[str] = set()
    for row in rows:
        payload_path = Path(str(row["path"]))
        if not payload_path.is_absolute():
            payload_path = manifest.parent / payload_path
        payload_path = payload_path.resolve()
        if not payload_path.is_file():
            raise ValueError(f"Payload does not exist: {payload_path}")
        features = read_geojson(payload_path)["features"]
        if len(features) != int(row["sites"]):
            raise ValueError(
                f"Manifest says {row['sites']} sites for {payload_path}; "
                f"GeoJSON contains {len(features)}."
            )
        for index, feature in enumerate(features, start=1):
            properties = feature.get("properties") or {}
            missing = [name for name in METADATA_PROPERTIES if name not in properties]
            if missing:
                raise ValueError(
                    f"{payload_path}, feature {index}, lacks: {', '.join(missing)}"
                )
            site_id = str(properties["site_id"]).strip()
            if not site_id:
                raise ValueError(f"{payload_path}, feature {index}, has blank site_id.")
            if site_id in seen:
                raise ValueError(f"site_id occurs in multiple payloads: {site_id}")
            seen.add(site_id)
            if not feature.get("geometry"):
                raise ValueError(f"{payload_path}, feature {index}, has no geometry.")
            try:
                area_km2 = float(properties["polygon_area_km2"])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(
                    f"{payload_path}, feature {index}, needs polygon_area_km2."
                ) from exc
            if not math.isfinite(area_km2) or area_km2 <= 0:
                raise ValueError(f"Invalid polygon_area_km2 for {site_id}: {area_km2}")
            sites.append(
                Site(
                    site_id=site_id,
                    area_km2=area_km2,
                    feature=feature,
                    feature_sha256=canonical_sha256(feature),
                )
            )
    if not sites:
        raise ValueError("Payload manifest contains no sites.")
    return sites


@lru_cache(maxsize=None)
def read_local_point_file(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schema_version") != 1:
        raise ValueError(f"Unsupported local-point schema in {path}.")
    if value.get("generator") != SAMPLER_VERSION:
        raise ValueError(f"Unexpected local-point generator in {path}.")
    return value


def load_local_point_samples(manifest_path: Path) -> dict[str, LocalPointSample]:
    manifest = manifest_path.resolve()
    if not manifest.is_file():
        raise ValueError(f"Local-point manifest does not exist: {manifest}")
    with manifest.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required = {
        "site_id",
        "path",
        "sample_n",
        "sampling_seed",
        "sampling_crs",
        "polygon_area_km2",
        "source_geometry_sha256",
        "file_sha256",
    }
    if not rows or not required.issubset(rows[0]):
        raise ValueError(
            "Local-point manifest lacks required columns: "
            + ", ".join(sorted(required))
        )

    samples: dict[str, LocalPointSample] = {}
    for row in rows:
        site_id = str(row["site_id"]).strip()
        if not site_id or site_id in samples:
            raise ValueError(f"Invalid or duplicate local-point site_id: {site_id}")
        path = Path(str(row["path"]))
        if not path.is_absolute():
            path = manifest.parent / path
        path = path.resolve()
        if not path.is_file():
            raise ValueError(f"Local-point file does not exist: {path}")
        actual_sha256 = hashlib.sha256(path.read_bytes()).hexdigest()
        expected_sha256 = str(row["file_sha256"]).strip().lower()
        if actual_sha256 != expected_sha256:
            raise ValueError(f"Local-point file checksum mismatch: {path}")

        value = read_local_point_file(path)
        coordinates = value.get("coordinates")
        if not isinstance(coordinates, list) or not coordinates:
            raise ValueError(f"Local-point file has no coordinates: {path}")
        parsed_coordinates: list[tuple[float, float]] = []
        for index, coordinate in enumerate(coordinates, start=1):
            if not isinstance(coordinate, list) or len(coordinate) != 2:
                raise ValueError(f"Invalid coordinate {index} in {path}")
            try:
                longitude, latitude = map(float, coordinate)
            except (TypeError, ValueError) as exc:
                raise ValueError(f"Invalid coordinate {index} in {path}") from exc
            if (
                not math.isfinite(longitude)
                or not math.isfinite(latitude)
                or not -180 <= longitude <= 180
                or not -90 <= latitude <= 90
            ):
                raise ValueError(f"Invalid coordinate {index} in {path}")
            parsed_coordinates.append((longitude, latitude))
        if len(set(parsed_coordinates)) != len(parsed_coordinates):
            raise ValueError(f"Duplicate coordinates in {path}")

        sample_n = int(row["sample_n"])
        sampling_seed = int(row["sampling_seed"])
        if len(parsed_coordinates) != sample_n:
            raise ValueError(
                f"Local-point file contains {len(parsed_coordinates)}/{sample_n} "
                f"points: {path}"
            )
        if str(value.get("site_id", "")) != site_id:
            raise ValueError(f"Local-point site_id mismatch: {path}")
        if int(value.get("requested_sample_n", -1)) != sample_n:
            raise ValueError(f"Local-point sample count mismatch: {path}")
        if int(value.get("sampling_seed", -1)) != sampling_seed:
            raise ValueError(f"Local-point seed mismatch: {path}")
        sampling_crs = str(row["sampling_crs"])
        if value.get("sampling_crs") != sampling_crs or sampling_crs != "EPSG:6933":
            raise ValueError(f"Local-point sampling CRS mismatch: {path}")
        bounds = (
            min(point[0] for point in parsed_coordinates),
            min(point[1] for point in parsed_coordinates),
            max(point[0] for point in parsed_coordinates),
            max(point[1] for point in parsed_coordinates),
        )
        file_bounds = tuple(float(item) for item in value.get("bounds", []))
        if len(file_bounds) != 4 or any(
            abs(actual - expected) > 1e-7
            for actual, expected in zip(bounds, file_bounds)
        ):
            raise ValueError(f"Local-point bounds mismatch: {path}")
        polygon_area_km2 = float(row["polygon_area_km2"])
        if not math.isfinite(polygon_area_km2) or polygon_area_km2 <= 0:
            raise ValueError(f"Invalid local-point polygon area: {path}")
        if abs(float(value.get("polygon_area_km2", 0)) - polygon_area_km2) > max(
            1e-6, polygon_area_km2 * 1e-9
        ):
            raise ValueError(f"Local-point polygon area mismatch: {path}")
        source_geometry_sha256 = str(row["source_geometry_sha256"]).lower()
        if value.get("source_geometry_sha256") != source_geometry_sha256:
            raise ValueError(f"Local-point source-geometry checksum mismatch: {path}")
        samples[site_id] = LocalPointSample(
            site_id=site_id,
            path=path,
            file_sha256=actual_sha256,
            sample_n=sample_n,
            sampling_seed=sampling_seed,
            sampling_crs=sampling_crs,
            polygon_area_km2=polygon_area_km2,
            source_geometry_sha256=source_geometry_sha256,
            bounds=bounds,
        )
    return samples


def attach_local_point_samples(
    plans: Iterable[TaskPlan],
    samples: dict[str, LocalPointSample],
) -> list[TaskPlan]:
    attached: list[TaskPlan] = []
    for plan in plans:
        sample = samples.get(plan.site.site_id)
        if sample is not None:
            if plan.method != "sample":
                raise ValueError(
                    f"Local points were supplied for exact site {plan.site.site_id}."
                )
            if sample.sample_n != plan.sample_points:
                raise ValueError(
                    f"Local-point count for {plan.site.site_id} is "
                    f"{sample.sample_n:,}; expected {plan.sample_points:,}."
                )
            if sample.sampling_seed != plan.sampling_seed:
                raise ValueError(f"Local-point seed mismatch for {plan.site.site_id}.")
            relative_area_error = abs(
                sample.polygon_area_km2 - plan.site.area_km2
            ) / plan.site.area_km2
            if relative_area_error > 0.001:
                raise ValueError(
                    f"Local-point area differs by {100 * relative_area_error:.3f}% "
                    f"for {plan.site.site_id}."
                )
            plan = replace(plan, local_point_sample=sample)
        attached.append(plan)
    return attached


def safe_asset_part(value: str, maximum: int = 38) -> str:
    cleaned = ASSET_PART_PATTERN.sub("_", value.lower()).strip("_-")
    if not cleaned:
        cleaned = "site"
    return cleaned[:maximum].rstrip("_-")


def stable_seed(site_id: str) -> int:
    # Earth Engine expects a signed 32-bit seed; never return zero.
    return int(hashlib.sha256(site_id.encode("utf-8")).hexdigest()[:8], 16) % (
        2**31 - 2
    ) + 1


def method_code(method: str, sample_points: int) -> str:
    if method == "exact":
        return "x"
    if sample_points % 1_000_000 == 0:
        return f"mph{sample_points // 1_000_000}m"
    if sample_points % 1_000 == 0:
        return f"mph{sample_points // 1_000}k"
    return f"mph{sample_points}"


# ---- Task planning ----


def choose_method(
    *,
    requested: str,
    exact_work: float,
    exact_max_work: float,
) -> str:
    if requested not in {"auto", "exact", "sample"}:
        raise ValueError("Method must be auto, exact, or sample.")
    if requested == "auto":
        return "exact" if exact_work <= exact_max_work else "sample"
    return requested


def plan_tasks(
    *,
    sites: Iterable[Site],
    method: str,
    sample_points: int,
    exact_max_work: float,
    run_label: str,
    output_folder: str,
) -> list[TaskPlan]:
    if sample_points < 10_000:
        raise ValueError("At least 10,000 sample points are required.")
    sampled_work = float(sample_points * len(YEARS))
    if sampled_work > MAX_EFFECTIVE_PIXELS_PER_TASK:
        raise ValueError(
            f"{sample_points:,} points x {len(YEARS)} dates exceeds the "
            f"{MAX_EFFECTIVE_PIXELS_PER_TASK:,} hard work ceiling."
        )
    if exact_max_work <= 0 or exact_max_work > MAX_EFFECTIVE_PIXELS_PER_TASK:
        raise ValueError(
            "The exact-work threshold must be positive and no greater than "
            f"{MAX_EFFECTIVE_PIXELS_PER_TASK:,}."
        )

    plans: list[TaskPlan] = []
    for site in sites:
        native_pixels = site.area_km2 * 1_000_000 / (NATIVE_SCALE_M**2)
        exact_work = native_pixels * len(YEARS)
        selected_method = choose_method(
            requested=method,
            exact_work=exact_work,
            exact_max_work=exact_max_work,
        )
        effective_work = exact_work if selected_method == "exact" else sampled_work
        if effective_work > MAX_EFFECTIVE_PIXELS_PER_TASK:
            raise ValueError(
                f"Unsafe forced-{selected_method} plan for {site.site_id}: "
                f"{effective_work:,.0f} pixel-band-time evaluations exceed the "
                f"{MAX_EFFECTIVE_PIXELS_PER_TASK:,} hard ceiling."
            )
        short_method = method_code(selected_method, sample_points)
        site_hash = hashlib.sha256(site.site_id.encode("utf-8")).hexdigest()[:10]
        site_part = safe_asset_part(site.site_id)
        description = f"glcsafe_{short_method}_{run_label}_{site_part}_{site_hash}"
        if len(description) > 100:
            raise ValueError(f"Task description exceeds 100 characters: {description}")
        plans.append(
            TaskPlan(
                description=description,
                asset_id=f"{output_folder.rstrip('/')}/{description}",
                site=site,
                method=selected_method,
                sample_points=sample_points if selected_method == "sample" else 0,
                sampling_seed=stable_seed(site.site_id),
                native_pixel_estimate=native_pixels,
                effective_pixel_band_time=effective_work,
            )
        )
    # Smoke-test the largest sampled watershed first. Once sampled work is done,
    # test the largest exact task before allowing any smaller exact tasks.
    return sorted(
        plans,
        key=lambda plan: (
            0 if plan.method == "sample" else 1,
            -plan.native_pixel_estimate
            if plan.method == "sample"
            else -plan.effective_pixel_band_time,
            plan.description,
        ),
    )


def launch_batch(missing: list[TaskPlan], maximum: int) -> list[TaskPlan]:
    if maximum < 1 or maximum > MAX_TASKS_PER_LAUNCH:
        raise ValueError(
            f"A launch must contain 1-{MAX_TASKS_PER_LAUNCH} new tasks."
        )
    if not missing:
        return []
    first_method = missing[0].method
    return [plan for plan in missing if plan.method == first_method][:maximum]


def workload_fingerprint(plans: Iterable[TaskPlan]) -> str:
    plans = list(plans)
    missing_samples = [
        plan.site.site_id
        for plan in plans
        if plan.method == "sample" and plan.local_point_sample is None
    ]
    if missing_samples:
        raise ValueError(
            "Sampled tasks lack local point files: " + ", ".join(missing_samples)
        )
    exact = [
        {
            "description": plan.description,
            "asset_id": plan.asset_id,
            "site_id": plan.site.site_id,
            "feature_sha256": plan.site.feature_sha256,
            "polygon_area_km2": round(plan.site.area_km2, 6),
            "method": plan.method,
            "sample_points": plan.sample_points,
            "sampling_seed": plan.sampling_seed,
            "years": list(YEARS),
            "native_scale_m": NATIVE_SCALE_M,
            "source_collections": [FIVE_YEAR_COLLECTION, ANNUAL_COLLECTION],
            "sampler_version": SAMPLER_VERSION if plan.method == "sample" else None,
            "sampled_reducer_version": (
                SAMPLED_REDUCER_VERSION if plan.method == "sample" else None
            ),
            "local_point_file_sha256": (
                plan.local_point_sample.file_sha256
                if plan.local_point_sample is not None
                else None
            ),
            "source_geometry_sha256": (
                plan.local_point_sample.source_geometry_sha256
                if plan.local_point_sample is not None
                else None
            ),
        }
        for plan in plans
    ]
    return canonical_sha256(exact)


def sampling_standard_error(fraction: float, sample_count: int) -> float:
    if not 0 <= fraction <= 1:
        raise ValueError("Fraction must be between zero and one.")
    if sample_count < 1:
        raise ValueError("Sample count must be positive.")
    return math.sqrt(fraction * (1 - fraction) / sample_count)


# ---- Earth Engine exports ----


def require_earth_engine() -> None:
    if ee is None:
        raise RuntimeError(
            "The Earth Engine Python API is required. Install earthengine-api, "
            "authenticate, and rerun."
        )


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


def unsafe_legacy_descriptions(descriptions: Iterable[str]) -> list[str]:
    return sorted(
        description
        for description in descriptions
        if description.startswith(UNSAFE_LEGACY_PREFIXES)
    )


def asset_or_none(asset_id: str) -> Any:
    try:
        return ee.data.getAsset(asset_id)
    except ee.EEException as exc:
        message = str(exc).lower()
        if "not found" in message or "does not exist" in message or "404" in message:
            return None
        raise


def ensure_folder(asset_id: str) -> None:
    if asset_or_none(asset_id) is None:
        ee.data.createAsset({"type": "FOLDER"}, asset_id)


def child_asset_ids(parent: str) -> set[str]:
    if asset_or_none(parent) is None:
        return set()
    found: set[str] = set()
    request: dict[str, Any] = {"parent": parent, "pageSize": 1_000}
    while True:
        response = ee.data.listAssets(request)
        for asset in response.get("assets", []):
            asset_id = asset.get("name") or asset.get("id")
            if asset_id:
                found.add(str(asset_id))
        token = response.get("nextPageToken")
        if not token:
            return found
        request["pageToken"] = token


def verify_site_geometry(site: Site) -> Site:
    feature = ee.Feature(site.feature)
    values = ee.Dictionary(
        {
            "site_id": feature.get("site_id"),
            "area_km2": feature.geometry().area(maxError=1).divide(1_000_000),
        }
    ).getInfo()
    if str(values["site_id"]) != site.site_id:
        raise RuntimeError(f"Earth Engine changed site_id for {site.site_id}.")
    actual_area = float(values["area_km2"])
    relative_difference = abs(actual_area - site.area_km2) / max(actual_area, 1e-12)
    if relative_difference > 0.01:
        raise RuntimeError(
            f"Local area for {site.site_id} differs from Earth Engine by "
            f"{100 * relative_difference:.2f}%; rebuild the vector payloads."
        )
    return replace(site, area_km2=actual_area)


def glc_multiband_image(geometry: Any) -> Any:
    five_year = (
        ee.ImageCollection(FIVE_YEAR_COLLECTION)
        .filterBounds(geometry)
        .select(["b1", "b2", "b3"])
        .mosaic()
        .rename(["1985", "1990", "1995"])
    )
    annual_source_bands = [f"b{index}" for index in range(1, 24)]
    annual_output_bands = [str(year) for year in range(2000, 2023)]
    annual = (
        ee.ImageCollection(ANNUAL_COLLECTION)
        .filterBounds(geometry)
        .select(annual_source_bands)
        .mosaic()
        .rename(annual_output_bands)
    )
    return five_year.addBands(annual)


def base_output_properties(plan: TaskPlan, year: int) -> dict[str, Any]:
    properties = plan.site.feature["properties"]
    result = {
        **{name: properties.get(name) for name in METADATA_PROPERTIES},
        "Year": year,
        "source": "GLC_FCS30D",
        "extraction_method": (
            "native_30m_exact"
            if plan.method == "exact"
            else f"deterministic_{SAMPLER_VERSION}"
        ),
        "polygon_area_m2": plan.site.area_km2 * 1_000_000,
        "native_pixel_estimate": plan.native_pixel_estimate,
        "effective_pixel_band_time": plan.effective_pixel_band_time,
        "requested_sample_n": plan.sample_points,
        "sampling_seed": plan.sampling_seed if plan.method == "sample" else -1,
        "glc_geometry_simplified_m": properties.get("glc_geometry_simplified_m"),
        "glc_simplification_area_error_pct": properties.get(
            "glc_simplification_area_error_pct"
        ),
    }
    if plan.local_point_sample is not None:
        result.update(
            {
                "local_point_file_sha256": plan.local_point_sample.file_sha256,
                "local_point_source_geometry_sha256": (
                    plan.local_point_sample.source_geometry_sha256
                ),
                "local_point_sampling_crs": plan.local_point_sample.sampling_crs,
                "sampled_reducer_version": SAMPLED_REDUCER_VERSION,
            }
        )
    return {key: value for key, value in result.items() if value is not None}


def lookup_from_grouped_area(groups: Any) -> Any:
    def add_group(item: Any, accumulator: Any) -> Any:
        item = ee.Dictionary(item)
        return ee.Dictionary(accumulator).set(
            ee.Number(item.get("LC_ID")).format("%d"), item.get("sum")
        )

    return ee.Dictionary(ee.List(groups).iterate(add_group, ee.Dictionary({})))


def build_exact_export(plan: TaskPlan) -> Any:
    feature = ee.Feature(plan.site.feature)
    geometry = feature.geometry()
    image = glc_multiband_image(geometry)
    maximum_pixels_per_date = min(
        MAX_EFFECTIVE_PIXELS_PER_TASK,
        math.ceil(plan.native_pixel_estimate * 1.10) + 10_000,
    )
    yearly_tables = []
    for year in YEARS:
        land_cover = image.select(str(year)).rename("land_cover")
        grouped = ee.Dictionary(
            ee.Image.pixelArea()
            .rename("area")
            .addBands(land_cover)
            .reduceRegion(
                reducer=ee.Reducer.sum().group(groupField=1, groupName="LC_ID"),
                geometry=geometry,
                scale=NATIVE_SCALE_M,
                bestEffort=False,
                maxPixels=maximum_pixels_per_date,
                tileScale=4,
            )
        )
        lookup = lookup_from_grouped_area(grouped.get("groups", ee.List([])))
        base = ee.Dictionary(base_output_properties(plan, year))

        def one_class(class_id: Any) -> Any:
            class_number = ee.Number(class_id)
            key = class_number.format("%d")
            area = ee.Number(ee.Algorithms.If(lookup.contains(key), lookup.get(key), 0))
            return ee.Feature(
                None,
                base.set("LC_ID", class_number)
                .set("Area_m2", area)
                .set("sample_count", -1)
                .set("sample_n", -1)
                .set("sample_fraction", -1)
                .set("sample_standard_error", 0),
            )

        yearly_tables.append(ee.FeatureCollection(ee.List(GLC_CLASSES).map(one_class)))
    return ee.FeatureCollection(yearly_tables).flatten()


def build_sample_export(plan: TaskPlan) -> Any:
    local_sample = plan.local_point_sample
    if local_sample is None:
        raise ValueError(f"No local point sample for {plan.site.site_id}.")
    value = read_local_point_file(local_sample.path)
    points = ee.Geometry.MultiPoint(value["coordinates"], "EPSG:4326")
    image = glc_multiband_image(points)
    histograms = ee.Dictionary(
        image.unmask(-999).reduceRegion(
            reducer=ee.Reducer.frequencyHistogram(),
            geometry=points,
            scale=NATIVE_SCALE_M,
            bestEffort=False,
            maxPixels=local_sample.sample_n * len(YEARS) + 10_000,
            tileScale=4,
        )
    )
    polygon_area_m2 = ee.Number(plan.site.area_km2 * 1_000_000)
    yearly_tables = []
    for year in YEARS:
        histogram = ee.Dictionary(
            histograms.get(str(year), ee.Dictionary({}))
        )
        total_n = ee.Number(
            ee.Algorithms.If(
                histogram.size().gt(0),
                histogram.values().reduce(ee.Reducer.sum()),
                0,
            )
        )
        missing_n = ee.Number(
            ee.Algorithms.If(histogram.contains("-999"), histogram.get("-999"), 0)
        )
        sample_n = total_n.subtract(missing_n)
        safe_sample_n = sample_n.max(1)
        base = ee.Dictionary(base_output_properties(plan, year))

        def one_class(class_id: Any) -> Any:
            class_number = ee.Number(class_id)
            key = class_number.format("%d")
            count = ee.Number(
                ee.Algorithms.If(histogram.contains(key), histogram.get(key), 0)
            )
            fraction = count.divide(safe_sample_n)
            standard_error = fraction.multiply(ee.Number(1).subtract(fraction)).divide(
                safe_sample_n
            ).sqrt()
            return ee.Feature(
                None,
                base.set("LC_ID", class_number)
                .set("Area_m2", fraction.multiply(polygon_area_m2))
                .set("sample_count", count)
                .set("sample_n", sample_n)
                .set("sample_fraction", fraction)
                .set("sample_standard_error", standard_error),
            )

        yearly_tables.append(ee.FeatureCollection(ee.List(GLC_CLASSES).map(one_class)))
    return ee.FeatureCollection(yearly_tables).flatten()


def make_export_task(plan: TaskPlan) -> Any:
    table = build_exact_export(plan) if plan.method == "exact" else build_sample_export(plan)
    return ee.batch.Export.table.toAsset(
        collection=table,
        description=plan.description,
        assetId=plan.asset_id,
    )


def validate_export_graph(plan: TaskPlan) -> int:
    """Serialize an unstarted export task and return its request size."""
    task = make_export_task(plan)
    config = dict(task.config)
    config["expression"] = ee.serializer.encode(
        config["expression"], for_cloud_api=True
    )
    encoded = json.dumps(config, sort_keys=True, separators=(",", ":"))
    if not encoded or plan.description not in encoded or plan.asset_id not in encoded:
        raise RuntimeError(f"Export graph validation failed for {plan.description}.")
    return len(encoded.encode("utf-8"))


# ---- Submission records ----


def preflight_dimensions(plans: list[TaskPlan]) -> dict[str, Any]:
    if not plans:
        raise ValueError("No plans were supplied.")
    methods = {plan.method for plan in plans}
    if len(methods) != 1:
        raise ValueError("A preflight receipt cannot mix exact and sampled tasks.")
    method = plans[0].method
    sample_sizes = {plan.sample_points for plan in plans}
    if len(sample_sizes) != 1:
        raise ValueError("A preflight receipt cannot mix sample sizes.")
    sample_points = plans[0].sample_points
    short_method = method_code(method, sample_points)
    workflow = f"glc_fcs30d_{method}"
    if method == "sample":
        workflow = f"{workflow}_{sample_points}"
    return {
        "workflow": workflow,
        "description_prefix": f"glcsafe_{short_method}_",
        "task_count": len(plans),
        "site_count": len(plans),
        "max_area_km2": max(plan.site.area_km2 for plan in plans),
        "max_work": max(plan.effective_pixel_band_time for plan in plans),
        "fingerprint": workload_fingerprint(plans),
    }


def preflight_command(project: str, plans: list[TaskPlan], receipt: Path) -> str:
    dimensions = preflight_dimensions(plans)
    command = [
        "Rscript",
        str(HELPER_ROOT / "gee_quota_preflight.R"),
        "--project",
        project,
        "--workflow",
        dimensions["workflow"],
        "--description-prefix",
        dimensions["description_prefix"],
        "--proposed-task-count",
        str(dimensions["task_count"]),
        "--site-count",
        str(dimensions["site_count"]),
        "--max-task-area-km2",
        str(dimensions["max_area_km2"]),
        "--scale-m",
        str(NATIVE_SCALE_M),
        "--time-slices-per-task",
        str(len(YEARS)),
        "--bands-per-slice",
        "1",
        "--effective-pixels-per-task",
        str(dimensions["max_work"]),
        "--workload-fingerprint",
        dimensions["fingerprint"],
        "--receipt",
        str(receipt),
    ]
    return shlex.join(command)


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
    effective_pixels_per_task: float,
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
        str(max_task_area_km2),
        "--scale-m",
        str(scale_m),
        "--time-slices-per-task",
        str(time_slices_per_task),
        "--bands-per-slice",
        str(bands_per_slice),
        "--effective-pixels-per-task",
        str(effective_pixels_per_task),
        "--workload-fingerprint",
        workload_fingerprint,
    ]
    subprocess.run(command, check=True)


# ---- Command line ----


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, default=DEFAULT_RUN_ROOT)
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Defaults to RUN_ROOT/payload_manifest.csv.",
    )
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--run-label", required=True)
    parser.add_argument(
        "--output-folder",
        help="Defaults to projects/PROJECT/assets/glc_fcs30d_safe_RUN_LABEL.",
    )
    parser.add_argument("--method", choices=("auto", "exact", "sample"), default="auto")
    parser.add_argument("--sample-points", type=int, default=DEFAULT_SAMPLE_POINTS)
    parser.add_argument(
        "--local-point-manifest",
        type=Path,
        help="Manifest created by build_local_glc_sample_points.R.",
    )
    parser.add_argument(
        "--exact-max-work",
        type=float,
        help=(
            "Maximum pixel x date work for auto-selected exact extraction; "
            "defaults to SAMPLE_POINTS x 26 dates."
        ),
    )
    parser.add_argument(
        "--site-id",
        action="append",
        help="Restrict to one site_id; repeat to select multiple sites.",
    )
    parser.add_argument("--expected-site-count", type=int)
    parser.add_argument("--max-new-tasks", type=int, default=1)
    parser.add_argument("--preflight-receipt", type=Path)
    parser.add_argument("--submit", action="store_true")
    args = parser.parse_args()
    if not LABEL_PATTERN.fullmatch(args.run_label):
        parser.error("--run-label must contain lowercase letters, numbers, and underscores.")
    if args.max_new_tasks < 1 or args.max_new_tasks > MAX_TASKS_PER_LAUNCH:
        parser.error(f"--max-new-tasks must be 1-{MAX_TASKS_PER_LAUNCH}.")
    if args.expected_site_count is not None and args.expected_site_count < 1:
        parser.error("--expected-site-count must be positive.")
    if args.exact_max_work is None:
        args.exact_max_work = args.sample_points * len(YEARS)
    args.manifest = args.manifest or args.run_root / "payload_manifest.csv"
    args.output_folder = args.output_folder or (
        f"projects/{args.project}/assets/glc_fcs30d_safe_{args.run_label}"
    )
    return args


def main() -> None:
    args = parse_args()
    require_earth_engine()
    sites = load_sites(args.manifest)
    if args.site_id:
        selected = set(args.site_id)
        known = {site.site_id for site in sites}
        missing_ids = sorted(selected - known)
        if missing_ids:
            raise ValueError("Unknown site_id values: " + ", ".join(missing_ids))
        sites = [site for site in sites if site.site_id in selected]
    if args.expected_site_count is not None and len(sites) != args.expected_site_count:
        raise RuntimeError(
            f"Selected {len(sites)} sites; expected {args.expected_site_count}."
        )
    plans = plan_tasks(
        sites=sites,
        method=args.method,
        sample_points=args.sample_points,
        exact_max_work=args.exact_max_work,
        run_label=args.run_label,
        output_folder=args.output_folder,
    )
    local_samples = (
        load_local_point_samples(args.local_point_manifest)
        if args.local_point_manifest is not None
        else {}
    )
    plans = attach_local_point_samples(plans, local_samples)

    ee.Initialize(project=args.project)
    active = active_descriptions()
    unsafe_active = unsafe_legacy_descriptions(active)
    if unsafe_active:
        raise RuntimeError(
            f"{len(unsafe_active)} unsafe legacy other_targets GLC tasks are still "
            "active or queued. Cancel every task beginning with "
            "glc_followup_other_targets_ before planning any new work."
        )
    existing = child_asset_ids(args.output_folder)
    complete = [plan for plan in plans if plan.asset_id in existing]
    underway = [plan for plan in plans if plan.description in active]
    missing = [
        plan
        for plan in plans
        if plan.asset_id not in existing and plan.description not in active
    ]
    launch = launch_batch(missing, args.max_new_tasks)
    counts_by_method = {
        method: sum(plan.method == method for plan in plans)
        for method in ("sample", "exact")
    }
    print(
        f"GLC targets: {len(plans)} sites ({counts_by_method['exact']} exact, "
        f"{counts_by_method['sample']} sampled); {len(complete)} complete, "
        f"{len(underway)} active, {len(missing)} missing."
    )
    if launch:
        missing_local_points = [
            plan.site.site_id
            for plan in launch
            if plan.method == "sample" and plan.local_point_sample is None
        ]
        if missing_local_points:
            raise RuntimeError(
                "Selected sampled tasks lack local point files: "
                + ", ".join(missing_local_points)
                + ". Build them with build_local_glc_sample_points.R."
            )
        verified_launch: list[TaskPlan] = []
        for plan in launch:
            if plan.method == "sample":
                verified_launch.append(plan)
                continue
            verified_site = verify_site_geometry(plan.site)
            verified_plan = plan_tasks(
                sites=[verified_site],
                method="exact",
                sample_points=args.sample_points,
                exact_max_work=args.exact_max_work,
                run_label=args.run_label,
                output_folder=args.output_folder,
            )[0]
            verified_launch.append(verified_plan)
        launch = verified_launch
        for plan in launch:
            print(
                f"  {plan.description}: {plan.method}, {plan.site.area_km2:,.1f} km2, "
                f"{plan.effective_pixel_band_time:,.0f} bounded pixel-band-time"
            )
        default_receipt = Path("generated_outputs/gee_preflight") / (
            f"{launch[0].description}_receipt.json"
        )
        receipt_path = args.preflight_receipt or default_receipt
        print("Run this exact preflight command before submission:")
        print(preflight_command(args.project, launch, receipt_path))
    else:
        print("No missing tasks remain.")
        return

    if not args.submit:
        for plan in launch:
            graph_bytes = validate_export_graph(plan)
            print(
                f"Validated unstarted {plan.method} export graph: "
                f"{graph_bytes:,} request bytes."
            )
        print("Dry run only; no Earth Engine task was submitted.")
        return
    if args.preflight_receipt is None:
        raise RuntimeError("--submit requires --preflight-receipt.")

    dimensions = preflight_dimensions(launch)
    consume_preflight_receipt(
        args.preflight_receipt,
        project=args.project,
        workflow=dimensions["workflow"],
        description_prefix=dimensions["description_prefix"],
        proposed_task_count=dimensions["task_count"],
        site_count=dimensions["site_count"],
        max_task_area_km2=dimensions["max_area_km2"],
        scale_m=NATIVE_SCALE_M,
        time_slices_per_task=len(YEARS),
        bands_per_slice=1,
        effective_pixels_per_task=dimensions["max_work"],
        workload_fingerprint=dimensions["fingerprint"],
    )
    ensure_folder(args.output_folder)
    for plan in launch:
        task = make_export_task(plan)
        task.start()
        print(f"Submitted {plan.description} -> {plan.asset_id}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"SAFE GLC EXPORT ERROR: {exc}", file=sys.stderr)
        raise
