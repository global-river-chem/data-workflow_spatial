"""Reusable pieces for GEE watershed extractions."""

from __future__ import annotations

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

    return ee.FeatureCollection(asset_id)


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
