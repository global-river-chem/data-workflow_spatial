"""Helpers for small, recoverable GEE export runs."""

from __future__ import annotations

from typing import Optional


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
