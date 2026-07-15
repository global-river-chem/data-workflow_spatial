"""Build station-specific watersheds from HydroSHEDS level-12 basins"""

from __future__ import annotations


HYDROBASINS_LEVEL_12 = "WWF/HydroSHEDS/v1/Basins/hybas_12"


def _upstream_ids(basins, target_id: int, main_basin_id: int) -> list[int]:
    import ee

    rows = (
        basins.filter(ee.Filter.eq("MAIN_BAS", main_basin_id))
        .reduceColumns(ee.Reducer.toList(2), ["HYBAS_ID", "NEXT_DOWN"])
        .get("list")
        .getInfo()
    )

    direct_upstream: dict[int, list[int]] = {}
    for basin_id, next_down in rows:
        direct_upstream.setdefault(int(next_down), []).append(int(basin_id))

    selected = {int(target_id)}
    to_check = [int(target_id)]
    while to_check:
        current = to_check.pop()
        for basin_id in direct_upstream.get(current, []):
            if basin_id not in selected:
                selected.add(basin_id)
                to_check.append(basin_id)

    return sorted(selected)


def derive_hydrosheds_watershed(
    latitude: float,
    longitude: float,
    site_id: str,
    simplify_m: int = 1000,
):
    import ee

    basins = ee.FeatureCollection(HYDROBASINS_LEVEL_12)
    point = ee.Geometry.Point([longitude, latitude])
    target = basins.filterBounds(point).first()
    target_info = target.toDictionary(["HYBAS_ID", "MAIN_BAS", "UP_AREA"]).getInfo()

    target_id = int(target_info["HYBAS_ID"])
    main_basin_id = int(target_info["MAIN_BAS"])
    upstream_ids = _upstream_ids(basins, target_id, main_basin_id)

    geometry = (
        basins.filter(ee.Filter.inList("HYBAS_ID", upstream_ids))
        .geometry(simplify_m)
        .dissolve(simplify_m)
        .simplify(simplify_m)
    )

    return ee.Feature(
        geometry,
        {
            "site_id": site_id,
            "hydrosheds_id": str(target_id),
            "hydrosheds_up_area_km2": target_info["UP_AREA"],
            "source_type": "hydrosheds_upstream_union",
        },
    )
