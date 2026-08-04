"""Pure planning tests for the bounded GLC-FCS30D launcher."""

from __future__ import annotations

import sys
import csv
import hashlib
import json
import unittest
from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory


LAND_COVER_ROOT = Path(__file__).resolve().parents[1] / "land_cover"
sys.path.insert(0, str(LAND_COVER_ROOT))

from run_safe_glc_fcs30d_exports import (  # noqa: E402
    DEFAULT_SAMPLE_POINTS,
    DEFAULT_EXACT_MAX_WORK,
    GLC_CLASSES,
    LocalPointSample,
    YEARS,
    Site,
    canonical_sha256,
    launch_batch,
    load_local_point_samples,
    plan_tasks,
    preflight_dimensions,
    sampling_standard_error,
    stable_seed,
    unsafe_legacy_descriptions,
    workload_fingerprint,
)
from consolidate_safe_glc_fcs30d_exports import validate_asset_rows  # noqa: E402


def site(site_id: str, area_km2: float, coordinate: float = 0) -> Site:
    feature = {
        "type": "Feature",
        "properties": {
            "site_id": site_id,
            "LTER": "TEST",
            "Stream_Name": "Test Stream",
            "Shapefile_Name": "test.shp",
            "polygon_area_km2": area_km2,
        },
        "geometry": {
            "type": "Polygon",
            "coordinates": [
                [
                    [coordinate, 0],
                    [coordinate + 0.1, 0],
                    [coordinate + 0.1, 0.1],
                    [coordinate, 0.1],
                    [coordinate, 0],
                ]
            ],
        },
    }
    return Site(
        site_id=site_id,
        area_km2=area_km2,
        feature=feature,
        feature_sha256=canonical_sha256(feature),
    )


def plans_for(sites: list[Site], method: str = "auto"):
    plans = plan_tasks(
        sites=sites,
        method=method,
        sample_points=DEFAULT_SAMPLE_POINTS,
        exact_max_work=DEFAULT_EXACT_MAX_WORK,
        run_label="unit",
        output_folder="projects/test/assets/glc_safe_unit",
    )
    return [
        replace(
            plan,
            local_point_sample=LocalPointSample(
                site_id=plan.site.site_id,
                path=Path(f"/not-read/{plan.site.site_id}.json"),
                file_sha256=canonical_sha256({"site_id": plan.site.site_id}),
                sample_n=plan.sample_points,
                sampling_seed=plan.sampling_seed,
                sampling_crs="EPSG:6933",
                polygon_area_km2=plan.site.area_km2,
                source_geometry_sha256=canonical_sha256(plan.site.feature["geometry"]),
                bounds=(0, 0, 1, 1),
            ),
        )
        if plan.method == "sample"
        else plan
        for plan in plans
    ]


