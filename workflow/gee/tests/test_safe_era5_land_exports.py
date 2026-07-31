"""Pure unit tests for the safe ERA5-Land task planner."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ERA5_ROOT = Path(__file__).resolve().parents[1] / "era5_land"
sys.path.insert(0, str(ERA5_ROOT))

from run_safe_era5_land_exports import (  # noqa: E402
    DEFAULT_PRODUCTS,
    NATIVE_SCALE_M,
    PRODUCTS,
    Payload,
    launch_site_count,
    parse_integer_selection,
    parse_products,
    plan_tasks,
    workload_fingerprint,
)


def payload(name: str, area_km2: float, sites: int = 2) -> Payload:
    return Payload(
        name=name,
        path=Path(f"/{name}.geojson"),
        sites=sites,
        area_km2=area_km2,
        sha256=("a" if name == "small" else "b") * 64,
    )


class ParsingTests(unittest.TestCase):
    def test_integer_ranges_are_inclusive_and_sorted(self) -> None:
        self.assertEqual(parse_integer_selection("3,1:2", 1, 12), (1, 2, 3))

    def test_invalid_month_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_integer_selection("0:2", 1, 12)

    def test_products_are_exact_and_distinct(self) -> None:
        self.assertEqual(parse_products("precip,temp"), ("precip", "temp"))
        with self.assertRaises(ValueError):
            parse_products("precip,precip")
        with self.assertRaises(ValueError):
            parse_products("made_up")


class PlanningTests(unittest.TestCase):
    def test_defaults_are_the_requested_five_bands(self) -> None:
        self.assertEqual(len(DEFAULT_PRODUCTS), 5)
        self.assertNotIn("potential_evap", DEFAULT_PRODUCTS)
        self.assertEqual(PRODUCTS["snow_cover"].daily_scale, 1.0)
        self.assertEqual(PRODUCTS["evapotrans"].daily_scale, -1_000.0)

    def test_largest_month_and_payload_are_first(self) -> None:
        plans = plan_tasks(
            payloads=(payload("small", 10), payload("large", 1_000)),
            years=(2024,),
            months=(2, 3),
            period="daily",
            products=DEFAULT_PRODUCTS,
            run_label="unit",
            output_folder="projects/test/assets/out",
        )
        self.assertEqual(plans[0].payload.name, "large")
        self.assertEqual(plans[0].month, 3)
        expected = 1_000 * 1_000_000 / NATIVE_SCALE_M**2 * 31 * 5
        self.assertAlmostEqual(plans[0].effective_pixel_band_days, expected)

    def test_monthly_tasks_are_also_bounded_to_one_source_month(self) -> None:
        plans = plan_tasks(
            payloads=(payload("small", 10),),
            years=(2024,),
            months=(1, 2),
            period="monthly",
            products=DEFAULT_PRODUCTS,
            run_label="unit",
            output_folder="projects/test/assets/out",
        )
        self.assertEqual(len(plans), 2)
        self.assertEqual({plan.days for plan in plans}, {29, 31})

    def test_fingerprint_changes_with_exact_task_list(self) -> None:
        plans = plan_tasks(
            payloads=(payload("small", 10),),
            years=(2024,),
            months=(1, 2),
            period="daily",
            products=DEFAULT_PRODUCTS,
            run_label="unit",
            output_folder="projects/test/assets/out",
        )
        self.assertNotEqual(
            workload_fingerprint(plans[:1]), workload_fingerprint(plans)
        )

    def test_site_count_does_not_double_count_payload_across_months(self) -> None:
        plans = plan_tasks(
            payloads=(payload("small", 10, sites=7),),
            years=(2024,),
            months=(1, 2),
            period="daily",
            products=DEFAULT_PRODUCTS,
            run_label="unit",
            output_folder="projects/test/assets/out",
        )
        self.assertEqual(launch_site_count(plans), 7)


if __name__ == "__main__":
    unittest.main()
