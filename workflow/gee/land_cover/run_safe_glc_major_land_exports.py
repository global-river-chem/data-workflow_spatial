"""Export the dominant GLC-FCS30D class for each watershed.

The source-year weights reproduce the 1900-2022 harmonized record without
first exporting annual land-cover tables.
"""

from __future__ import annotations

import sys
from typing import Any

import run_safe_glc_fcs30d_exports as glc


MAJOR_SAMPLED_REDUCER_VERSION = "multipoint_frequency_histogram_v2"


ee = glc.ee

# Each weight is the number of years from 1900 through 2022 represented by
# that source map in the harmonized record
YEAR_WEIGHTS = {
    1985: 88,
    1990: 5,
    1995: 5,
    2000: 3,
    **{year: 1 for year in range(2001, 2023)},
}
# These groups match the simplified land-cover crosswalk used in harmonization
SIMPLE_CLASS_IDS = {
    "Bare": (140, 200, 201, 202),
    "Cropland": (10, 11, 12, 20),
    "Forest": (50, 51, 52, 61, 62, 71, 72, 81, 82, 91, 92),
    "Grassland_Shrubland": (120, 121, 122, 130, 150, 152, 153),
    "Ice_Snow": (220,),
    "Impervious": (190,),
    "Open_water": (210,),
    "Tidal_Wetland": (185, 186, 187),
    "Wetland_Marsh": (181, 182, 183),
}
# These classes stay in yearly totals but cannot be selected as major land cover
NON_CANDIDATE_CLASS_IDS = (0, 184)
MAPPED_CLASS_IDS = tuple(
    class_id
    for class_ids in SIMPLE_CLASS_IDS.values()
    for class_id in class_ids
)
TOTAL_TEMPORAL_WEIGHT = sum(YEAR_WEIGHTS.values())

if set(MAPPED_CLASS_IDS) & set(NON_CANDIDATE_CLASS_IDS):
    raise ValueError("Non-candidate GLC classes cannot appear in the crosswalk.")
if set(MAPPED_CLASS_IDS) | set(NON_CANDIDATE_CLASS_IDS) != set(glc.GLC_CLASSES):
    raise ValueError("The major-land crosswalk must account for every GLC class.")


# ---- Land-cover scores ----


def sum_classes(values: Any, class_ids: tuple[int, ...]) -> Any:
    total = ee.Number(0)
    for class_id in class_ids:
        key = str(class_id)
        total = total.add(
            ee.Number(
                ee.Algorithms.If(values.contains(key), values.get(key), 0)
            )
        )
    return total


def weighted_class_scores(
    yearly_values: dict[int, tuple[Any, Any]],
) -> dict[str, tuple[Any, Any]]:
    scores = {}
    for simple_class, class_ids in SIMPLE_CLASS_IDS.items():
        weighted_score = ee.Number(0)
        valid_weight = ee.Number(0)
        for year, weight in YEAR_WEIGHTS.items():
            values, total = yearly_values[year]
            fraction = ee.Number(
                ee.Algorithms.If(
                    ee.Number(total).gt(0),
                    sum_classes(values, class_ids).divide(total),
                    0,
                )
            )
            weighted_score = weighted_score.add(fraction.multiply(weight))
            valid_weight = valid_weight.add(
                ee.Number(ee.Algorithms.If(ee.Number(total).gt(0), weight, 0))
            )
        scores[simple_class] = (weighted_score, valid_weight)
    return scores


def major_output_properties(plan: glc.TaskPlan) -> dict[str, Any]:
    properties = plan.site.feature["properties"]
    result = {
        **{name: properties.get(name) for name in glc.METADATA_PROPERTIES},
        "source": "GLC_FCS30D",
        "major_land_definition": "weighted_mean_1900_2022_equivalent",
        "source_year_weights": ";".join(
            f"{year}:{weight}" for year, weight in YEAR_WEIGHTS.items()
        ),
        "total_temporal_weight": TOTAL_TEMPORAL_WEIGHT,
        "extraction_method": (
            "native_30m_exact"
            if plan.method == "exact"
            else f"deterministic_{glc.SAMPLER_VERSION}"
        ),
        "polygon_area_m2": plan.site.area_km2 * 1_000_000,
        "native_pixel_estimate": plan.native_pixel_estimate,
        "effective_pixel_band_time": plan.effective_pixel_band_time,
        "requested_sample_n": plan.sample_points,
        "sampling_seed": plan.sampling_seed if plan.method == "sample" else -1,
        "glc_geometry_simplified_m": properties.get(
            "glc_geometry_simplified_m"
        ),
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
                "local_point_sampling_crs": (
                    plan.local_point_sample.sampling_crs
                ),
                "sampled_reducer_version": MAJOR_SAMPLED_REDUCER_VERSION,
            }
        )
    return {key: value for key, value in result.items() if value is not None}


