"""Validate and download a complete safe GLC-FCS30D watershed run."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from pathlib import Path
from typing import Any


try:
    import ee
except ImportError:
    ee = None


from run_safe_glc_fcs30d_exports import (
    DEFAULT_EXACT_MAX_WORK,
    DEFAULT_PROJECT,
    DEFAULT_RUN_ROOT,
    DEFAULT_SAMPLE_POINTS,
    GLC_CLASSES,
    METADATA_PROPERTIES,
    YEARS,
    child_asset_ids,
    load_sites,
    plan_tasks,
)


OUTPUT_COLUMNS = (
    *METADATA_PROPERTIES,
    "Year",
    "source",
    "LC_ID",
    "Area_m2",
    "extraction_method",
    "sample_count",
    "sample_n",
    "sample_fraction",
    "sample_standard_error",
    "requested_sample_n",
    "sampling_seed",
    "polygon_area_m2",
    "native_pixel_estimate",
    "effective_pixel_band_time",
    "glc_geometry_simplified_m",
    "glc_simplification_area_error_pct",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, default=DEFAULT_RUN_ROOT)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--output-folder")
    parser.add_argument("--method", choices=("auto", "exact", "sample"), default="auto")
    parser.add_argument("--sample-points", type=int, default=DEFAULT_SAMPLE_POINTS)
    parser.add_argument("--exact-max-work", type=float, default=DEFAULT_EXACT_MAX_WORK)
    parser.add_argument("--expected-site-count", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--download",
        action="store_true",
        help="Download only if every expected per-site asset is complete.",
    )
    args = parser.parse_args()
    args.manifest = args.manifest or args.run_root / "payload_manifest.csv"
    args.output_folder = args.output_folder or (
        f"projects/{args.project}/assets/glc_fcs30d_safe_{args.run_label}"
    )
    return args


def normalize_row(properties: dict[str, Any]) -> dict[str, Any]:
    row = dict(properties)
    row["site_id"] = str(row.get("site_id", ""))
    row["Year"] = int(row["Year"])
    row["LC_ID"] = int(row["LC_ID"])
    for name in (
        "Area_m2",
        "sample_count",
        "sample_n",
        "sample_fraction",
        "sample_standard_error",
        "requested_sample_n",
        "sampling_seed",
        "polygon_area_m2",
        "native_pixel_estimate",
        "effective_pixel_band_time",
    ):
        row[name] = float(row[name])
    return row


def validate_asset_rows(rows: list[dict[str, Any]], plan: Any) -> dict[str, Any]:
    expected_count = len(YEARS) * len(GLC_CLASSES)
    if len(rows) != expected_count:
        raise RuntimeError(
            f"{plan.asset_id} has {len(rows)} rows; expected {expected_count}."
        )
    keys = [(row["Year"], row["LC_ID"]) for row in rows]
    expected_keys = {(year, class_id) for year in YEARS for class_id in GLC_CLASSES}
    if len(keys) != len(set(keys)) or set(keys) != expected_keys:
        raise RuntimeError(f"Incomplete or duplicate year/class keys in {plan.asset_id}.")
    if {row["site_id"] for row in rows} != {plan.site.site_id}:
        raise RuntimeError(f"Wrong site_id in {plan.asset_id}.")
    expected_method = (
        "native_30m_exact"
        if plan.method == "exact"
        else "deterministic_point_sample"
    )
    if {row.get("extraction_method") for row in rows} != {expected_method}:
        raise RuntimeError(f"Wrong extraction_method in {plan.asset_id}.")

    minimum_sample_n: float | None = None
    maximum_fraction_error = 0.0
    for year in YEARS:
        year_rows = [row for row in rows if row["Year"] == year]
        area_sum = sum(row["Area_m2"] for row in year_rows)
        if not math.isfinite(area_sum) or area_sum <= 0:
            raise RuntimeError(f"Non-positive class area for {plan.site.site_id}, {year}.")
        if plan.method == "sample":
            sample_sizes = {row["sample_n"] for row in year_rows}
            if len(sample_sizes) != 1:
                raise RuntimeError(f"Inconsistent sample_n for {plan.site.site_id}, {year}.")
            sample_n = sample_sizes.pop()
            minimum_sample_n = (
                sample_n
                if minimum_sample_n is None
                else min(minimum_sample_n, sample_n)
            )
            if sample_n < 0.99 * plan.sample_points:
                raise RuntimeError(
                    f"Only {sample_n:,.0f}/{plan.sample_points:,} requested samples "
                    f"were classified for {plan.site.site_id}, {year}."
                )
            count_sum = sum(row["sample_count"] for row in year_rows)
            if not math.isclose(count_sum, sample_n, rel_tol=0, abs_tol=0.5):
                raise RuntimeError(
                    f"Class counts do not sum to sample_n for {plan.site.site_id}, {year}."
                )
            fraction_error = abs(
                sum(row["sample_fraction"] for row in year_rows) - 1
            )
            maximum_fraction_error = max(maximum_fraction_error, fraction_error)
            if fraction_error > 1e-6:
                raise RuntimeError(
                    f"Sample fractions do not sum to one for {plan.site.site_id}, {year}."
                )
            polygon_area = year_rows[0]["polygon_area_m2"]
            if not math.isclose(area_sum, polygon_area, rel_tol=1e-6, abs_tol=1):
                raise RuntimeError(
                    f"Sampled class areas do not sum to watershed area for "
                    f"{plan.site.site_id}, {year}."
                )
    return {
        "site_id": plan.site.site_id,
        "method": plan.method,
        "rows": len(rows),
        "minimum_sample_n": minimum_sample_n,
        "maximum_fraction_sum_error": maximum_fraction_error,
    }


def download_asset(plan: Any) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    response = ee.FeatureCollection(plan.asset_id).getInfo()
    rows = [
        normalize_row(dict(feature.get("properties") or {}))
        for feature in response.get("features", [])
    ]
    return rows, validate_asset_rows(rows, plan)


def main() -> None:
    args = parse_args()
    if ee is None:
        raise RuntimeError(
            "The Earth Engine Python API is required. Install earthengine-api, "
            "authenticate, and rerun."
        )
    sites = load_sites(args.manifest)
    if args.expected_site_count is not None and len(sites) != args.expected_site_count:
        raise RuntimeError(f"Found {len(sites)} sites; expected {args.expected_site_count}.")
    plans = plan_tasks(
        sites=sites,
        method=args.method,
        sample_points=args.sample_points,
        exact_max_work=args.exact_max_work,
        run_label=args.run_label,
        output_folder=args.output_folder,
    )
    ee.Initialize(project=args.project)
    available = child_asset_ids(args.output_folder)
    missing = [plan.asset_id for plan in plans if plan.asset_id not in available]
    status = {
        "expected_assets": len(plans),
        "complete_assets": len(plans) - len(missing),
        "missing_assets": len(missing),
        "expected_sites": len(sites),
        "expected_rows": len(sites) * len(YEARS) * len(GLC_CLASSES),
    }
    print("Safe GLC consolidation status:", json.dumps(status, sort_keys=True))
    if not args.download:
        print("Read-only status complete; use --download only when all assets exist.")
        return
    if missing:
        raise RuntimeError(
            f"Refusing a partial download; {len(missing)} assets are missing.\n"
            + "\n".join(missing[:10])
        )

    all_rows: list[dict[str, Any]] = []
    asset_qa = []
    for index, plan in enumerate(plans, start=1):
        rows, qa = download_asset(plan)
        all_rows.extend(rows)
        asset_qa.append(qa)
        print(f"Downloaded and validated {index}/{len(plans)}: {plan.asset_id}")
    combined_keys = [
        (row["site_id"], row["Year"], row["LC_ID"]) for row in all_rows
    ]
    if len(combined_keys) != len(set(combined_keys)):
        raise RuntimeError("Duplicate site/year/class keys occur across assets.")
    if len(all_rows) != status["expected_rows"]:
        raise RuntimeError("The combined row count is incomplete.")

    output = args.output or (
        args.run_root / f"glc_fcs30d_safe_combined_{args.run_label}.csv"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    all_rows.sort(key=lambda row: (row["site_id"], row["Year"], row["LC_ID"]))
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUTPUT_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(all_rows)
    qa_path = output.with_suffix(".qa.json")
    qa = {
        **status,
        "combined_rows": len(all_rows),
        "output": str(output),
        "assets": asset_qa,
    }
    qa_path.write_text(json.dumps(qa, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("Combined output:", output)
    print("QA receipt:", qa_path)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"SAFE GLC CONSOLIDATION ERROR: {exc}", file=sys.stderr)
        raise
