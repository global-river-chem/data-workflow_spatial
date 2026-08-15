"""Run human-impact exports for an exact approved watershed target.

The command starts with a dry run and requires the target asset IDs to match
an existing reviewed site list. This includes changed watersheds while keeping
accepted unchanged sites out of the rerun.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

try:
    import ee
except ImportError:  # Allow --help before Earth Engine is installed.
    ee = None


HELPER_ROOT = Path(__file__).resolve().parents[1]


DEFAULT_PROJECT = os.getenv("SILICA_GEE_PROJECT", "silica-synthesis")
DEFAULT_WORKFLOW_ROOT = os.getenv("SILICA_HUMAN_IMPACT_WORKFLOW_ROOT", "")


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
    ]
    subprocess.run(command, check=True)
SITE_ID_PROPERTY = "site_id"
STATIC_DATASETS = ("dams", "fertilizer", "wastewater")
LABEL_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Check an exact reviewed watershed target and plan human-impact "
            "exports. Nothing is submitted unless --submit and a matching "
            "quota receipt are both provided."
        )
    )
    parser.add_argument(
        "--target-asset",
        required=True,
        help="Earth Engine watershed asset containing the exact rerun target.",
    )
    parser.add_argument(
        "--expected-site-count",
        required=True,
        type=int,
        help="Number of distinct site IDs required in the target asset.",
    )
    parser.add_argument(
        "--expected-site-ids",
        required=True,
        type=Path,
        help="Reviewed CSV with a site_id column, or one-ID-per-line text file.",
    )
    parser.add_argument(
        "--run-label",
        required=True,
        help="Lowercase task label, for example reviewed_new_sites.",
    )
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument(
        "--workflow-root",
        type=Path,
        default=Path(DEFAULT_WORKFLOW_ROOT) if DEFAULT_WORKFLOW_ROOT else None,
        help=(
            "Checkout containing src/gee_spatial and the human-impact config. "
            "Alternatively set SILICA_HUMAN_IMPACT_WORKFLOW_ROOT."
        ),
    )
    parser.add_argument(
        "--output-folder",
        help=(
            "Destination Earth Engine asset folder. The default is derived "
            "from the run label."
        ),
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="Path for the JSON review summary written before submission.",
    )
    parser.add_argument(
        "--only-dataset",
        choices=(*STATIC_DATASETS, "population"),
        help="Limit a smoke test to one dataset.",
    )
    parser.add_argument(
        "--only-year",
        type=int,
        help="With --only-dataset population, limit the plan to one year.",
    )
    parser.add_argument(
        "--submit",
        action="store_true",
        help="Launch the missing exports after the site list passes every check.",
    )
    parser.add_argument(
        "--max-new-tasks",
        type=int,
        default=1,
        help="Maximum new tasks to submit (default: one smoke-test task).",
    )
    parser.add_argument(
        "--preflight-receipt",
        type=Path,
        help="Fresh, approved receipt from gee_quota_preflight.R.",
    )
    args = parser.parse_args()
    if args.workflow_root is None:
        parser.error(
            "--workflow-root is required unless "
            "SILICA_HUMAN_IMPACT_WORKFLOW_ROOT is set."
        )
    if args.max_new_tasks < 1:
        parser.error("--max-new-tasks must be positive.")
    if args.only_year is not None and args.only_dataset != "population":
        parser.error("--only-year requires --only-dataset population.")
    return args


def read_expected_site_ids(path: Path) -> list[str]:
    """Read the reviewed target IDs without changing ID spelling."""
    if not path.exists():
        raise FileNotFoundError(f"Expected site-ID file does not exist: {path}")
    if path.suffix.lower() == ".csv":
        with path.open(newline="", encoding="utf-8-sig") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames or SITE_ID_PROPERTY not in reader.fieldnames:
                raise ValueError(
                    f"Expected CSV must contain a {SITE_ID_PROPERTY!r} column."
                )
            values = [row[SITE_ID_PROPERTY].strip() for row in reader]
    else:
        values = [
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    if not values or any(not value for value in values):
        raise ValueError("Expected site-ID file is empty or contains blank IDs.")
    if len(values) != len(set(values)):
        raise ValueError("Expected site-ID file contains duplicate IDs.")
    return sorted(values)


def feature_collection_ids(
    collection: ee.FeatureCollection,
    label: str,
) -> tuple[int, list[str]]:
    """Return validated site IDs for one watershed collection."""
    row_count = int(collection.size().getInfo())
    raw_ids = collection.aggregate_array(SITE_ID_PROPERTY).getInfo()
    site_ids = [str(value).strip() if value is not None else "" for value in raw_ids]
    if len(site_ids) != row_count:
        raise RuntimeError(
            f"{label} returned {row_count} rows but {len(site_ids)} site IDs."
        )
    if any(not site_id for site_id in site_ids):
        raise RuntimeError(f"{label} contains a blank {SITE_ID_PROPERTY} value.")
    if len(site_ids) != len(set(site_ids)):
        raise RuntimeError(f"{label} contains duplicate {SITE_ID_PROPERTY} values.")
    return row_count, sorted(site_ids)


def human_run_plan(config: dict, available_dataset_years) -> list[dict]:
    """Return the 28 non-GHSL outputs used by the accepted replacement plan."""
    plan = [
        {"dataset": dataset, "year": None}
        for dataset in STATIC_DATASETS
    ]
    plan.extend(
        {"dataset": "population", "year": year}
        for year in range(2000, 2025)
    )
    if len(plan) != 28:
        raise RuntimeError(
            f"Expected 28 non-GHSL human-impact outputs; found {len(plan)}."
        )
    return plan


def asset_or_none(asset_id: str):
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


def active_operations_by_description() -> dict[str, dict]:
    return {
        operation.get("metadata", {}).get("description", ""): operation
        for operation in ee.data.listOperations()
        if not operation.get("done")
        and operation.get("metadata", {}).get("state")
        not in {"CANCELLING", "CANCELLED"}
    }


def output_name(
    dataset: str,
    year: int | None,
    site_count: int,
    run_label: str,
) -> str:
    period = str(year) if year is not None else "static"
    return (
        f"human_impacts_{dataset}_{period}_{site_count}sites_"
        f"{run_label}_watershed_extract"
    )


def write_manifest(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def restore_centroid_geometry(
    collection: ee.FeatureCollection,
    watersheds: ee.FeatureCollection,
) -> ee.FeatureCollection:
    """Attach one small geometry so asset exports retain a spatial reference."""
    def restore(feature):
        watershed = ee.Feature(
            watersheds.filter(
                ee.Filter.eq(SITE_ID_PROPERTY, feature.get(SITE_ID_PROPERTY))
            ).first()
        )
        return ee.Feature(feature).setGeometry(
            watershed.geometry().centroid(maxError=100)
        )

    return collection.map(restore)


def launch(
    plan: Iterable[dict],
    watersheds: ee.FeatureCollection,
    config: dict,
    output_folder: str,
    site_count: int,
    run_label: str,
    extract_human_impact_dataset,
    human_impact_export_columns,
    allowed_descriptions: set[str],
) -> list[dict]:
    """Launch missing tasks and leave completed or active tasks alone."""
    ensure_folder(output_folder)
    active = active_operations_by_description()
    task_rows = []
    for item in plan:
        dataset = item["dataset"]
        year = item["year"]
        name = output_name(dataset, year, site_count, run_label)
        asset_id = f"{output_folder}/{name}"
        if asset_or_none(asset_id) is not None:
            state = "SKIP_COMPLETED"
            task_id = ""
        elif name in active:
            operation = active[name]
            state = operation.get("metadata", {}).get("state", "PENDING")
            task_id = operation.get("name", "").rsplit("/", 1)[-1]
        elif name not in allowed_descriptions:
            state = "DEFERRED_BY_TASK_CAP"
            task_id = ""
        else:
            extracted = extract_human_impact_dataset(
                dataset,
                config,
                watersheds,
                year=year,
                fertilizer_crops=None,
            )
            extracted = restore_centroid_geometry(extracted, watersheds)
            selectors = human_impact_export_columns(config, dataset)
            task = ee.batch.Export.table.toAsset(
                collection=extracted.select(selectors),
                description=name,
                assetId=asset_id,
            )
            task.start()
            state = task.status().get("state", "READY")
            task_id = task.id
        task_rows.append(
            {
                "dataset": dataset,
                "year": year,
                "description": name,
                "asset_id": asset_id,
                "task_id": task_id,
                "state": state,
            }
        )
        state_text = {
            "SKIP_COMPLETED": "Already complete",
            "READY": "Submitted and waiting",
            "RUNNING": "Already running",
            "PENDING": "Already queued",
        }.get(state, state.replace("_", " ").title())
        print(f"{state_text}: {name}", flush=True)
    return task_rows


def main() -> None:
    args = parse_args()
    if ee is None:
        raise SystemExit(
            "Install and authenticate the Earth Engine Python API before "
            "running exports: python3 -m pip install earthengine-api"
        )
    if args.expected_site_count <= 0:
        raise ValueError("--expected-site-count must be greater than zero.")
    if not LABEL_PATTERN.fullmatch(args.run_label):
        raise ValueError(
            "--run-label must contain only lowercase letters, numbers, and underscores."
        )

    workflow_root = args.workflow_root.resolve()
    if not (workflow_root / "src/gee_spatial/human_impacts.py").exists():
        raise FileNotFoundError(
            f"Human-impact workflow source was not found under {workflow_root}."
        )
    sys.path.insert(0, str(workflow_root))
    from src.gee_spatial.human_impacts import (  # noqa: PLC0415
        available_dataset_years,
        extract_human_impact_dataset,
        human_impact_export_columns,
        load_human_impact_config,
    )

    ee.Initialize(project=args.project)
    expected_ids = read_expected_site_ids(args.expected_site_ids)
    if len(expected_ids) != args.expected_site_count:
        raise RuntimeError(
            f"Expected {args.expected_site_count} reviewed IDs but found "
            f"{len(expected_ids)}. Nothing was submitted."
        )
    target_watersheds = ee.FeatureCollection(args.target_asset)
    target_rows, target_ids = feature_collection_ids(
        target_watersheds,
        "Target asset",
    )
    if target_rows != args.expected_site_count or target_ids != expected_ids:
        missing_ids = sorted(set(expected_ids) - set(target_ids))
        unexpected_ids = sorted(set(target_ids) - set(expected_ids))
        raise RuntimeError(
            "Target asset IDs do not match the reviewed target. "
            f"Missing: {missing_ids}; unexpected: {unexpected_ids}. "
            "Nothing was submitted."
        )

    output_folder = args.output_folder or (
        f"projects/{args.project}/assets/human_impacts_incremental_{args.run_label}"
    )
    manifest_path = args.manifest or Path(
        "generated_outputs/gee_task_timing"
    ) / f"human_impacts_incremental_{args.run_label}.json"
    summary = {
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "project": args.project,
        "target_asset": args.target_asset,
        "target_rows": target_rows,
        "expected_site_count": args.expected_site_count,
        "expected_site_ids": str(args.expected_site_ids.resolve()),
        "output_folder": output_folder,
        "run_label": args.run_label,
        "only_dataset": args.only_dataset,
        "only_year": args.only_year,
        "submit_requested": args.submit,
    }
    config = load_human_impact_config(
        workflow_root / "config/human-impact-products.yml"
    )
    plan = human_run_plan(config, available_dataset_years)
    if args.only_dataset:
        plan = [item for item in plan if item["dataset"] == args.only_dataset]
    if args.only_year is not None:
        plan = [item for item in plan if item["year"] == args.only_year]
    if not plan:
        raise RuntimeError("The requested human-impact plan is empty.")
    active = active_operations_by_description()
    missing_plan = []
    for item in plan:
        name = output_name(
            item["dataset"],
            item["year"],
            target_rows,
            args.run_label,
        )
        asset_id = f"{output_folder}/{name}"
        if asset_or_none(asset_id) is None and name not in active:
            missing_plan.append({**item, "description": name})
    launch_plan = missing_plan[: args.max_new_tasks]
    launch_scales = [
        float(
            config["datasets"][item["dataset"]].get(
                "selected_spatial_resolution_m",
                1000,
            )
        )
        for item in launch_plan
    ]
    preflight_scale_m = min(launch_scales, default=1000)
    area_property = "_quota_area_km2"
    area_watersheds = target_watersheds.map(
        lambda feature: feature.set(
            area_property,
            feature.geometry().area(maxError=1).divide(1_000_000),
        )
    )
    max_task_area_km2 = float(
        area_watersheds.aggregate_sum(area_property).getInfo() or 0
    )
    summary["planned_outputs"] = len(plan)
    summary["missing_outputs"] = len(missing_plan)
    summary["max_task_area_km2"] = max_task_area_km2
    summary["preflight_scale_m"] = preflight_scale_m
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
    print(
        f"Missing non-GHSL tasks: {len(missing_plan)}; "
        f"task cap: {args.max_new_tasks}; "
        f"tasks eligible now: {len(launch_plan)}.",
        flush=True,
    )
    if launch_plan:
        print(
            "Required preflight:\n"
            "  Rscript workflow/gee/gee_quota_preflight.R "
            "--workflow human_impacts_incremental "
            "--description-prefix human_impacts_ "
            f"--proposed-task-count {len(launch_plan)} "
            f"--site-count {target_rows} "
            f"--max-task-area-km2 {max_task_area_km2:.6f} "
            f"--scale-m {preflight_scale_m:g} "
            "--receipt generated_outputs/gee_preflight/"
            f"human_impacts_{args.run_label}.json",
            flush=True,
        )
    if not args.submit:
        print("Dry run complete. No Earth Engine tasks were submitted.", flush=True)
        return
    if not launch_plan:
        print("No missing tasks remain; nothing submitted.", flush=True)
        return
    if args.preflight_receipt is None:
        raise RuntimeError(
            "--submit requires --preflight-receipt. Run the printed GEE quota "
            "preflight command immediately before this launcher."
        )
    consume_preflight_receipt(
        args.preflight_receipt,
        project=args.project,
        workflow="human_impacts_incremental",
        description_prefix="human_impacts_",
        proposed_task_count=len(launch_plan),
        site_count=target_rows,
        max_task_area_km2=max_task_area_km2,
        scale_m=preflight_scale_m,
        time_slices_per_task=1,
    )
    allowed_descriptions = {
        str(item["description"]) for item in launch_plan
    }
    task_rows = launch(
        plan,
        target_watersheds,
        config,
        output_folder,
        target_rows,
        args.run_label,
        extract_human_impact_dataset,
        human_impact_export_columns,
        allowed_descriptions,
    )
    task_log = manifest_path.with_name(
        f"human_impacts_incremental_tasks_{args.run_label}.json"
    )
    write_manifest(task_log, {"summary": summary, "tasks": task_rows})
    print(f"Task list saved to: {task_log}", flush=True)


if __name__ == "__main__":
    main()