def select_major_classes(
    plan: glc.TaskPlan,
    output_geometry: Any,
    scores: dict[str, tuple[Any, Any]],
) -> Any:
    base = ee.Dictionary(major_output_properties(plan))
    features = []
    for simple_class, (weighted_score, valid_weight) in scores.items():
        mean_fraction = ee.Number(
            ee.Algorithms.If(
                ee.Number(valid_weight).gt(0),
                ee.Number(weighted_score).divide(valid_weight),
                0,
            )
        )
        features.append(
            ee.Feature(
                output_geometry,
                base.set("major_land", simple_class)
                .set("major_land_mean_fraction", mean_fraction)
                .set("valid_temporal_weight", valid_weight),
            )
        )

    candidates = ee.FeatureCollection(features)
    maximum = candidates.aggregate_max("major_land_mean_fraction")
    selected = candidates.filter(
        ee.Filter.eq("major_land_mean_fraction", maximum)
    )
    tie_count = selected.size()
    return selected.map(
        lambda feature: feature.set("major_land_tie_count", tie_count).set(
            "major_land_tie_flag",
            ee.Algorithms.If(tie_count.gt(1), "yes", "no"),
        )
    )


# ---- Exact and sampled summaries ----


def build_exact_major_export(plan: glc.TaskPlan) -> Any:
    feature = ee.Feature(plan.site.feature)
    geometry = feature.geometry()
    output_geometry = geometry.centroid(maxError=1)
    image = glc.glc_multiband_image(geometry)
    maximum_pixels = glc.exact_pixel_limit(plan.native_pixel_estimate)
    yearly_values = {}

    for year in YEAR_WEIGHTS:
        grouped = ee.Dictionary(
            ee.Image.pixelArea()
            .rename("area")
            .addBands(image.select(str(year)).rename("land_cover"))
            .reduceRegion(
                reducer=ee.Reducer.sum().group(
                    groupField=1,
                    groupName="LC_ID",
                ),
                geometry=geometry,
                scale=glc.NATIVE_SCALE_M,
                bestEffort=False,
                maxPixels=maximum_pixels,
                tileScale=4,
            )
        )
        lookup = glc.lookup_from_grouped_area(
            grouped.get("groups", ee.List([]))
        )
        total_area = ee.Number(
            ee.Algorithms.If(
                lookup.size().gt(0),
                lookup.values().reduce(ee.Reducer.sum()),
                0,
            )
        )
        yearly_values[year] = (lookup, total_area)

    return select_major_classes(
        plan,
        output_geometry,
        weighted_class_scores(yearly_values),
    )


def build_sample_major_export(plan: glc.TaskPlan) -> Any:
    local_sample = plan.local_point_sample
    if local_sample is None:
        raise ValueError(f"No local point sample for {plan.site.site_id}.")

    value = glc.read_local_point_file(local_sample.path)
    points = ee.Geometry.MultiPoint(value["coordinates"], "EPSG:4326")
    output_geometry = ee.Geometry.Point(value["coordinates"][0], "EPSG:4326")
    image = glc.glc_multiband_image(points)
    histograms = ee.Dictionary(
        image.unmask(-999).reduceRegion(
            reducer=ee.Reducer.frequencyHistogram(),
            geometry=points,
            scale=glc.NATIVE_SCALE_M,
            bestEffort=False,
            maxPixels=local_sample.sample_n * len(glc.YEARS) + 10_000,
            tileScale=4,
        )
    )

    yearly_values = {}
    for year in YEAR_WEIGHTS:
        histogram = ee.Dictionary(histograms.get(str(year), ee.Dictionary({})))
        total_n = ee.Number(
            ee.Algorithms.If(
                histogram.size().gt(0),
                histogram.values().reduce(ee.Reducer.sum()),
                0,
            )
        )
        missing_n = ee.Number(
            ee.Algorithms.If(
                histogram.contains("-999"),
                histogram.get("-999"),
                0,
            )
        )
        yearly_values[year] = (histogram, total_n.subtract(missing_n))

    return select_major_classes(
        plan,
        output_geometry,
        weighted_class_scores(yearly_values),
    )


def make_major_export_task(plan: glc.TaskPlan) -> Any:
    table = (
        build_exact_major_export(plan)
        if plan.method == "exact"
        else build_sample_major_export(plan)
    )
    return ee.batch.Export.table.toAsset(
        collection=table,
        description=plan.description,
        assetId=plan.asset_id,
    )


if __name__ == "__main__":
    try:
        glc.main(
            make_task=make_major_export_task,
            description=__doc__,
            result_kind="major_land",
            status_label="Major-land GLC",
        )
    except Exception as exc:
        print(f"Major-land GLC export failed: {exc}", file=sys.stderr)
        raise
