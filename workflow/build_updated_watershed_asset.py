"""Update an Earth Engine watershed asset without rebuilding unchanged rows.

The script compares a local baseline GeoJSON with the current local GeoJSON,
preserves unchanged geometries from the baseline Earth Engine asset, and adds
the rows supplied in a checked additions asset. Counts and site IDs are
derived from the two local files rather than embedded in the code.
"""

from __future__ import annotations

import argparse
import json
import re
import time
import unicodedata
from pathlib import Path

import ee


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
    parser = argparse.ArgumentParser(
        description="Merge a baseline watershed asset with checked additions."
    )
    parser.add_argument("--project", required=True)
    parser.add_argument(
        "--base-asset",
        required=True,
        help="Earth Engine asset containing the unchanged baseline rows.",
    )
    parser.add_argument(
        "--additions-asset",
        required=True,
        help="Earth Engine asset containing rows absent from the baseline.",
    )
    parser.add_argument(
        "--output-asset",
        required=True,
    )
    parser.add_argument(
        "--base-geojson",
        type=Path,
        required=True,
        help="Local GeoJSON corresponding to the baseline asset.",
    )
    parser.add_argument(
        "--current-geojson",
        type=Path,
        required=True,
        help="Current local GeoJSON containing the complete expected roster.",
    )
    parser.add_argument("--archive-folder")
    parser.add_argument("--archive-asset")
    parser.add_argument("--poll-seconds", type=int, default=10)
    parser.add_argument("--archive-base", action="store_true")
    args = parser.parse_args()
    if args.archive_base and not (args.archive_folder and args.archive_asset):
        parser.error("--archive-base requires --archive-folder and --archive-asset.")
    return args


def norm_key(value: object) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = text.encode("ascii", "ignore").decode().strip().lower()
    return re.sub(r"[^a-z0-9]+", "_", text).strip("_")


def site_match_key(feature: dict) -> tuple[str, str, str]:
    properties = feature["properties"]
    return (
        norm_key(properties.get("Shapefile_Name")),
        norm_key(properties.get("Discharge_File_Name")),
        norm_key(properties.get("Stream_Name")),
    )


