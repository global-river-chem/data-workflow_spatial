"""Helpers for timing Earth Engine export tasks."""

from __future__ import annotations

import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DONE_STATES = {"COMPLETED", "FAILED", "CANCELLED"}

TIMING_COLUMNS = [
    "run_name",
    "export_name",
    "task_id",
    "description",
    "mode",
    "product",
    "products",
    "period",
    "year",
    "month",
    "months",
    "run_group",
    "selected_rows",
    "site_period_rows",
    "time_slices",
    "export_destination",
    "launched_at_utc",
    "last_checked_at_utc",
    "finished_at_utc",
    "elapsed_min",
    "state",
    "error_message",
]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def datetime_label(value: datetime) -> str:
    return value.strftime("%Y%m%dT%H%M%SZ")


def iso_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds")


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value)


def clean_list_value(value: Any) -> str:
    if value is None or value == "":
        return ""

    if isinstance(value, list):
        return "|".join(str(item) for item in value)

    return str(value)


def time_slice_count(run_row: dict[str, Any]) -> int:
    if run_row.get("period") != "monthly_by_year":
        return 1

    months = run_row.get("months")
    if not months or months == "all":
        return 12

    return len(months)


def task_timing_row(
    run_row: dict[str, Any],
    export_name: str,
    task,
    selected_rows: int,
    export_destination: str,
    launched_at: datetime | None = None,
) -> dict[str, Any]:
    launched_at = launched_at or utc_now()
    time_slices = time_slice_count(run_row)
    row = {
        "run_name": run_row.get("run_name", ""),
        "export_name": export_name,
        "task_id": "",
        "description": export_name,
        "mode": run_row.get("mode", ""),
        "product": run_row.get("product") or "",
        "products": clean_list_value(run_row.get("products")),
        "period": run_row.get("period", ""),
        "year": run_row.get("year") or "",
        "month": run_row.get("month") or "",
        "months": clean_list_value(run_row.get("months")),
        "run_group": run_row.get("run_group", ""),
        "selected_rows": int(selected_rows),
        "site_period_rows": int(selected_rows) * time_slices,
        "time_slices": time_slices,
        "export_destination": export_destination,
        "launched_at_utc": iso_timestamp(launched_at),
        "last_checked_at_utc": iso_timestamp(launched_at),
        "finished_at_utc": "",
        "elapsed_min": 0,
        "state": "",
        "error_message": "",
    }

    return update_task_timing_row(row, task, checked_at=launched_at)


def update_task_timing_row(
    row: dict[str, Any],
    task,
    checked_at: datetime | None = None,
) -> dict[str, Any]:
    checked_at = checked_at or utc_now()
    status = task.status()
    state = status.get("state", "")
    launched_at = parse_timestamp(row["launched_at_utc"])

    row["task_id"] = status.get("id") or row.get("task_id", "")
    row["description"] = status.get("description") or row.get("description", "")
    row["last_checked_at_utc"] = iso_timestamp(checked_at)
    row["elapsed_min"] = round((checked_at - launched_at).total_seconds() / 60, 2)
    row["state"] = state
    row["error_message"] = status.get("error_message", "")

    if state in DONE_STATES and not row.get("finished_at_utc"):
        row["finished_at_utc"] = iso_timestamp(checked_at)

    return row


def timing_rows_from_launched_tasks(launched_tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [item["timing_row"] for item in launched_tasks]


def write_timing_log(rows: list[dict[str, Any]], path: str | Path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=TIMING_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def print_timing_summary(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("No timing rows to summarize")
        return

    print("\nTiming summary")
    print(f"Tasks tracked: {len(rows)}")

    done_rows = [row for row in rows if row.get("state") in DONE_STATES]
    if not done_rows:
        print("No completed tasks yet")
        return

    elapsed_values = [float(row["elapsed_min"]) for row in done_rows if row.get("elapsed_min") != ""]
    site_period_rows = sum(int(row.get("site_period_rows") or 0) for row in done_rows)
    total_elapsed = sum(elapsed_values)
    print(f"Finished tasks: {len(done_rows)}")
    print(f"Mean elapsed minutes per finished task: {round(total_elapsed / len(elapsed_values), 2)}")
    print(f"Site-period rows in finished tasks: {site_period_rows}")

    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for row in done_rows:
        product_label = row.get("product") or row.get("products") or row.get("mode")
        key = (row.get("mode", ""), product_label, row.get("period", ""))
        groups.setdefault(key, []).append(row)

    for (mode, product_label, period), group_rows in sorted(groups.items()):
        group_elapsed = [float(row["elapsed_min"]) for row in group_rows]
        group_site_period_rows = sum(int(row.get("site_period_rows") or 0) for row in group_rows)
        print(
            json.dumps(
                {
                    "mode": mode,
                    "product": product_label,
                    "period": period,
                    "tasks": len(group_rows),
                    "mean_elapsed_min": round(sum(group_elapsed) / len(group_elapsed), 2),
                    "site_period_rows": group_site_period_rows,
                }
            )
        )
