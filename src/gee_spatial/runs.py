"""Helpers for small, recoverable GEE export runs."""

from __future__ import annotations

from typing import Any, Optional


def choose_property_name(watersheds, preferred: str, alternatives: Optional[list[str]] = None) -> str:
    """Use the expected column name, or a known Earth Engine upload-shortened name"""

    candidates = [preferred] + list(alternatives or [])
    property_names = set(watersheds.first().propertyNames().getInfo())

    for candidate in candidates:
        if candidate in property_names:
            return candidate

    raise ValueError(
        f"None of these columns were found in the watershed asset: {candidates}. "
        f"Available columns are: {sorted(property_names)}"
    )


def filter_watersheds_by_group(watersheds, run_group: Optional[str], run_group_column: str = "run_group"):
    if run_group in {None, "", "all"}:
        return watersheds

    import ee

    return watersheds.filter(ee.Filter.eq(run_group_column, run_group))


def all_run_groups(watersheds, run_group_column: str) -> list[str]:
    groups = watersheds.aggregate_array(run_group_column).distinct().sort().getInfo()
    return [group for group in groups if group not in {None, ""}]


def month_values(months: Any = "all") -> list[int]:
    if months is None or months == "all":
        return list(range(1, 13))

    if isinstance(months, int):
        return [months]

    return [int(month) for month in months]


def run_periods(timing: str, start_year: int | None, end_year: int | None, months: Any = "all") -> list[dict]:
    if timing == "static":
        return [{"year": None, "month": None, "period": "static"}]

    if start_year is None or end_year is None:
        raise ValueError("start_year and end_year are required unless timing is static")

    periods = []
    for year in range(int(start_year), int(end_year) + 1):
        if timing == "annual":
            periods.append({"year": year, "month": None, "period": "annual"})
        elif timing == "monthly":
            for month in month_values(months):
                periods.append({"year": year, "month": month, "period": "monthly"})
        else:
            raise ValueError(f"Unsupported timing: {timing}")

    return periods


def _product_names_for_run(run: dict) -> list[str | None]:
    if run.get("mode") == "era5_land":
        return [None]

    products = run.get("products")
    if products:
        return list(products)

    product = run.get("product")
    if product:
        return [product]

    raise ValueError("Run needs either products or product")


def build_run_list(
    run_config: dict,
    run_groups: list[str],
    active_run_name: Optional[str] = None,
) -> list[dict]:
    runs = run_config.get("runs") or {}
    active_run = active_run_name or run_config.get("active_run")

    if not active_run:
        raise ValueError("Set active_run in config/run-list.yml")

    if active_run not in runs:
        raise KeyError(f"Run not found in config/run-list.yml: {active_run}")

    run = runs[active_run]
    requested_groups = run.get("run_groups", ["all"])
    selected_groups = run_groups if requested_groups is None or requested_groups == "all" else list(requested_groups)
    periods = run_periods(
        timing=run.get("timing", "annual"),
        start_year=run.get("start_year"),
        end_year=run.get("end_year"),
        months=run.get("months", "all"),
    )

    rows = []
    for run_group in selected_groups:
        for period in periods:
            for product in _product_names_for_run(run):
                rows.append(
                    {
                        "run_name": active_run,
                        "mode": run.get("mode", "single_product"),
                        "product": product,
                        "products": run.get("products"),
                        "year": period["year"],
                        "month": period["month"],
                        "period": period["period"],
                        "run_group": run_group,
                    }
                )

    return rows


def run_list_chunk(run_rows: list[dict], start_at: int = 0, max_tasks: Optional[int] = None) -> list[dict]:
    if max_tasks in {None, 0, "all"}:
        return run_rows[int(start_at) :]

    return run_rows[int(start_at) : int(start_at) + int(max_tasks)]


def period_label(year: Optional[int] = None, month: Optional[int] = None, period: Optional[str] = None) -> str:
    if period == "static":
        return "static"

    if year is None:
        raise ValueError("year is required unless period is static")

    if month is None:
        return str(year)

    return f"{year}_{int(month):02d}"


def export_name(
    product: str,
    year: Optional[int] = None,
    month: Optional[int] = None,
    run_group: Optional[str] = None,
    period: Optional[str] = None,
) -> str:
    parts = [product, period_label(year=year, month=month, period=period)]

    if run_group not in {None, "", "all"}:
        parts.append(str(run_group))

    parts.append("watershed_extract")
    return "_".join(parts)
