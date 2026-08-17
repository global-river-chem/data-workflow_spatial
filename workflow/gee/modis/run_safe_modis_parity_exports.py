"""Plan and safely submit MODIS parity summaries for replacement watersheds.

The local default only validates inputs and prints a task plan. Earth Engine is
contacted only with ``--check-existing`` or ``--submit``. Submission requires a
fresh quota receipt matching the exact tasks selected for the launch.
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
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Iterable


try:
    import ee
except ImportError:  # Pure local planning and self-tests do not need Earth Engine
    ee = None


HELPER_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_PROJECT = os.getenv("SILICA_GEE_PROJECT", "silica-synthesis")
ET_COLLECTION = "MODIS/061/MOD16A2GF"
NPP_COLLECTION = "MODIS/061/MOD17A3HGF"
GREENUP_COLLECTION = "MODIS/061/MCD12Q2"
SNOW_COLLECTION = "MODIS/061/MOD10A2"
ANALYSIS_SCALE_M = 500.0
MAX_EFFECTIVE_PIXELS_PER_TASK = 100_000_000
MAX_TASKS_PER_LAUNCH = 5
DEFAULT_SPATIAL_PIXEL_CAP = 10_000
DEFAULT_PAYLOAD_MEGABYTES = 5.0
EXTRACTION_VERSION = "modis_release3_field_time_bounded_scale_v3"
DESCRIPTION_PREFIX = "modis4_"
WORKFLOW_NAME = "modis_parity_half_year"
METADATA_PROPERTIES = (
    "site_id",
    "LTER",
    "Stream_Name",
    "Shapefile_Name",
    "Discharge_File_Name",
)
LABEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_]*$")
ASSET_PART_PATTERN = re.compile(r"[^a-z0-9_-]+")
ACTIVE_STATES = {
    "READY",
    "RUNNING",
    "PENDING",
    "CANCEL_REQUESTED",
    "CANCELLING",
}
COMPOSITE_DOYS = tuple(range(1, 362, 8))
SNOW_DOYS_BY_YEAR = {
    2001: tuple(doy for doy in COMPOSITE_DOYS if doy not in (169, 177)),
    2016: tuple(doy for doy in COMPOSITE_DOYS if doy != 49),
    2022: tuple(doy for doy in COMPOSITE_DOYS if doy != 289),
}
HALF_DOYS = {
    "h1": COMPOSITE_DOYS[:23],
    "h2": COMPOSITE_DOYS[23:],
}


@dataclass(frozen=True)
class Payload:
    name: str
    sites: int
    area_km2: float
    sha256: str
    features: tuple[dict[str, Any], ...]
    effective_pixels: float = 0.0
    geojson_bytes: int = 0


@dataclass(frozen=True)
class TaskPlan:
    description: str
    asset_id: str
    payload: Payload
    year: int
    half: str
    doys: tuple[int, ...]
    band_count: int
    effective_pixel_bands: float


def parse_integer_selection(
    value: str, minimum: int, maximum: int
) -> tuple[int, ...]:
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


def parse_halves(value: str) -> tuple[str, ...]:
    halves = tuple(item.strip() for item in value.split(",") if item.strip())
    if not halves or len(set(halves)) != len(halves):
        raise ValueError("List each requested half once.")
    unknown = sorted(set(halves) - set(HALF_DOYS))
    if unknown:
        raise ValueError("Halves must be h1, h2, or h1,h2.")
    return halves


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_geojson(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    features = data.get("features")
    if data.get("type") != "FeatureCollection" or not isinstance(features, list):
        raise ValueError(f"Not a GeoJSON FeatureCollection: {path}")
    if not features:
        raise ValueError(f"GeoJSON contains no features: {path}")
    for index, feature in enumerate(features, start=1):
        properties = feature.get("properties") or {}
        missing = [name for name in METADATA_PROPERTIES if name not in properties]
        if missing:
            raise ValueError(
                f"{path}, feature {index}, lacks: {', '.join(missing)}"
            )
        if not feature.get("geometry"):
            raise ValueError(f"{path}, feature {index}, has no geometry.")
    return data


def feature_json_bytes(feature: dict[str, Any]) -> int:
    return len(
        json.dumps(
            feature,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("utf-8")
    )


def feature_area_km2(feature: dict[str, Any], source: Path) -> float:
    properties = feature.get("properties") or {}
    try:
        area_km2 = float(properties["polygon_area_km2"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(
            f"Feature in {source} needs a positive polygon_area_km2 property."
        ) from exc
    if not math.isfinite(area_km2) or area_km2 <= 0:
        raise ValueError(f"Invalid polygon_area_km2 in {source}: {area_km2}")
    return area_km2


def payload_hash(features: Iterable[dict[str, Any]]) -> str:
    value = json.dumps(
        list(features),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def fallback_seed(site_id: str) -> int:
    value = hashlib.sha256(site_id.encode("utf-8")).digest()
    return int.from_bytes(value[:4], "big") % 2_147_483_647


def load_payload_list(path: Path) -> list[Payload]:
    list_path = path.resolve()
    if not list_path.is_file():
        raise ValueError(f"Payload list does not exist: {list_path}")
    with list_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    required = {"payload", "path", "sites", "polygon_area_km2_sum"}
    if not rows or not required.issubset(rows[0]):
        raise ValueError("Payload list lacks one or more required columns.")

    payloads: list[Payload] = []
    all_ids: set[str] = set()
    for row in rows:
        payload_path = Path(str(row["path"]))
        if not payload_path.is_absolute():
            payload_path = list_path.parent / payload_path
        payload_path = payload_path.resolve()
        if not payload_path.is_file():
            raise ValueError(f"Payload does not exist: {payload_path}")
        data = read_geojson(payload_path)
        features = tuple(data["features"])
        ids = [
            str(feature["properties"]["site_id"]).strip()
            for feature in features
        ]
        if any(not site_id for site_id in ids) or len(set(ids)) != len(ids):
            raise ValueError(f"Blank or duplicate site_id in {payload_path}")
        repeated = sorted(set(ids) & all_ids)
        if repeated:
            raise ValueError(f"Site occurs in two payloads: {repeated[0]}")
        all_ids.update(ids)
        declared_sites = int(row["sites"])
        if declared_sites != len(ids):
            raise ValueError(
                f"Payload list says {declared_sites} sites for {payload_path}; "
                f"GeoJSON contains {len(ids)}."
            )
        area_km2 = float(row["polygon_area_km2_sum"])
        if area_km2 <= 0:
            raise ValueError(f"Payload area must be positive: {payload_path}")
        feature_area = sum(
            feature_area_km2(feature, payload_path) for feature in features
        )
        if abs(feature_area - area_km2) > max(1e-6, area_km2 * 1e-6):
            raise ValueError(
                f"Payload area properties differ from the payload list: "
                f"{payload_path}"
            )
        payloads.append(
            Payload(
                name=str(row["payload"]),
                sites=declared_sites,
                area_km2=area_km2,
                sha256=file_sha256(payload_path),
                features=features,
                geojson_bytes=sum(feature_json_bytes(item) for item in features),
            )
        )
    names = [payload.name for payload in payloads]
    if len(set(names)) != len(names):
        raise ValueError("Payload names must be distinct.")
    return payloads


def rebatch_payloads(
    payloads: Iterable[Payload],
    *,
    pixel_cap: int,
    maximum_payload_mb: float,
) -> list[Payload]:
    features = [feature for payload in payloads for feature in payload.features]
    if not features:
        raise ValueError("No watershed features were supplied.")
    records = []
    for feature in features:
        area_km2 = feature_area_km2(feature, Path("input payload"))
        native_pixels = area_km2 * 1_000_000 / ANALYSIS_SCALE_M**2
        effective_pixels = min(native_pixels, float(pixel_cap))
        analysis_scale_m = max(
            ANALYSIS_SCALE_M,
            math.sqrt(area_km2 * 1_000_000 / pixel_cap),
        )
        value = json.loads(json.dumps(feature))
        properties = value.setdefault("properties", {})
        properties["_modis_analysis_scale_m"] = analysis_scale_m
        properties["_modis_effective_pixels"] = effective_pixels
        properties["_modis_fallback_seed"] = fallback_seed(
            str(properties["site_id"])
        )
        records.append(
            {
                "feature": value,
                "area_km2": area_km2,
                "effective_pixels": effective_pixels,
                "bytes": feature_json_bytes(value),
            }
        )

    maximum_bytes = maximum_payload_mb * 1024**2
    minimum_groups = max(
        1,
        math.ceil(
            sum(item["effective_pixels"] for item in records)
            * 210
            / MAX_EFFECTIVE_PIXELS_PER_TASK
        ),
        math.ceil(sum(item["bytes"] for item in records) / maximum_bytes),
    )
    for group_count in range(minimum_groups, len(records) + 1):
        groups = [
            {"records": [], "pixels": 0.0, "bytes": 0, "area": 0.0}
            for _ in range(group_count)
        ]
        ordered = sorted(
            records,
            key=lambda item: (item["bytes"], item["effective_pixels"]),
            reverse=True,
        )
        target_pixels = sum(item["effective_pixels"] for item in records) / group_count
        target_bytes = sum(item["bytes"] for item in records) / group_count
        for item in ordered:
            group = min(
                groups,
                key=lambda candidate: (
                    (candidate["pixels"] + item["effective_pixels"])
                    / target_pixels
                    + (candidate["bytes"] + item["bytes"]) / target_bytes,
                    len(candidate["records"]),
                ),
            )
            group["records"].append(item)
            group["pixels"] += item["effective_pixels"]
            group["bytes"] += item["bytes"]
            group["area"] += item["area_km2"]
        if all(
            group["bytes"] <= maximum_bytes
            and group["pixels"] * 210 <= MAX_EFFECTIVE_PIXELS_PER_TASK
            for group in groups
        ):
            output = []
            for index, group in enumerate(groups, start=1):
                batch_features = tuple(
                    sorted(
                        (item["feature"] for item in group["records"]),
                        key=lambda feature: str(
                            feature["properties"]["site_id"]
                        ),
                    )
                )
                output.append(
                    Payload(
                        name=f"modis_{index:02d}",
                        sites=len(batch_features),
                        area_km2=group["area"],
                        sha256=payload_hash(batch_features),
                        features=batch_features,
                        effective_pixels=group["pixels"],
                        geojson_bytes=group["bytes"],
                    )
                )
            return output
    raise RuntimeError("Could not build safe in-memory MODIS payloads.")


def payload_site_ids(payloads: Iterable[Payload]) -> tuple[str, ...]:
    return tuple(
        sorted(
            str(feature["properties"]["site_id"]).strip()
            for payload in payloads
            for feature in payload.features
        )
    )


def read_expected_site_ids(path: Path) -> tuple[int, tuple[str, ...]]:
    expected_path = path.resolve()
    if not expected_path.is_file():
        raise ValueError(f"Expected site file does not exist: {expected_path}")
    delimiter = "\t" if expected_path.suffix.lower() == ".tsv" else ","
    with expected_path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        if not reader.fieldnames or "site_id" not in reader.fieldnames:
            raise ValueError("Expected site file must contain site_id.")
        values = [str(row["site_id"]).strip() for row in reader]
    if not values or any(not value for value in values):
        raise ValueError("Expected site file is empty or contains blank IDs.")
    return len(values), tuple(sorted(set(values)))


def validate_site_coverage(
    actual_ids: Iterable[str],
    *,
    expected_count: int | None,
    expected_ids: Iterable[str] | None,
) -> tuple[str, ...]:
    actual = tuple(actual_ids)
    if not actual or any(not value for value in actual):
        raise ValueError("Payloads contain no site IDs or a blank site ID.")
    if len(actual) != len(set(actual)):
        raise ValueError("Payloads contain duplicate site IDs.")
    if expected_count is not None and len(actual) != expected_count:
        raise RuntimeError(
            f"Payloads contain {len(actual)} sites; expected {expected_count}."
        )
    if expected_ids is not None:
        expected = set(expected_ids)
        actual_set = set(actual)
        missing = sorted(expected - actual_set)
        unexpected = sorted(actual_set - expected)
        if missing or unexpected:
            raise RuntimeError(
                "Payload site IDs do not match the accepted set. "
                f"Missing: {missing[:10]}; unexpected: {unexpected[:10]}."
            )
    return tuple(sorted(actual))


def safe_asset_part(value: str) -> str:
    cleaned = ASSET_PART_PATTERN.sub("_", value.lower()).strip("_-")
    if not cleaned:
        raise ValueError(f"Cannot form an asset name from {value!r}.")
    return cleaned


def task_band_count(year: int, half: str) -> int:
    snow_doys = set(SNOW_DOYS_BY_YEAR.get(year, COMPOSITE_DOYS))
    count = len(HALF_DOYS[half])
    count += sum(doy in snow_doys for doy in HALF_DOYS[half]) * 8
    if half == "h1":
        count += 1  # Annual NPP
        if year <= 2024:
            count += 2  # Two greenup cycles
    return count


def plan_tasks(
    *,
    payloads: Iterable[Payload],
    years: Iterable[int],
    halves: Iterable[str],
    run_label: str,
    output_folder: str,
) -> list[TaskPlan]:
    plans: list[TaskPlan] = []
    for year in years:
        for half in halves:
            for payload in payloads:
                payload_name = safe_asset_part(payload.name)
                description = (
                    f"{DESCRIPTION_PREFIX}{run_label}_{payload_name}_{year}_{half}"
                )
                if len(description) > 100:
                    raise ValueError(
                        "Earth Engine task description exceeds 100 characters: "
                        + description
                    )
                band_count = task_band_count(year, half)
                work = payload.effective_pixels * band_count
                plans.append(
                    TaskPlan(
                        description=description,
                        asset_id=f"{output_folder.rstrip('/')}/{description}",
                        payload=payload,
                        year=year,
                        half=half,
                        doys=HALF_DOYS[half],
                        band_count=band_count,
                        effective_pixel_bands=work,
                    )
                )
    return sorted(
        plans,
        key=lambda item: (
            item.year,
            item.half,
            item.effective_pixel_bands,
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
            "half": plan.half,
            "doys": list(plan.doys),
            "band_count": plan.band_count,
            "scale_m": ANALYSIS_SCALE_M,
            "spatial_pixel_cap": DEFAULT_SPATIAL_PIXEL_CAP,
            "extraction_version": EXTRACTION_VERSION,
        }
        for plan in plans
    ]
    serialized = json.dumps(exact, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def launch_site_count(plans: Iterable[TaskPlan]) -> int:
    return sum({plan.payload.name: plan.payload.sites for plan in plans}.values())


def print_plan(plans: list[TaskPlan], total_missing: int) -> None:
    print(
        f"Missing tasks: {total_missing}; eligible in this launch: {len(plans)}."
    )
    for plan in plans:
        print(
            f"  {plan.description}: {plan.payload.sites} sites, "
            f"{plan.payload.area_km2:,.1f} km2, {plan.band_count} bands, "
            f"{plan.effective_pixel_bands:,.0f} pixel-band operations"
        )


def preflight_command(
    *,
    project: str,
    plans: list[TaskPlan],
    receipt: Path,
    monthly_stop_hours: float,
    watchdog_hours: float,
) -> str:
    command = [
        "Rscript",
        str(HELPER_ROOT / "gee_quota_preflight.R"),
        "--project",
        project,
        "--workflow",
        WORKFLOW_NAME,
        "--description-prefix",
        DESCRIPTION_PREFIX,
        "--proposed-task-count",
        str(len(plans)),
        "--site-count",
        str(launch_site_count(plans)),
        "--max-task-area-km2",
        f"{max(plan.payload.area_km2 for plan in plans):.6f}",
        "--scale-m",
        str(ANALYSIS_SCALE_M),
        "--time-slices-per-task",
        "1",
        "--bands-per-slice",
        str(max(plan.band_count for plan in plans)),
        "--effective-pixels-per-task",
        f"{max(plan.effective_pixel_bands for plan in plans):.0f}",
        "--monthly-stop-eecu-hours",
        str(monthly_stop_hours),
        "--watchdog-cancel-eecu-hours",
        str(watchdog_hours),
        "--workload-fingerprint",
        workload_fingerprint(plans),
        "--receipt",
        str(receipt),
    ]
    return " ".join(shlex.quote(part) for part in command)


def consume_receipt(receipt: Path, plans: list[TaskPlan], project: str) -> None:
    command = [
        "Rscript",
        str(HELPER_ROOT / "gee_quota_preflight.R"),
        "--consume",
        "--receipt",
        str(receipt),
        "--project",
        project,
        "--workflow",
        WORKFLOW_NAME,
        "--description-prefix",
        DESCRIPTION_PREFIX,
        "--proposed-task-count",
        str(len(plans)),
        "--site-count",
        str(launch_site_count(plans)),
        "--max-task-area-km2",
        f"{max(plan.payload.area_km2 for plan in plans):.6f}",
        "--scale-m",
        str(ANALYSIS_SCALE_M),
        "--time-slices-per-task",
        "1",
        "--bands-per-slice",
        str(max(plan.band_count for plan in plans)),
        "--effective-pixels-per-task",
        f"{max(plan.effective_pixel_bands for plan in plans):.0f}",
        "--workload-fingerprint",
        workload_fingerprint(plans),
    ]
    subprocess.run(command, check=True)


def require_earth_engine(project: str) -> None:
    if ee is None:
        raise RuntimeError(
            "Install the Earth Engine Python API before checking or submitting."
        )
    ee.Initialize(project=project)


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


def geojson_feature_collection(payload: Payload) -> Any:
    return ee.FeatureCollection(list(payload.features))


def verify_payload_geometry(payload: Payload) -> Payload:
    collection = geojson_feature_collection(payload)
    checked = collection.map(
        lambda feature: feature.set(
            {
                "_area_km2": feature.geometry()
                .area(maxError=1)
                .divide(1_000_000),
                "_declared_area_km2": feature.get("polygon_area_km2"),
            }
        )
    )
    result = ee.Dictionary(
        {
            "sites": checked.size(),
            "site_ids": checked.aggregate_array("site_id"),
            "actual_area_km2": checked.aggregate_array("_area_km2"),
            "declared_area_km2": checked.aggregate_array(
                "_declared_area_km2"
            ),
        }
    ).getInfo()
    actual_sites = int(result["sites"])
    if actual_sites != payload.sites:
        raise RuntimeError(
            f"Earth Engine read {actual_sites} sites from {payload.name}; "
            f"expected {payload.sites}."
        )
    site_ids = tuple(str(value) for value in result["site_ids"])
    local_ids = tuple(
        str(feature["properties"]["site_id"]) for feature in payload.features
    )
    if len(set(site_ids)) != actual_sites or set(site_ids) != set(local_ids):
        raise RuntimeError(
            f"Earth Engine changed the per-feature site IDs for {payload.name}."
        )
    areas = {
        site_id: (float(actual), float(declared))
        for site_id, actual, declared in zip(
            site_ids,
            result["actual_area_km2"],
            result["declared_area_km2"],
        )
    }
    for site_id, (actual, declared) in areas.items():
        difference = abs(actual - declared) / max(actual, 1e-12)
        if not math.isfinite(actual) or actual <= 0 or difference > 0.01:
            raise RuntimeError(
                f"{site_id} area differs from Earth Engine by "
                f"{100 * difference:.2f}%."
            )
    return replace(payload, area_km2=sum(value[0] for value in areas.values()))


def attach_verified_payload(plan: TaskPlan, payload: Payload) -> TaskPlan:
    if payload.name != plan.payload.name:
        raise ValueError("Verified payload does not match the task plan.")
    work = payload.effective_pixels * plan.band_count
    return replace(plan, payload=payload, effective_pixel_bands=work)


def collection_doys(collection_id: str, year: int) -> tuple[int, ...]:
    collection = ee.ImageCollection(collection_id).filterDate(
        f"{year}-01-01", f"{year + 1}-01-01"
    )
    tagged = collection.map(
        lambda image: image.set(
            "_doy", image.date().getRelative("day", "year").add(1)
        )
    )
    values = tagged.aggregate_array("_doy").getInfo()
    return tuple(sorted(int(value) for value in values))


def verify_sources(plans: Iterable[TaskPlan]) -> None:
    plans = tuple(plans)
    years = sorted({plan.year for plan in plans})
    for year in years:
        expected = {
            ET_COLLECTION: COMPOSITE_DOYS,
            SNOW_COLLECTION: SNOW_DOYS_BY_YEAR.get(year, COMPOSITE_DOYS),
        }
        halves = {plan.half for plan in plans if plan.year == year}
        if "h1" in halves:
            expected[NPP_COLLECTION] = (1,)
            if year <= 2024:
                expected[GREENUP_COLLECTION] = (1,)
        for collection_id, expected_doys in expected.items():
            actual_doys = collection_doys(collection_id, year)
            if actual_doys != expected_doys:
                raise RuntimeError(
                    f"{collection_id} has source DOYs {actual_doys} for {year}; "
                    f"expected {expected_doys}. No task was started."
                )


def source_image(collection_id: str, year: int, doy: int) -> Any:
    start = ee.Date.fromYMD(year, 1, 1).advance(doy - 1, "day")
    return ee.Image(
        ee.ImageCollection(collection_id)
        .filterDate(start, start.advance(1, "day"))
        .first()
    )


def valid_scaled_band(
    image: Any,
    source_band: str,
    minimum: float,
    maximum: float,
    scale: float,
    output_band: str,
) -> Any:
    raw = image.select(source_band)
    valid = raw.gte(minimum).And(raw.lte(maximum))
    return raw.updateMask(valid).multiply(scale).rename(output_band)


def build_task_image(plan: TaskPlan) -> tuple[Any, tuple[str, ...]]:
    images: list[Any] = []
    names: list[str] = []
    snow_doys = set(SNOW_DOYS_BY_YEAR.get(plan.year, COMPOSITE_DOYS))
    for doy in plan.doys:
        if doy in snow_doys:
            snow = source_image(SNOW_COLLECTION, plan.year, doy).select(
                "Eight_Day_Snow_Cover"
            )
            for day_index in range(1, 9):
                name = f"snow_{plan.year}_{doy:03d}_d{day_index}"
                images.append(
                    snow.bitwiseAnd(1 << (day_index - 1)).neq(0).rename(name)
                )
                names.append(name)
        et_name = f"et_{plan.year}_{doy:03d}"
        images.append(
            valid_scaled_band(
                source_image(ET_COLLECTION, plan.year, doy),
                "ET",
                -32767,
                32700,
                0.1,
                et_name,
            )
        )
        names.append(et_name)

    if plan.half == "h1":
        npp_name = f"npp_{plan.year}"
        annual_npp = ee.ImageCollection(NPP_COLLECTION).filterDate(
            f"{plan.year}-01-01", f"{plan.year + 1}-01-01"
        )
        images.append(
            valid_scaled_band(
                ee.Image(annual_npp.first()),
                "Npp",
                -30000,
                32700,
                0.0001,
                npp_name,
            )
        )
        names.append(npp_name)
        if plan.year <= 2024:
            greenup = ee.Image(
                ee.ImageCollection(GREENUP_COLLECTION)
                .filterDate(f"{plan.year}-01-01", f"{plan.year + 1}-01-01")
                .first()
            )
            for cycle, source_band in enumerate(("Greenup_1", "Greenup_2")):
                name = f"greenup{cycle}_{plan.year}"
                images.append(
                    valid_scaled_band(
                        greenup,
                        source_band,
                        11138,
                        32766,
                        1,
                        name,
                    )
                )
                names.append(name)

    if len(images) != plan.band_count:
        raise RuntimeError("Task image band count does not match the task plan.")
    return ee.Image.cat(images), tuple(names)


def first_property(feature: Any, names: tuple[str, ...]) -> Any:
    value = feature.get(names[0])
    for name in names[1:]:
        value = ee.Algorithms.If(
            ee.Algorithms.IsEqual(value, None), feature.get(name), value
        )
    return value


def summary_geometry(feature: Any) -> Any:
    geometry = feature.geometry()
    seed = ee.Number(feature.get("_modis_fallback_seed")).toInt()
    return ee.FeatureCollection.randomPoints(
        geometry,
        1,
        seed,
        1,
    ).first().geometry()


def reduce_feature(image: Any, names: tuple[str, ...], feature: Any) -> Any:
    geometry = feature.geometry()
    fallback_geometry = summary_geometry(feature)
    projection = image.select(0).projection()
    analysis_scale = ee.Number(feature.get("_modis_analysis_scale_m"))
    polygon = image.reduceRegion(
        reducer=ee.Reducer.mean(),
        geometry=geometry,
        scale=analysis_scale,
        crs=projection,
        bestEffort=False,
        maxPixels=10_000_000,
        tileScale=4,
    )
    interior = image.reduceRegion(
        reducer=ee.Reducer.first(),
        geometry=fallback_geometry,
        scale=analysis_scale,
        crs=projection,
        bestEffort=False,
        maxPixels=10_000,
    )
    values_list = []
    polygon_value_count = ee.Number(0)
    interior_fallback_value_count = ee.Number(0)
    missing_value_count = ee.Number(0)
    for name in names:
        polygon_missing = ee.Algorithms.IsEqual(polygon.get(name), None)
        interior_missing = ee.Algorithms.IsEqual(interior.get(name), None)
        values_list.append(
            ee.Algorithms.If(
                polygon_missing,
                interior.get(name),
                polygon.get(name),
            )
        )
        polygon_value_count = polygon_value_count.add(
            ee.Algorithms.If(polygon_missing, 0, 1)
        )
        interior_fallback_value_count = interior_fallback_value_count.add(
            ee.Algorithms.If(
                polygon_missing,
                ee.Algorithms.If(interior_missing, 0, 1),
                0,
            )
        )
        missing_value_count = missing_value_count.add(
            ee.Algorithms.If(
                polygon_missing,
                ee.Algorithms.If(interior_missing, 1, 0),
                0,
            )
        )
    values = ee.Dictionary.fromLists(list(names), values_list)
    metadata = {
        name: first_property(feature, (name,)) for name in METADATA_PROPERTIES
    }
    method = ee.Algorithms.If(
        analysis_scale.lte(ANALYSIS_SCALE_M),
        "fractional_polygon_mean_native_500m_interior_fallback_v3",
        "fractional_polygon_mean_bounded_scale_interior_fallback_v3",
    )
    return (
        ee.Feature(fallback_geometry, metadata)
        .set(values)
        .set("analysis_scale_m", analysis_scale)
        .set("extraction_method", method)
        .set("requested_value_count", len(names))
        .set("polygon_value_count", polygon_value_count)
        .set(
            "interior_fallback_value_count",
            interior_fallback_value_count,
        )
        .set("missing_value_count", missing_value_count)
        .set(
            "value_coverage_fraction",
            polygon_value_count.add(interior_fallback_value_count).divide(
                len(names)
            ),
        )
        .set(
            "interior_fallback_used",
            interior_fallback_value_count.gt(0),
        )
    )


def make_export_task(plan: TaskPlan) -> Any:
    image, names = build_task_image(plan)
    watersheds = geojson_feature_collection(plan.payload)
    table = watersheds.map(lambda feature: reduce_feature(image, names, feature))
    table = table.map(
        lambda feature: feature.set(
            {
                "year": plan.year,
                "half": plan.half,
                "spatial_pixel_cap": DEFAULT_SPATIAL_PIXEL_CAP,
                "source_et": ET_COLLECTION,
                "source_snow": SNOW_COLLECTION,
                "source_npp": NPP_COLLECTION,
                "source_greenup": GREENUP_COLLECTION,
                "extraction_version": EXTRACTION_VERSION,
            }
        )
    )
    return ee.batch.Export.table.toAsset(
        collection=table,
        description=plan.description,
        assetId=plan.asset_id,
    )


def run_self_test() -> None:
    geometry_marker = object()
    point_marker = object()

    class GeometryProbe:
        pass

    class FeatureProbe:
        def geometry(self) -> GeometryProbe:
            return geometry_marker

        def get(self, name: str) -> int:
            assert name == "_modis_fallback_seed"
            return 123

    class NumberProbe:
        def __init__(self, value: int):
            assert value == 123

        def toInt(self) -> int:
            return 123

    class PointFeatureProbe:
        def geometry(self) -> object:
            return point_marker

    class PointCollectionProbe:
        def first(self) -> PointFeatureProbe:
            return PointFeatureProbe()

    class FeatureCollectionProbe:
        @staticmethod
        def randomPoints(
            region: object,
            points: int,
            seed: int,
            max_error: int,
        ) -> PointCollectionProbe:
            assert region is geometry_marker
            assert points == 1
            assert seed == 123
            assert max_error == 1
            return PointCollectionProbe()

    class EarthEngineProbe:
        Number = NumberProbe
        FeatureCollection = FeatureCollectionProbe

    engine = globals()["ee"]
    globals()["ee"] = EarthEngineProbe
    try:
        assert summary_geometry(FeatureProbe()) is point_marker
    finally:
        globals()["ee"] = engine
    assert fallback_seed("example_site") == fallback_seed("example_site")
    assert 0 <= fallback_seed("example_site") < 2_147_483_647
    assert EXTRACTION_VERSION.endswith("_v3")

    with tempfile.TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        payload_path = root / "payload.geojson"
        properties = {name: f"test_{name}" for name in METADATA_PROPERTIES}
        payload_path.write_text(
            json.dumps(
                {
                    "type": "FeatureCollection",
                    "features": [
                        {
                            "type": "Feature",
                            "properties": {
                                **properties,
                                "polygon_area_km2": 100,
                            },
                            "geometry": {
                                "type": "Polygon",
                                "coordinates": [
                                    [[0, 0], [1, 0], [1, 1], [0, 0]]
                                ],
                            },
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        list_path = root / "payload_list.csv"
        list_path.write_text(
            "payload,path,sites,polygon_area_km2_sum\n"
            "modis_01,payload.geojson,1,100\n",
            encoding="utf-8",
        )
        payloads = rebatch_payloads(
            load_payload_list(list_path),
            pixel_cap=DEFAULT_SPATIAL_PIXEL_CAP,
            maximum_payload_mb=DEFAULT_PAYLOAD_MEGABYTES,
        )
        ids = validate_site_coverage(
            payload_site_ids(payloads), expected_count=1, expected_ids=None
        )
        assert len(ids) == 1
        prepared = payloads[0].features[0]["properties"]
        assert prepared["_modis_fallback_seed"] == fallback_seed(
            prepared["site_id"]
        )
        plans = plan_tasks(
            payloads=payloads,
            years=(2001, 2016, 2022, 2025),
            halves=("h1", "h2"),
            run_label="test",
            output_folder="projects/test/assets/modis",
        )
        assert len(plans) == 8
        counts = {(plan.year, plan.half): plan.band_count for plan in plans}
        assert counts[(2001, "h1")] == 194
        assert counts[(2001, "h2")] == 207
        assert counts[(2016, "h1")] == 202
        assert counts[(2022, "h2")] == 199
        assert counts[(2025, "h1")] == 208
        assert len(workload_fingerprint(plans)) == 64
    print("MODIS parity launcher self-test passed.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--payload-list", type=Path, action="append")
    parser.add_argument("--output-folder")
    parser.add_argument("--run-label")
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--years", default="2001:2025")
    parser.add_argument("--halves", default="h1,h2")
    parser.add_argument("--expected-site-count", type=int, default=151)
    parser.add_argument("--expected-site-ids", type=Path, action="append")
    parser.add_argument(
        "--maximum-payload-mb",
        type=float,
        default=DEFAULT_PAYLOAD_MEGABYTES,
    )
    parser.add_argument("--max-new-tasks", type=int, default=1)
    parser.add_argument("--check-existing", action="store_true")
    parser.add_argument("--check-sources", action="store_true")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--preflight-receipt", type=Path)
    parser.add_argument(
        "--receipt-output",
        type=Path,
        default=Path("generated_outputs/gee_preflight/modis_parity.json"),
    )
    parser.add_argument("--monthly-stop-eecu-hours", type=float, default=800)
    parser.add_argument("--watchdog-cancel-eecu-hours", type=float, default=0.005)
    args = parser.parse_args()
    if args.self_test:
        return args
    for name in ("payload_list", "output_folder", "run_label"):
        if getattr(args, name) in (None, ""):
            parser.error(f"--{name.replace('_', '-')} is required.")
    if not LABEL_PATTERN.fullmatch(args.run_label):
        parser.error("--run-label may contain lowercase letters, numbers, and _.")
    try:
        args.years = parse_integer_selection(args.years, 2001, 2025)
        args.halves = parse_halves(args.halves)
    except ValueError as exc:
        parser.error(str(exc))
    if args.max_new_tasks < 1 or args.max_new_tasks > MAX_TASKS_PER_LAUNCH:
        parser.error(
            f"--max-new-tasks must be between 1 and {MAX_TASKS_PER_LAUNCH}."
        )
    if args.expected_site_count < 1:
        parser.error("--expected-site-count must be positive.")
    if args.monthly_stop_eecu_hours <= 0:
        parser.error("--monthly-stop-eecu-hours must be positive.")
    if args.watchdog_cancel_eecu_hours <= 0:
        parser.error("--watchdog-cancel-eecu-hours must be positive.")
    if args.maximum_payload_mb <= 0:
        parser.error("--maximum-payload-mb must be positive.")
    if args.submit and args.preflight_receipt is None:
        parser.error("--submit requires --preflight-receipt.")
    return args


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    source_payloads = [
        payload
        for path in args.payload_list
        for payload in load_payload_list(path)
    ]
    source_site_ids = payload_site_ids(source_payloads)
    expected_alias_rows = None
    expected_ids = None
    if args.expected_site_ids is not None:
        expected_parts = [
            read_expected_site_ids(path) for path in args.expected_site_ids
        ]
        expected_alias_rows = sum(part[0] for part in expected_parts)
        combined_expected = tuple(
            site_id for part in expected_parts for site_id in part[1]
        )
        if len(combined_expected) != len(set(combined_expected)):
            raise ValueError("Expected site files contain a repeated site_id.")
        expected_ids = tuple(sorted(combined_expected))
    site_ids = validate_site_coverage(
        source_site_ids,
        expected_count=args.expected_site_count,
        expected_ids=expected_ids,
    )
    payloads = rebatch_payloads(
        source_payloads,
        pixel_cap=DEFAULT_SPATIAL_PIXEL_CAP,
        maximum_payload_mb=args.maximum_payload_mb,
    )
    print(
        f"Verified payload coverage: {len(site_ids)} unique site IDs"
        + (
            f" covering {expected_alias_rows} site/alias rows."
            if expected_alias_rows is not None
            else "."
        )
    )
    native_sites = sum(
        1
        for payload in payloads
        for feature in payload.features
        if float(feature["properties"]["_modis_analysis_scale_m"])
        <= ANALYSIS_SCALE_M
    )
    print(
        f"Built {len(payloads)} in-memory task payloads; "
        f"native 500 m for {native_sites} "
        "sites and bounded scale for the rest."
    )
    all_plans = plan_tasks(
        payloads=payloads,
        years=args.years,
        halves=args.halves,
        run_label=args.run_label,
        output_folder=args.output_folder,
    )
    missing = all_plans
    used_earth_engine = args.check_existing or args.check_sources or args.submit
    if used_earth_engine:
        require_earth_engine(args.project)
    if args.check_existing or args.submit:
        folder = ee.data.getAsset(args.output_folder.rstrip("/"))
        if str(folder.get("type", "")).upper() != "FOLDER":
            raise RuntimeError("--output-folder must be an existing folder asset.")
        existing = child_asset_ids(args.output_folder.rstrip("/"))
        active = active_descriptions()
        missing = [
            plan
            for plan in all_plans
            if plan.asset_id not in existing and plan.description not in active
        ]
    if args.check_sources:
        verify_sources(all_plans)
        print("Verified requested MODIS source years in Earth Engine.")

    launch_plan = missing[: args.max_new_tasks]
    if not launch_plan:
        print("No missing tasks remain; nothing was submitted.")
        return 0
    unsafe = [
        plan
        for plan in launch_plan
        if plan.effective_pixel_bands > MAX_EFFECTIVE_PIXELS_PER_TASK
    ]
    if unsafe:
        worst = unsafe[0]
        raise RuntimeError(
            f"{worst.description} estimates {worst.effective_pixel_bands:,.0f} "
            f"pixel-band operations, above the hard "
            f"{MAX_EFFECTIVE_PIXELS_PER_TASK:,} limit. Rebuild the payload list."
        )
    print_plan(launch_plan, len(missing))
    print("Required preflight command:")
    print(
        "  "
        + preflight_command(
            project=args.project,
            plans=launch_plan,
            receipt=args.receipt_output,
            monthly_stop_hours=args.monthly_stop_eecu_hours,
            watchdog_hours=args.watchdog_cancel_eecu_hours,
        )
    )
    if not args.submit:
        if used_earth_engine:
            print("Read-only Earth Engine checks complete. No task was submitted.")
        else:
            print("Local dry run complete. Earth Engine was not contacted.")
        return 0

    verified_payloads = {
        plan.payload.name: verify_payload_geometry(plan.payload)
        for plan in launch_plan
    }
    verified_plan = [
        attach_verified_payload(plan, verified_payloads[plan.payload.name])
        for plan in launch_plan
    ]
    verified_unsafe = [
        plan
        for plan in verified_plan
        if plan.effective_pixel_bands > MAX_EFFECTIVE_PIXELS_PER_TASK
    ]
    if verified_unsafe:
        raise RuntimeError(
            f"Earth Engine geometry raises {verified_unsafe[0].description} above "
            "the hard task-size limit. No task was started."
        )
    verify_sources(launch_plan)
    tasks = [make_export_task(plan) for plan in launch_plan]
    consume_receipt(args.preflight_receipt, launch_plan, args.project)
    for task in tasks:
        task.start()
        print(f"Started {task.id}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"SAFE MODIS ERROR: {exc}", file=sys.stderr)
        raise