def asset_lookup_key(properties: dict) -> str:
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
    base_features = load_features(args.base_geojson)
    current_features = load_features(args.current_geojson)

    # Match on source labels instead of site_id so corrected IDs can be carried
    # forward without changing an unchanged geometry.
    current_by_match_key = {site_match_key(f): f for f in current_features}
    base_match_keys = {site_match_key(f) for f in base_features}
    base_count = len(base_features)
    current_count = len(current_features)

    if len(base_match_keys) != base_count:
        raise ValueError("Baseline GeoJSON rows are not uniquely matchable")
    if len(current_by_match_key) != current_count:
        raise ValueError("Current GeoJSON rows are not uniquely matchable")
    if current_count < base_count:
        raise ValueError("Current GeoJSON has fewer rows than the baseline")

    base_updates: dict[str, dict] = {}
    for base_feature in base_features:
        match_key = site_match_key(base_feature)
        current_feature = current_by_match_key.get(match_key)
        if current_feature is None:
            raise ValueError(f"Baseline feature has no current match: {match_key}")
        current_properties = current_feature["properties"]
        base_updates[asset_lookup_key(base_feature["properties"])] = {
            "site_id": current_properties["site_id"],
            "LTER": current_properties["LTER"],
        }

    addition_features = [
        feature
        for feature in current_features
        if site_match_key(feature) not in base_match_keys
    ]
    addition_count = current_count - base_count
    if len(addition_features) != addition_count:
        raise ValueError(
            f"Expected {addition_count} additions, found {len(addition_features)}"
        )

    addition_site_ids = {
        feature["properties"]["site_id"] for feature in addition_features
    }
    expected_site_ids = {f["properties"]["site_id"] for f in current_features}
    if len(expected_site_ids) != current_count:
        raise ValueError("The current GeoJSON contains duplicate site IDs")

    ee.Initialize(project=args.project)

    output_exists = asset_or_none(args.output_asset) is not None
    active_base_exists = asset_or_none(args.base_asset) is not None
    archived_base_exists = bool(args.archive_asset) and asset_or_none(args.archive_asset) is not None

    if active_base_exists:
        base_source_asset = args.base_asset
    elif archived_base_exists:
        base_source_asset = args.archive_asset
    else:
        raise ValueError("Could not find the baseline asset.")

    # Check both source assets before starting a server-side export.  This
    # prevents a similarly named staging table from entering production.
    base_collection = ee.FeatureCollection(base_source_asset)
    additions_collection = ee.FeatureCollection(args.additions_asset)
    base_rows = base_collection.size().getInfo()
    additions_rows = additions_collection.size().getInfo()
    additions_asset_site_ids = set(
        additions_collection.aggregate_array("site_id").getInfo()
    )
    if base_rows != base_count:
        raise ValueError(f"Expected {base_count} baseline rows, found {base_rows}")
    if additions_rows != addition_count:
        raise ValueError(f"Expected {addition_count} addition rows, found {additions_rows}")
    if additions_asset_site_ids != addition_site_ids:
        raise ValueError("Additions asset site IDs do not match the current GeoJSON")

    base_update_dictionary = ee.Dictionary(base_updates)

    # Shapefile uploads shortened several DBF field names.  Rename them to the
    # descriptive names expected by the extraction and QA workflows.
    base_source_fields = (
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
    base_destination_fields = FULL_METADATA_FIELDS

    additions_source_fields = (
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
    additions_destination_fields = tuple(
        name for name in FULL_METADATA_FIELDS if name != "Discharge_File_Name"
    )

    def standardize_base(feature):
        discharge_name = ee.String(
            ee.Algorithms.If(feature.get("Dsc_F_N"), feature.get("Dsc_F_N"), "")
        )
        lookup_key = ee.String(feature.get("site_id")).cat("||").cat(discharge_name)
        updates = ee.Dictionary(base_update_dictionary.get(lookup_key))
        return feature.select(
            list(base_source_fields), list(base_destination_fields)
        ).set(
            {
                "site_id": ee.String(updates.get("site_id")),
                "LTER": ee.String(updates.get("LTER")),
            }
        )

    def standardize_addition(feature):
        # Addition uploads may omit the optional discharge-file field.
        return feature.select(
            list(additions_source_fields), list(additions_destination_fields)
        ).set(
            "Discharge_File_Name", ee.String("")
        )

    if output_exists:
        print(f"Production asset already exists; verifying {args.output_asset}")
    else:
        combined = base_collection.map(standardize_base).merge(
            additions_collection.map(standardize_addition)
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

    # Treat the asset as ready only after its IDs and schema match the local file.
    output = ee.FeatureCollection(args.output_asset)
    output_rows = output.size().getInfo()
    output_site_ids = set(output.aggregate_array("site_id").getInfo())
    output_fields = set(output.first().propertyNames().getInfo())
    missing_fields = set(FULL_METADATA_FIELDS) - output_fields
    if output_rows != current_count:
        raise ValueError(
            f"Output asset has {output_rows} rows, expected {current_count}"
        )
    if output_site_ids != expected_site_ids:
        raise ValueError("Output asset site IDs do not match the current GeoJSON")
    if missing_fields:
        raise ValueError(f"Output asset is missing fields: {sorted(missing_fields)}")

    print(f"Verified output asset: {args.output_asset}")
    print(f"Rows: {current_count}")
    print(f"Distinct site IDs: {current_count}")

    if args.archive_base:
        # Archive only after the production checks above pass.  Repeated runs
        # recognize the completed move and verify the archived table in place.
        if active_base_exists:
            if archived_base_exists:
                raise ValueError(
                    f"Archive destination already exists: {args.archive_asset}"
                )
            if asset_or_none(args.archive_folder) is None:
                ee.data.createAsset({"type": "FOLDER"}, args.archive_folder)
            ee.data.renameAsset(args.base_asset, args.archive_asset)
            if asset_or_none(args.base_asset) is not None:
                raise RuntimeError(
                    "The predecessor still exists at its active path after archiving."
                )
            print(f"Archived predecessor: {args.archive_asset}")
        else:
            print(f"Predecessor is already archived: {args.archive_asset}")

        archived_rows = ee.FeatureCollection(args.archive_asset).size().getInfo()
        if archived_rows != base_count:
            raise RuntimeError(
                f"Archived asset has {archived_rows} rows, expected {base_count}"
            )


if __name__ == "__main__":
    main()
