from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError:
    yaml = None


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.gee_spatial.runs import build_run_list


DEFAULT_CONCURRENT_BATCH_TASKS = 2
READY_QUEUE_LIMIT = 3000


def load_yaml(path: Path) -> dict[str, Any]:
    if yaml is None:
        return parse_simple_yaml(path)

    with path.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle) or {}


def parse_simple_yaml(path: Path) -> dict[str, Any]:
    lines = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        lines.append((len(raw_line) - len(raw_line.lstrip(" ")), raw_line.strip()))

    parsed, _ = parse_yaml_block(lines, 0, lines[0][0] if lines else 0)
    return parsed or {}


def parse_yaml_block(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    if index >= len(lines):
        return {}, index

    if lines[index][1].startswith("- "):
        return parse_yaml_list(lines, index, indent)

    return parse_yaml_dict(lines, index, indent)


def parse_yaml_dict(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[dict[str, Any], int]:
    values = {}

    while index < len(lines):
        line_indent, text = lines[index]
        if line_indent < indent or text.startswith("- "):
            break
        if line_indent > indent:
            index += 1
            continue

        key, raw_value = text.split(":", 1)
        raw_value = raw_value.strip()
        index += 1

        if raw_value:
            values[key] = parse_scalar(raw_value)
        elif index < len(lines) and lines[index][0] > line_indent:
            values[key], index = parse_yaml_block(lines, index, lines[index][0])
        else:
            values[key] = None

    return values, index


def parse_yaml_list(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[list[Any], int]:
    values = []

    while index < len(lines):
        line_indent, text = lines[index]
        if line_indent != indent or not text.startswith("- "):
            break

        item = text[2:].strip()
        index += 1

        if item:
            values.append(parse_scalar(item))
        elif index < len(lines) and lines[index][0] > line_indent:
            value, index = parse_yaml_block(lines, index, lines[index][0])
            values.append(value)
        else:
            values.append(None)

    return values, index


def parse_scalar(value: str) -> Any:
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value in {"null", "None", ""}:
        return None

    try:
        return int(value)
    except ValueError:
        pass

    try:
        return float(value)
    except ValueError:
        return value


def first_existing_column(fieldnames: list[str], candidates: list[str]) -> str:
    for candidate in candidates:
        if candidate in fieldnames:
            return candidate

    raise ValueError(f"Could not find any of these columns: {candidates}")


def load_group_counts(geometry_check_path: Path, preferred_column: str) -> Counter:
    if not geometry_check_path.exists():
        raise FileNotFoundError(f"Geometry check file not found: {geometry_check_path}")

    with geometry_check_path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise ValueError(f"Geometry check file has no header row: {geometry_check_path}")

        group_column = first_existing_column(
            reader.fieldnames,
            [preferred_column, "run_group", "run_grp"],
        )
        counts = Counter(row[group_column] for row in reader if row.get(group_column))

    if not counts:
        raise ValueError(f"No run groups found in {geometry_check_path}")

    return counts


def months_in_row(row: dict[str, Any]) -> int:
    if row.get("period") != "monthly_by_year":
        return 1

    months = row.get("months")
    if not months or months == "all":
        return 12

    return len(months)


def estimate_output_rows(run_rows: list[dict[str, Any]], group_counts: Counter) -> int:
    total = 0
    for row in run_rows:
        total += group_counts[row["run_group"]] * months_in_row(row)

    return total


def run_product_count(run_settings: dict[str, Any]) -> int:
    if run_settings.get("mode") == "era5_land":
        return len(run_settings.get("products") or [])

    products = run_settings.get("products")
    if products:
        return len(products)

    return 1 if run_settings.get("product") else 0


def format_hours(tasks: int, minutes_per_task: float | None) -> str:
    waves = math.ceil(tasks / DEFAULT_CONCURRENT_BATCH_TASKS)

    if minutes_per_task is None:
        return f"{waves:,} two-task waves"

    hours = waves * minutes_per_task / 60
    return f"{waves:,} two-task waves, about {hours:,.1f} hours at {minutes_per_task:g} min/task"


def describe_run(
    run_name: str,
    run_config: dict[str, Any],
    group_counts: Counter,
    minutes_per_task: float | None,
) -> dict[str, Any]:
    run_rows = build_run_list(run_config, sorted(group_counts), active_run_name=run_name)
    run_settings = (run_config.get("runs") or {})[run_name]
    tasks = len(run_rows)
    output_rows = estimate_output_rows(run_rows, group_counts)

    return {
        "run_name": run_name,
        "mode": run_settings.get("mode", "single_product"),
        "timing": run_settings.get("timing", "annual"),
        "years": year_span(run_settings),
        "products": run_product_count(run_settings),
        "tasks": tasks,
        "output_rows": output_rows,
        "launch_export": bool(run_settings.get("launch_export", False)),
        "time_note": format_hours(tasks, minutes_per_task),
        "queue_note": "split before queuing" if tasks > READY_QUEUE_LIMIT else "",
    }


def year_span(run_settings: dict[str, Any]) -> str:
    if run_settings.get("timing") == "static":
        return "static"

    start_year = run_settings.get("start_year")
    end_year = run_settings.get("end_year")
    if start_year == end_year:
        return str(start_year)

    return f"{start_year}-{end_year}"


def print_table(rows: list[dict[str, Any]]) -> None:
    headers = [
        "run_name",
        "mode",
        "timing",
        "years",
        "products",
        "tasks",
        "output_rows",
        "launch_export",
        "time_note",
        "queue_note",
    ]
    widths = {
        header: max(len(header), *(len(str(row[header])) for row in rows))
        for header in headers
    }

    print("  ".join(header.ljust(widths[header]) for header in headers))
    print("  ".join("-" * widths[header] for header in headers))
    for row in rows:
        print("  ".join(str(row[header]).ljust(widths[header]) for header in headers))


def main() -> None:
    parser = argparse.ArgumentParser(description="Estimate GEE export tasks before launching them")
    parser.add_argument("--run", help="Summarize one run instead of every run in config/run-list.yml")
    parser.add_argument(
        "--minutes-per-task",
        type=float,
        help="Optional observed task runtime to turn the two-task wave count into rough hours",
    )
    args = parser.parse_args()

    run_config = load_yaml(ROOT / "config" / "run-list.yml")
    asset_config = load_yaml(ROOT / "config" / "gee-assets.yml")

    geometry_check = Path(asset_config["watersheds"]["geometry_check"]).expanduser()
    preferred_group_column = run_config.get("site_groups", {}).get("column", "run_group")
    group_counts = load_group_counts(geometry_check, preferred_group_column)

    run_names = list((run_config.get("runs") or {}).keys())
    if args.run:
        if args.run not in run_names:
            raise SystemExit(f"Run not found: {args.run}")
        run_names = [args.run]

    rows = [
        describe_run(
            run_name=run_name,
            run_config=run_config,
            group_counts=group_counts,
            minutes_per_task=args.minutes_per_task,
        )
        for run_name in run_names
    ]

    print(f"Watersheds in geometry check: {sum(group_counts.values()):,}")
    print(f"Run groups: {len(group_counts):,}")
    print(f"Default Earth Engine batch-task concurrency used here: {DEFAULT_CONCURRENT_BATCH_TASKS}")
    print(f"Queue warning threshold used here: {READY_QUEUE_LIMIT:,} ready tasks")
    print()
    print_table(rows)


if __name__ == "__main__":
    main()
