"""GEE watershed summaries for the global human-impact datasets.

Dataset settings live in ``human-impact-products.yml``. The Colab notebook
uses this module to summarize LandScan, GHSL, Global Dam Watch, NPKGRIDS, and
HydroWASTE within every watershed.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Iterable, Optional

import yaml

from src.gee_spatial.extraction import (
    PROPERTY_NAMES,
    get_first_property,
    polygon_area_km2_value,
    reduce_region_value_or_null,
    tiny_watershed_value,
)


HUMAN_IMPACT_METADATA_COLUMNS = [
    "site_id",
    "lter",
    "shapefile_name",
    "stream_name",
    "Q_file_name",
    "run_group",
    "hydrosheds_used",
    "hydrosheds_id",
    "expected_area_km2",
    "drainage_area_source",
    "polygon_area_km2",
    "tiny_watershed",
    "source_type",
    "human_impact_dataset",
    "human_impact_asset_id",
    "period",
    "year",
    "reference_timeframe",
]

SUPPORTED_DATASETS = (
    "population",
    "ghsl_population",
    "dams",
    "fertilizer",
    "wastewater",
)
POPULATION_DATASETS = ("population", "ghsl_population")
# Required for global watershed reductions.
MAX_REDUCE_REGION_PIXELS = 10_000_000_000_000


def load_human_impact_config(path: str | Path) -> Dict[str, Any]:
    """Open the human-impact settings file and check required datasets exist."""

    with Path(path).open(encoding="utf-8") as handle:
        config = yaml.safe_load(handle) or {}

    datasets = config.get("datasets") or {}
    missing = [name for name in SUPPORTED_DATASETS if name not in datasets]
    if missing:
        raise ValueError(f"Human-impact config is missing datasets: {missing}")

    return config


def get_dataset(config: Dict[str, Any], dataset_name: str) -> Dict[str, Any]:
    """Return settings for one named dataset."""
    datasets = config.get("datasets") or {}
    if dataset_name not in datasets:
        raise KeyError(f"Human-impact dataset not found in config: {dataset_name}")
    return datasets[dataset_name]


def human_impact_export_columns(
    config: Dict[str, Any],
    dataset_name: str,
) -> list[str]:
    """List the columns to keep when Earth Engine writes a CSV."""
    dataset = get_dataset(config, dataset_name)
    return [
        *HUMAN_IMPACT_METADATA_COLUMNS,
        *(dataset.get("output_columns") or []),
        "used_fine_scale_fallback",
    ]


def available_dataset_years(
    config: Dict[str, Any],
    dataset_name: str,
) -> list[int]:
    """Return the years or five-year dates configured for one changing dataset."""

    dataset = get_dataset(config, dataset_name)
    if "available_years" in dataset:
        return [int(year) for year in dataset["available_years"]]
    return list(
        range(
            int(dataset["available_start_year"]),
            int(dataset["available_end_year"]) + 1,
        )
    )


def _population_images_for_year(dataset: Dict[str, Any], year: int):
    """Select the source map for one requested year or five-year date."""

    import ee

    collection = ee.ImageCollection(dataset["asset_id"])
    if "year_index_template" in dataset:
        image_index = dataset["year_index_template"].format(year=year)
        return collection.filter(ee.Filter.eq("system:index", image_index))
    return collection.filter(ee.Filter.eq(dataset["year_property"], year))


def _base_properties(
    feature,
    dataset_name: str,
    dataset: Dict[str, Any],
    year: Optional[int] = None,
) -> Dict[str, Any]:
    """Copy watershed identifiers and dataset details into an export row."""
    properties = {
        output_name: get_first_property(feature, source_names)
        for output_name, source_names in PROPERTY_NAMES.items()
    }
    properties["polygon_area_km2"] = polygon_area_km2_value(feature)
    properties["tiny_watershed"] = tiny_watershed_value(feature)
    properties.update(
        {
            "human_impact_dataset": dataset_name,
            "human_impact_asset_id": dataset["asset_id"],
            "period": dataset["temporal_resolution"],
            "year": year if year is not None else "",
            "reference_timeframe": dataset["reference_timeframe"],
        }
    )
    return properties


def _summarize_image_by_watersheds(
    image,
    watersheds,
    reducer,
    scale: float,
    tile_scale: int = 4,
):
    """Calculate a map summary inside each watershed boundary."""

    def summarize_feature(feature):
        values = image.reduceRegion(
            reducer=reducer,
            geometry=feature.geometry(),
            scale=scale,
            tileScale=tile_scale,
            maxPixels=MAX_REDUCE_REGION_PIXELS,
        )
        return feature.set(values)

    return watersheds.map(summarize_feature)


def _fill_missing_values_at_fine_scale(
    summary,
    image,
    output_names: list[str],
    reducer,
    fine_scale: float,
    tile_scale: int = 4,
):
    """Retry blank watershed results at a finer scale, using the same boundary."""

    import ee

    def fill_feature(feature):
        missing_checks = [
            ee.Algorithms.IsEqual(feature.get(output_name), None)
            for output_name in output_names
        ]
        needs_retry = ee.List(missing_checks).contains(True)
        fine_values = ee.Dictionary(
            ee.Algorithms.If(
                needs_retry,
                image.reduceRegion(
                    reducer=reducer,
                    geometry=feature.geometry(),
                    scale=fine_scale,
                    tileScale=tile_scale,
                    maxPixels=MAX_REDUCE_REGION_PIXELS,
                ),
                ee.Dictionary({}),
            )
        )

        fine_lookup = {
            output_name: reduce_region_value_or_null(fine_values, output_name)
            for output_name in output_names
        }
        fallback_succeeded = ee.List(
            [
                ee.Algorithms.If(
                    ee.Algorithms.IsEqual(feature.get(output_name), None),
                    ee.Algorithms.If(
                        ee.Algorithms.IsEqual(fine_lookup[output_name], None),
                        False,
                        True,
                    ),
                    False,
                )
                for output_name in output_names
            ]
        ).contains(True)

        updates = {
            output_name: ee.Algorithms.If(
                ee.Algorithms.IsEqual(feature.get(output_name), None),
                fine_lookup[output_name],
                feature.get(output_name),
            )
            for output_name in output_names
        }
        updates["used_fine_scale_fallback"] = fallback_succeeded
        return feature.set(updates)

    return summary.map(fill_feature)


def _clean_raster_feature(
    feature,
    dataset_name: str,
    dataset: Dict[str, Any],
    output_names: Iterable[str],
    year: Optional[int] = None,
    extra_properties: Optional[Dict[str, Any]] = None,
):
    """Keep only the requested values plus the shared watershed details."""
    import ee

    properties = _base_properties(feature, dataset_name, dataset, year=year)
    for output_name in output_names:
        properties[output_name] = feature.get(output_name)
    properties.update(extra_properties or {})
    properties["used_fine_scale_fallback"] = ee.Algorithms.If(
        ee.Algorithms.IsEqual(feature.get("used_fine_scale_fallback"), None),
        False,
        feature.get("used_fine_scale_fallback"),
    )
    return ee.Feature(None, properties)


def extract_population(
    config: Dict[str, Any],
    watersheds,
    year: int,
    dataset_name: str = "population",
):
    """Extract density and area-derived population for one configured time step."""

    import ee

    dataset = get_dataset(config, dataset_name)
    available_years = available_dataset_years(config, dataset_name)
    if year not in available_years:
        raise ValueError(
            f"{dataset_name} time step {year} is not configured; "
            f"choose from {available_years}."
        )

    yearly = _population_images_for_year(dataset, year)
    reference = ee.Image(yearly.first()).select(dataset["band"])
    projection = reference.projection()
    population_count = (
        yearly.select(dataset["band"])
        .mosaic()
        .setDefaultProjection(projection)
    )

    # Work with density so a finer retry cannot duplicate people in a grid cell.
    native_pixel_area = ee.Image.pixelArea().reproject(projection)
    density_name = dataset["density_output_name"]
    population_density = (
        population_count.divide(native_pixel_area)
        .multiply(1_000_000)
        .rename(density_name)
        .setDefaultProjection(projection)
    )
    coverage_name = dataset["coverage_output_name"]
    population_coverage = (
        population_count.mask()
        .rename(coverage_name)
        .unmask(value=0, sameFootprint=False)
        .setDefaultProjection(projection)
    )
    population_image = ee.Image.cat([population_density, population_coverage])

    summary = _summarize_image_by_watersheds(
        population_image,
        watersheds,
        reducer=ee.Reducer.mean(),
        scale=float(dataset["selected_spatial_resolution_m"]),
    )
    summary = _fill_missing_values_at_fine_scale(
        summary,
        population_image,
        output_names=[density_name, coverage_name],
        reducer=ee.Reducer.mean(),
        fine_scale=float(dataset["fallback_spatial_resolution_m"]),
    )

    def clean_feature(feature):
        density = feature.get(density_name)
        coverage = feature.get(coverage_name)
        area_km2 = polygon_area_km2_value(feature)
        safe_density = ee.Number(
            ee.Algorithms.If(
                ee.Algorithms.IsEqual(density, None),
                0,
                density,
            )
        )
        safe_coverage = ee.Number(
            ee.Algorithms.If(
                ee.Algorithms.IsEqual(coverage, None),
                0,
                coverage,
            )
        )
        total_population = ee.Algorithms.If(
            ee.Algorithms.IsEqual(density, None),
            None,
            safe_density.multiply(area_km2).multiply(safe_coverage),
        )
        cleaned = _clean_raster_feature(
            feature,
            dataset_name,
            dataset,
            output_names=[density_name, coverage_name],
            year=year,
            extra_properties={dataset["total_output_name"]: total_population},
        )
        return cleaned

    return summary.map(clean_feature)


def _valid_rate_image(image, band: str):
    rate = image.select(band)
    return rate.updateMask(rate.gte(0)).toFloat()


def extract_fertilizer(
    config: Dict[str, Any],
    watersheds,
    crops: Optional[list[str]] = None,
):
    """Summarize the NPKGRIDS fertilizer comparison score for each watershed."""

    import ee

    dataset = get_dataset(config, "fertilizer")
    collection = ee.ImageCollection(dataset["asset_id"])
    if crops:
        collection = collection.filter(
            ee.Filter.inList(dataset["crop_property"], crops)
        )

    images = []
    layer_counts: Dict[str, Any] = {}
    output_names = []

    for nutrient, nutrient_config in dataset["nutrients"].items():
        # This is a crop-rate comparison, not total fertilizer mass.
        nutrient_collection = collection.filter(
            ee.Filter.eq(dataset["nutrient_property"], nutrient)
        )
        band = nutrient_config["band"]
        output_name = nutrient_config["output_name"]
        rate_sum = (
            nutrient_collection.map(lambda image, band=band: _valid_rate_image(image, band))
            .sum()
            .rename(output_name)
        )
        images.append(rate_sum)
        output_names.append(output_name)
        layer_counts[nutrient_config["layer_count_name"]] = nutrient_collection.size()

    image = ee.Image.cat(images)
    summary = _summarize_image_by_watersheds(
        image,
        watersheds,
        reducer=ee.Reducer.mean(),
        scale=float(dataset["selected_spatial_resolution_m"]),
    )
    summary = _fill_missing_values_at_fine_scale(
        summary,
        image,
        output_names=output_names,
        reducer=ee.Reducer.mean(),
        fine_scale=float(dataset["fallback_spatial_resolution_m"]),
    )

    return summary.map(
        lambda feature: _clean_raster_feature(
            feature,
            "fertilizer",
            dataset,
            output_names=output_names,
            extra_properties=layer_counts,
        )
    )


def _aggregate_sum_or_zero(collection, field: str):
    import ee

    value = collection.aggregate_sum(field)
    return ee.Number(
        ee.Algorithms.If(
            ee.Algorithms.IsEqual(value, None),
            0,
            value,
        )
    )


def _non_null_count(collection, field: str):
    import ee

    return collection.filter(ee.Filter.notNull([field])).size()


def extract_dams(config: Dict[str, Any], watersheds):
    """Count Global Dam Watch barriers and add their reported capacities."""

    import ee

    dataset = get_dataset(config, "dams")
    barriers = ee.FeatureCollection(dataset["asset_id"])
    capacity_field = dataset["capacity_field"]
    power_field = dataset["hydropower_field"]

    def summarize_feature(feature):
        area_km2 = ee.Number(polygon_area_km2_value(feature))
        inside = barriers.filterBounds(feature.geometry())
        count = inside.size()
        properties = _base_properties(feature, "dams", dataset)
        properties.update(
            {
                "dam_barrier_count": count,
                "dam_barrier_density_per_1000_km2": ee.Number(count)
                .multiply(1000)
                .divide(area_km2),
                "dam_storage_capacity_mcm_total": _aggregate_sum_or_zero(
                    inside, capacity_field
                ),
                "dam_storage_capacity_records": _non_null_count(
                    inside, capacity_field
                ),
                "dam_hydropower_capacity_mw_total": _aggregate_sum_or_zero(
                    inside, power_field
                ),
                "dam_hydropower_capacity_records": _non_null_count(
                    inside, power_field
                ),
                "used_fine_scale_fallback": False,
            }
        )
        return ee.Feature(None, properties)

    return watersheds.map(summarize_feature)


def extract_wastewater(config: Dict[str, Any], watersheds):
    """Count HydroWASTE plants and their reported treatment information."""

    import ee

    dataset = get_dataset(config, "wastewater")
    plants = ee.FeatureCollection(dataset["asset_id"]).filter(
        ee.Filter.inList(dataset["status_field"], dataset["included_statuses"])
    )
    population_field = dataset["population_served_field"]
    discharge_field = dataset["discharge_field"]
    treatment_field = dataset["treatment_level_field"]

    def summarize_feature(feature):
        area_km2 = ee.Number(polygon_area_km2_value(feature))
        inside = plants.filterBounds(feature.geometry())
        count = inside.size()
        primary = inside.filter(ee.Filter.eq(treatment_field, "Primary")).size()
        secondary = inside.filter(ee.Filter.eq(treatment_field, "Secondary")).size()
        advanced = inside.filter(ee.Filter.eq(treatment_field, "Advanced")).size()
        classified = ee.Number(primary).add(secondary).add(advanced)

        properties = _base_properties(feature, "wastewater", dataset)
        properties.update(
            {
                "wastewater_plant_count": count,
                "wastewater_plant_density_per_1000_km2": ee.Number(count)
                .multiply(1000)
                .divide(area_km2),
                "wastewater_population_served_people_total": _aggregate_sum_or_zero(
                    inside, population_field
                ),
                "wastewater_population_served_records": _non_null_count(
                    inside, population_field
                ),
                "wastewater_discharge_m3_day_total": _aggregate_sum_or_zero(
                    inside, discharge_field
                ),
                "wastewater_discharge_records": _non_null_count(
                    inside, discharge_field
                ),
                "wastewater_primary_treatment_count": primary,
                "wastewater_secondary_treatment_count": secondary,
                "wastewater_advanced_treatment_count": advanced,
                "wastewater_other_or_unknown_treatment_count": ee.Number(count).subtract(
                    classified
                ),
                "used_fine_scale_fallback": False,
            }
        )
        return ee.Feature(None, properties)

    return watersheds.map(summarize_feature)


def extract_human_impact_dataset(
    dataset_name: str,
    config: Dict[str, Any],
    watersheds,
    year: Optional[int] = None,
    fertilizer_crops: Optional[list[str]] = None,
):
    """Choose the right summary method for one named dataset."""

    if dataset_name in POPULATION_DATASETS:
        if year is None:
            raise ValueError(f"year is required for the {dataset_name} dataset")
        return extract_population(
            config,
            watersheds,
            year=year,
            dataset_name=dataset_name,
        )
    if year is not None:
        raise ValueError(f"{dataset_name} is static and does not accept year={year}")
    if dataset_name == "dams":
        return extract_dams(config, watersheds)
    if dataset_name == "fertilizer":
        return extract_fertilizer(config, watersheds, crops=fertilizer_crops)
    if dataset_name == "wastewater":
        return extract_wastewater(config, watersheds)
    raise ValueError(
        f"Unsupported human-impact dataset {dataset_name!r}; "
        f"choose from {SUPPORTED_DATASETS}."
    )


def inspect_human_impact_assets(config: Dict[str, Any]) -> Dict[str, Any]:
    """Check source-map fields and dates before launching a large export run."""

    import ee

    report: Dict[str, Any] = {}
    for dataset_name in SUPPORTED_DATASETS:
        dataset = get_dataset(config, dataset_name)
        if dataset["asset_type"] == "feature_collection":
            collection = ee.FeatureCollection(dataset["asset_id"])
            report[dataset_name] = {
                "size": collection.size().getInfo(),
                "properties": collection.first().propertyNames().sort().getInfo(),
            }
            if dataset_name == "wastewater":
                report[dataset_name]["status_counts"] = collection.aggregate_histogram(
                    dataset["status_field"]
                ).getInfo()
                report[dataset_name][
                    "treatment_level_counts"
                ] = collection.aggregate_histogram(
                    dataset["treatment_level_field"]
                ).getInfo()
        else:
            collection = ee.ImageCollection(dataset["asset_id"])
            first = ee.Image(collection.first())
            report[dataset_name] = {
                "size": collection.size().getInfo(),
                "bands": first.bandNames().getInfo(),
                "properties": first.propertyNames().sort().getInfo(),
            }
            if dataset_name in POPULATION_DATASETS:
                if "year_index_template" in dataset:
                    indexes = collection.aggregate_array("system:index").getInfo()
                    year_counts = {}
                    for image_index in indexes:
                        try:
                            year = int(str(image_index).rsplit("-", maxsplit=1)[-1])
                        except ValueError:
                            continue
                        year_counts[str(year)] = year_counts.get(str(year), 0) + 1
                    report[dataset_name]["year_counts"] = year_counts
                else:
                    report[dataset_name]["year_counts"] = collection.aggregate_histogram(
                        dataset["year_property"]
                    ).getInfo()
            if dataset_name == "fertilizer":
                report[dataset_name]["nutrient_counts"] = collection.aggregate_histogram(
                    dataset["nutrient_property"]
                ).getInfo()
                report[dataset_name]["bands_by_nutrient"] = {
                    nutrient: ee.Image(
                        collection.filter(
                            ee.Filter.eq(dataset["nutrient_property"], nutrient)
                        ).first()
                    )
                    .bandNames()
                    .getInfo()
                    for nutrient in dataset["nutrients"]
                }

    return report


def validate_asset_report(
    config: Dict[str, Any],
    report: Dict[str, Any],
) -> None:
    """Stop with a clear message when a source dataset no longer matches settings."""

    errors = []

    for dataset_name in POPULATION_DATASETS:
        population = get_dataset(config, dataset_name)
        if population["band"] not in report[dataset_name]["bands"]:
            errors.append(
                f"{dataset_name} band {population['band']!r} was not found in "
                f"{report[dataset_name]['bands']}."
            )
        observed_population_years = {
            int(float(year))
            for year, count in report[dataset_name]["year_counts"].items()
            if count
        }
        configured_population_years = set(
            available_dataset_years(config, dataset_name)
        )
        missing_population_years = sorted(
            configured_population_years - observed_population_years
        )
        if missing_population_years:
            errors.append(
                f"{dataset_name} collection has no images for configured years: "
                f"{missing_population_years}."
            )

    dams = get_dataset(config, "dams")
    dam_properties = set(report["dams"]["properties"])
    for field in (dams["capacity_field"], dams["hydropower_field"]):
        if field not in dam_properties:
            errors.append(f"GDW field {field!r} was not found.")

    fertilizer = get_dataset(config, "fertilizer")
    for nutrient, nutrient_config in fertilizer["nutrients"].items():
        nutrient_bands = report["fertilizer"]["bands_by_nutrient"][nutrient]
        if nutrient_config["band"] not in nutrient_bands:
            errors.append(
                f"NPKGRIDS band {nutrient_config['band']!r} for {nutrient} "
                f"was not found in {nutrient_bands}."
            )

    wastewater = get_dataset(config, "wastewater")
    wastewater_properties = set(report["wastewater"]["properties"])
    wastewater_fields = (
        wastewater["status_field"],
        wastewater["population_served_field"],
        wastewater["discharge_field"],
        wastewater["treatment_level_field"],
    )
    for field in wastewater_fields:
        if field not in wastewater_properties:
            errors.append(f"HydroWASTE field {field!r} was not found.")

    if errors:
        raise RuntimeError("Human-impact asset audit failed:\n- " + "\n- ".join(errors))
