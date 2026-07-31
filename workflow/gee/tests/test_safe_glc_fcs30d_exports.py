"""Pure planning tests for the bounded GLC-FCS30D launcher."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


LAND_COVER_ROOT = Path(__file__).resolve().parents[1] / "land_cover"
sys.path.insert(0, str(LAND_COVER_ROOT))

from run_safe_glc_fcs30d_exports import (  # noqa: E402
    DEFAULT_SAMPLE_POINTS,
    DEFAULT_EXACT_MAX_WORK,
    GLC_CLASSES,
    YEARS,
    Site,
    canonical_sha256,
    launch_batch,
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
    return plan_tasks(
        sites=sites,
        method=method,
        sample_points=DEFAULT_SAMPLE_POINTS,
        exact_max_work=DEFAULT_EXACT_MAX_WORK,
        run_label="unit",
        output_folder="projects/test/assets/glc_safe_unit",
    )


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
            preflight_dimensions(sample)["description_prefix"], "glcsafe_s_"
        )
        self.assertEqual(
            preflight_dimensions(exact)["description_prefix"], "glcsafe_x_"
        )

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
