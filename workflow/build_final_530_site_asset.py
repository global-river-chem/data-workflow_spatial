#!/usr/bin/env python3
"""Build and verify the final 530-site Earth Engine watershed asset.

The production asset is assembled inside Earth Engine from:

* the proven 497-row ERA5-Land watershed asset; and
* the targeted 33-row recovery asset.

The 497 existing geometries and their area metadata are preserved.  Site IDs
and LTER labels are updated from the locally audited 530-site package so the
three Finnish records are unique and the legacy Swedish label is normalized.
The 33 recovery rows come from the validated targeted recovery table.
"""

from __future__ import annotations

import argparse
import json
import re
import time
import unicodedata
from pathlib import Path

import ee


DEFAULT_INPUT_ROOT = Path(
    "/Users/sidneybush/Library/CloudStorage/Box-Box/Sidney_Bush/SiSyn/"
    "spatial-data-extractions/spatial-data-files/gee/earth-engine-input-files"
)

FULL_METADATA_FIELDS = (
    "site_id",
    "run_group",
    "LTER",
    "Shapefile_Name",
    "Stream_Name",
    "Discharge_File_Name",
    "hydrosheds_used",
    "hydrosheds_id",
    "expected_area_km2",
    "drn_src",
    "polygon_area_km2",
    "tiny_ws",
    "source_type",
    "source_file",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default="silica-synthesis")
    parser.add_argument(
        "--old-asset",
        default=(
            "projects/silica-synthesis/assets/"
            "silica_gee_watersheds_20260706_shapefile"
        ),
    )
    parser.add_argument(
        "--recovery-asset",
        default=(
            "projects/silica-synthesis/assets/"
            "silica_gee_watersheds_targeted_33_20260715"
        ),
    )
    parser.add_argument(
        "--output-asset",
        default=(
            "projects/silica-synthesis/assets/"
            "silica_gee_watersheds_530sites_20260715"
        ),
    )
    parser.add_argument(
        "--archive-folder",
        default="projects/silica-synthesis/assets/archive",
    )
    parser.add_argument(
        "--archive-asset",
        default=(
            "projects/silica-synthesis/assets/archive/"
            "silica_gee_watersheds_20260706_shapefile_497rows_archived_20260716"
        ),
    )
    parser.add_argument(
        "--old-geojson",
        type=Path,
        default=(
            DEFAULT_INPUT_ROOT
            / "20260706-gee-watersheds"
            / "silica_gee_watersheds_20260706.geojson"
        ),
    )
    parser.add_argument(
        "--current-geojson",
        type=Path,
        default=(
            DEFAULT_INPUT_ROOT
            / "20260715-gee-watersheds"
            / "silica_gee_watersheds_20260715.geojson"
        ),
    )
    parser.add_argument("--poll-seconds", type=int, default=10)
    parser.add_argument("--archive-old", action="store_true")
    return parser.parse_args()