class PlanningTests(unittest.TestCase):
    def test_full_product_has_26_dates_and_preserves_all_class_codes(self) -> None:
        self.assertEqual(len(YEARS), 26)
        self.assertEqual(YEARS[:4], (1985, 1990, 1995, 2000))
        self.assertEqual(YEARS[-1], 2022)
        self.assertEqual(len(GLC_CLASSES), 37)
        self.assertIn(0, GLC_CLASSES)
        self.assertIn(220, GLC_CLASSES)

    def test_auto_uses_exact_for_small_and_sample_for_large_sites(self) -> None:
        plans = plans_for(
            [site("small", 50), site("amazon", 1_314_834)]
        )
        by_id = {plan.site.site_id: plan for plan in plans}
        self.assertEqual(by_id["small"].method, "exact")
        self.assertEqual(by_id["amazon"].method, "sample")

    def test_large_sampled_work_is_constant_not_area_dependent(self) -> None:
        plans = plans_for(
            [site("large", 100_000), site("enormous", 1_314_834)]
        )
        self.assertEqual(plans[0].effective_pixel_band_time, 2_600_000)
        self.assertEqual(plans[1].effective_pixel_band_time, 2_600_000)

    def test_forced_exact_extraction_of_enormous_site_is_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "hard ceiling"):
            plans_for([site("amazon", 1_314_834)], method="exact")

    def test_sampled_sites_are_smoke_tested_before_exact_sites(self) -> None:
        plans = plans_for([site("small", 50), site("large", 100_000)])
        self.assertEqual(plans[0].method, "sample")
        self.assertEqual(plans[1].method, "exact")
        launch = launch_batch(plans, maximum=5)
        self.assertEqual(len(launch), 1)
        self.assertTrue(all(plan.method == "sample" for plan in launch))

    def test_receipt_prefix_separates_sample_and_exact_histories(self) -> None:
        sample = plans_for([site("large", 100_000)])
        exact = plans_for([site("small", 50)])
        self.assertEqual(
            preflight_dimensions(sample)["description_prefix"], "glcsafe_lps100k_"
        )
        self.assertEqual(
            preflight_dimensions(exact)["description_prefix"], "glcsafe_x_"
        )

    def test_receipt_prefix_separates_sample_sizes(self) -> None:
        default = plans_for([site("large", 100_000)])
        smaller = plan_tasks(
            sites=[site("large", 100_000)],
            method="auto",
            sample_points=10_000,
            exact_max_work=10_000 * len(YEARS),
            run_label="unit",
            output_folder="projects/test/assets/glc_safe_unit",
        )
        smaller = [
            replace(
                smaller[0],
                local_point_sample=LocalPointSample(
                    site_id=smaller[0].site.site_id,
                    path=Path("/not-read/smaller.json"),
                    file_sha256="1" * 64,
                    sample_n=smaller[0].sample_points,
                    sampling_seed=smaller[0].sampling_seed,
                    sampling_crs="EPSG:6933",
                    polygon_area_km2=smaller[0].site.area_km2,
                    source_geometry_sha256="2" * 64,
                    bounds=(0, 0, 1, 1),
                ),
            )
        ]
        self.assertEqual(
            preflight_dimensions(default)["description_prefix"],
            "glcsafe_lps100k_",
        )
        self.assertEqual(
            preflight_dimensions(smaller)["description_prefix"],
            "glcsafe_lps10k_",
        )

    def test_sampled_fingerprint_requires_local_points(self) -> None:
        raw = plan_tasks(
            sites=[site("large", 100_000)],
            method="auto",
            sample_points=10_000,
            exact_max_work=10_000 * len(YEARS),
            run_label="unit",
            output_folder="projects/test/assets/glc_safe_unit",
        )
        with self.assertRaisesRegex(ValueError, "lack local point files"):
            workload_fingerprint(raw)

    def test_local_point_manifest_validates_file_checksum_and_coordinates(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            sample_path = root / "sample.json"
            payload = {
                "schema_version": 1,
                "generator": "local_equal_area_points_v1",
                "site_id": "large",
                "sampling_crs": "EPSG:6933",
                "sampling_seed": stable_seed("large"),
                "requested_sample_n": 2,
                "polygon_area_km2": 100_000,
                "source_geometry_sha256": "a" * 64,
                "bounds": [-1, -2, 3, 4],
                "coordinates": [[-1, -2], [3, 4]],
            }
            sample_path.write_text(json.dumps(payload), encoding="utf-8")
            manifest_path = root / "manifest.csv"
            with manifest_path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=(
                        "site_id",
                        "path",
                        "sample_n",
                        "sampling_seed",
                        "sampling_crs",
                        "polygon_area_km2",
                        "source_geometry_sha256",
                        "file_sha256",
                    ),
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "site_id": "large",
                        "path": sample_path.name,
                        "sample_n": 2,
                        "sampling_seed": stable_seed("large"),
                        "sampling_crs": "EPSG:6933",
                        "polygon_area_km2": 100_000,
                        "source_geometry_sha256": "a" * 64,
                        "file_sha256": hashlib.sha256(
                            sample_path.read_bytes()
                        ).hexdigest(),
                    }
                )
            sample = load_local_point_samples(manifest_path)["large"]
            self.assertEqual(sample.sample_n, 2)
            self.assertEqual(sample.bounds, (-1, -2, 3, 4))

    def test_fingerprint_changes_if_geometry_changes(self) -> None:
        first = plans_for([site("same", 100, coordinate=0)])
        second = plans_for([site("same", 100, coordinate=1)])
        self.assertNotEqual(workload_fingerprint(first), workload_fingerprint(second))

    def test_site_seed_is_stable_and_site_specific(self) -> None:
        self.assertEqual(stable_seed("a"), stable_seed("a"))
        self.assertNotEqual(stable_seed("a"), stable_seed("b"))

    def test_default_sample_has_small_worst_case_uncertainty(self) -> None:
        standard_error = sampling_standard_error(0.5, DEFAULT_SAMPLE_POINTS)
        self.assertAlmostEqual(standard_error, 0.00158113883)
        self.assertLess(1.96 * standard_error, 0.0031)

    def test_unsafe_legacy_other_targets_queue_is_detected(self) -> None:
        found = unsafe_legacy_descriptions(
            {
                "glc_followup_other_targets_2001",
                "glcsafe_s_release_site_hash",
                "unrelated_task",
            }
        )
        self.assertEqual(found, ["glc_followup_other_targets_2001"])


class ConsolidationTests(unittest.TestCase):
    def sampled_rows(self):
        plan = plans_for([site("large", 100_000)])[0]
        polygon_area = plan.site.area_km2 * 1_000_000
        rows = []
        for year in YEARS:
            for class_id in GLC_CLASSES:
                count = DEFAULT_SAMPLE_POINTS if class_id == 0 else 0
                fraction = count / DEFAULT_SAMPLE_POINTS
                rows.append(
                    {
                        "site_id": plan.site.site_id,
                        "Year": year,
                        "LC_ID": class_id,
                        "Area_m2": fraction * polygon_area,
                        "extraction_method": "deterministic_point_sample",
                        "sample_count": count,
                        "sample_n": DEFAULT_SAMPLE_POINTS,
                        "sample_fraction": fraction,
                        "polygon_area_m2": polygon_area,
                    }
                )
        return plan, rows

    def test_complete_sampled_asset_passes_strict_qa(self) -> None:
        plan, rows = self.sampled_rows()
        result = validate_asset_rows(rows, plan)
        self.assertEqual(result["rows"], len(YEARS) * len(GLC_CLASSES))
        self.assertEqual(result["minimum_sample_n"], DEFAULT_SAMPLE_POINTS)

    def test_missing_year_class_key_is_rejected(self) -> None:
        plan, rows = self.sampled_rows()
        with self.assertRaisesRegex(RuntimeError, "rows; expected"):
            validate_asset_rows(rows[:-1], plan)


if __name__ == "__main__":
    unittest.main()