def norm_key(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = text.encode("ascii", "ignore").decode().strip().lower()
    return re.sub(r"[^a-z0-9]+", "_", text).strip("_")


def clean_lter(value: object) -> str:
    text = str(value or "").strip()
    if text in {"Swedish Goverment", "Swedish Government"}:
        return "Sweden"
    return text


def site_match_key(feature: dict) -> tuple[str, str, str]:
    properties = feature["properties"]
    return (
        norm_key(clean_lter(properties.get("LTER"))),
        norm_key(properties.get("Shapefile_Name")),
        norm_key(properties.get("Discharge_File_Name")),
    )


def old_lookup_key(properties: dict) -> str:
    return "||".join(
        (
            str(properties["site_id"]),
            str(properties.get("Discharge_File_Name") or ""),
        )
    )


def load_features(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    features = data.get("features") or []
    if not features:
        raise ValueError(f"No features found in {path}")
    return features


def asset_or_none(asset_id: str) -> dict | None:
    try:
        return ee.data.getAsset(asset_id)
    except ee.EEException as exc:
        message = str(exc).lower()
        if (
            "not found" in message
            or "does not exist" in message
            or "404" in message
        ):
            return None
        raise


def wait_for_task(task: ee.batch.Task, poll_seconds: int) -> dict:
    last_state = None
    while True:
        status = task.status()
        state = status.get("state")
        if state != last_state:
            print(f"Task state: {state}", flush=True)
            last_state = state
        if state in {"COMPLETED", "FAILED", "CANCELLED"}:
            if state != "COMPLETED":
                raise RuntimeError(json.dumps(status, indent=2))
            return status
        time.sleep(poll_seconds)


def main() -> None:
    args = parse_args()
    old_features = load_features(args.old_geojson)
    current_features = load_features(args.current_geojson)

    # Match rows by stable source metadata instead of the legacy site ID.  The
    # old package reused one Finnish site ID and used an outdated Swedish LTER
    # label, so site ID alone cannot identify all 497 existing rows.
    current_by_match_key = {site_match_key(f): f for f in current_features}
    old_match_keys = {site_match_key(f) for f in old_features}

    if len(old_features) != 497 or len(old_match_keys) != 497:
        raise ValueError("Expected 497 uniquely matchable rows in the old package")
    if len(current_features) != 530 or len(current_by_match_key) != 530:
        raise ValueError("Expected 530 uniquely matchable rows in the current package")

    # Preserve each existing geometry and its area fields.  Only the site ID
    # and LTER label come from the corrected local package for these rows.
    old_updates: dict[str, dict] = {}
    for old_feature in old_features:
        match_key = site_match_key(old_feature)
        current_feature = current_by_match_key.get(match_key)
        if current_feature is None:
            raise ValueError(f"Old feature has no current match: {match_key}")
        current_properties = current_feature["properties"]
        old_updates[old_lookup_key(old_feature["properties"])] = {
            "site_id": current_properties["site_id"],
            "LTER": current_properties["LTER"],
        }

    # The rows absent from the old package are the 33 targeted recovery sites.
    recovery_features = [
        feature
        for feature in current_features
        if site_match_key(feature) not in old_match_keys
    ]
    if len(recovery_features) != 33:
        raise ValueError(f"Expected 33 recovery features, found {len(recovery_features)}")

    recovery_site_ids = {
        feature["properties"]["site_id"] for feature in recovery_features
    }
    expected_site_ids = {f["properties"]["site_id"] for f in current_features}
    if len(expected_site_ids) != 530:
        raise ValueError("The current package does not contain 530 unique site IDs")

    ee.Initialize(project=args.project)

    output_exists = asset_or_none(args.output_asset) is not None
    active_old_exists = asset_or_none(args.old_asset) is not None
    archived_old_exists = asset_or_none(args.archive_asset) is not None

    if active_old_exists:
        old_source_asset = args.old_asset
    elif archived_old_exists:
        old_source_asset = args.archive_asset
    else:
        raise ValueError(
            "Could not find the 497-row source asset at either its active or "
            "archived path."
        )

    # Check both source assets before starting a server-side export.  This
    # prevents a similarly named staging table from entering production.
    old_collection = ee.FeatureCollection(old_source_asset)
    recovery_collection = ee.FeatureCollection(args.recovery_asset)
    old_rows = old_collection.size().getInfo()
    recovery_rows = recovery_collection.size().getInfo()
    recovery_asset_site_ids = set(
        recovery_collection.aggregate_array("site_id").getInfo()
    )
    if old_rows != 497:
        raise ValueError(f"Expected 497 rows in old asset, found {old_rows}")
    if recovery_rows != 33:
        raise ValueError(f"Expected 33 rows in recovery asset, found {recovery_rows}")
    if recovery_asset_site_ids != recovery_site_ids:
        raise ValueError("Recovery asset site IDs do not match the audited package")

    old_update_dictionary = ee.Dictionary(old_updates)

    # Shapefile uploads shortened several DBF field names.  Rename them to the
    # descriptive names expected by the extraction and QA workflows.
    old_source_fields = (
        "site_id",
        "run_grp",
        "LTER",
        "Shpfl_N",
        "Strm_Nm",
        "Dsc_F_N",
        "hydrshds_s",
        "hydrshds_d",
        "expc__2",
        "drn_src",
        "plyg__2",
        "tiny_ws",
        "src_typ",
        "sorc_fl",
    )
    old_destination_fields = FULL_METADATA_FIELDS

    recovery_source_fields = (
        "site_id",
        "run_grp",
        "LTER",
        "Shpfl_N",
        "Strm_Nm",
        "hydrshds_s",
        "hydrshds_d",
        "expc__2",
        "drn_src",
        "plyg__2",
        "tiny_ws",
        "src_typ",
        "sorc_fl",
    )
    recovery_destination_fields = tuple(
        name for name in FULL_METADATA_FIELDS if name != "Discharge_File_Name"
    )

    def standardize_old(feature):
        discharge_name = ee.String(
            ee.Algorithms.If(feature.get("Dsc_F_N"), feature.get("Dsc_F_N"), "")
        )
        lookup_key = ee.String(feature.get("site_id")).cat("||").cat(discharge_name)
        updates = ee.Dictionary(old_update_dictionary.get(lookup_key))
        return feature.select(
            list(old_source_fields), list(old_destination_fields)
        ).set(
            {
                "site_id": ee.String(updates.get("site_id")),
                "LTER": ee.String(updates.get("LTER")),
            }
        )

    def standardize_recovery(feature):
        # None of the 33 recovery rows has a discharge-file name.  Add the
        # field explicitly so both sides of the merge have the same schema.
        return feature.select(
            list(recovery_source_fields), list(recovery_destination_fields)
        ).set(
            "Discharge_File_Name", ee.String("")
        )

    if output_exists:
        print(f"Production asset already exists; verifying {args.output_asset}")
    else:
        combined = old_collection.map(standardize_old).merge(
            recovery_collection.map(standardize_recovery)
        )
        description = Path(args.output_asset).name
        task = ee.batch.Export.table.toAsset(
            collection=combined,
            description=description,
            assetId=args.output_asset,
        )
        task.start()
        print(f"Started Earth Engine task: {task.id}", flush=True)
        wait_for_task(task, args.poll_seconds)

    # Treat the asset as production-ready only after the complete ID set and
    # metadata schema agree with the audited 530-row local package.
    output = ee.FeatureCollection(args.output_asset)
    output_rows = output.size().getInfo()
    output_site_ids = set(output.aggregate_array("site_id").getInfo())
    output_fields = set(output.first().propertyNames().getInfo())
    missing_fields = set(FULL_METADATA_FIELDS) - output_fields
    if output_rows != 530:
        raise ValueError(f"Output asset has {output_rows} rows, expected 530")
    if output_site_ids != expected_site_ids:
        raise ValueError("Output asset site IDs do not match the audited 530-site package")
    if missing_fields:
        raise ValueError(f"Output asset is missing fields: {sorted(missing_fields)}")

    print(f"Verified output asset: {args.output_asset}")
    print("Rows: 530")
    print("Distinct site IDs: 530")

    if args.archive_old:
        # Archive only after the production checks above pass.  Repeated runs
        # recognize the completed move and verify the archived table in place.
        if active_old_exists:
            if archived_old_exists:
                raise ValueError(
                    f"Archive destination already exists: {args.archive_asset}"
                )
            if asset_or_none(args.archive_folder) is None:
                ee.data.createAsset({"type": "FOLDER"}, args.archive_folder)
            ee.data.renameAsset(args.old_asset, args.archive_asset)
            if asset_or_none(args.old_asset) is not None:
                raise RuntimeError(
                    "The predecessor still exists at its active path after archiving."
                )
            print(f"Archived predecessor: {args.archive_asset}")
        else:
            print(f"Predecessor is already archived: {args.archive_asset}")

        archived_rows = ee.FeatureCollection(args.archive_asset).size().getInfo()
        if archived_rows != 497:
            raise RuntimeError(f"Archived asset has {archived_rows} rows, expected 497")


if __name__ == "__main__":
    main()
