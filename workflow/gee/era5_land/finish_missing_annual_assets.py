"""Finish missing annual ERA5-Land assets in quota-checked batches."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import ee


MISSING_PATTERN = re.compile(
    r"Missing tasks: (?P<missing>\d+); tasks eligible in this launch: (?P<batch>\d+)\."
)
STARTED_PATTERN = re.compile(r"^Started (?P<task>[A-Z0-9]+)$", re.MULTILINE)


def run_command(command: list[str]) -> str:
    result = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError(f"Command failed with exit code {result.returncode}")
    return result.stdout


def checked_task_states(
    task_ids: list[str], status_rows: object
) -> dict[str, str]:
    if not task_ids or len(set(task_ids)) != len(task_ids):
        raise RuntimeError("Expected a non-empty list of distinct task IDs")
    if not isinstance(status_rows, list):
        raise RuntimeError("Earth Engine returned an invalid task-status response")

    state_by_id: dict[str, str] = {}
    for row in status_rows:
        if not isinstance(row, dict):
            raise RuntimeError("Earth Engine returned a malformed task-status row")
        task_id = row.get("id")
        state = row.get("state")
        if not isinstance(task_id, str) or not task_id:
            raise RuntimeError("Earth Engine returned a task status without an ID")
        if not isinstance(state, str) or not state:
            raise RuntimeError(f"Earth Engine returned no state for task {task_id}")
        if task_id in state_by_id:
            raise RuntimeError(
                f"Earth Engine returned duplicate status for task {task_id}"
            )
        state_by_id[task_id] = state

    expected_ids = set(task_ids)
    returned_ids = set(state_by_id)
    if returned_ids != expected_ids:
        missing = sorted(expected_ids - returned_ids)
        unexpected = sorted(returned_ids - expected_ids)
        raise RuntimeError(
            "Earth Engine returned incomplete task status: "
            f"missing={missing}, unexpected={unexpected}"
        )
    return state_by_id


def wait_for_tasks(task_ids: list[str], poll_seconds: int) -> None:
    terminal = {"COMPLETED", "FAILED", "CANCELLED", "CANCEL_REQUESTED"}
    while True:
        status_rows = ee.data.getTaskStatus(task_ids)
        state_by_id = checked_task_states(task_ids, status_rows)
        print("Task states: " + json.dumps(state_by_id, sort_keys=True), flush=True)
        if all(state in terminal for state in state_by_id.values()):
            failed = {
                task_id: state
                for task_id, state in state_by_id.items()
                if state != "COMPLETED"
            }
            if failed:
                raise RuntimeError(
                    "An ERA5-Land task did not complete: " + json.dumps(failed)
                )
            return
        time.sleep(poll_seconds)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-manifest", type=Path, required=True)
    parser.add_argument("--output-folder", required=True)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--years", default="2000:2025")
    parser.add_argument("--expected-site-count", type=int, required=True)
    parser.add_argument("--expected-site-ids", type=Path, required=True)
    parser.add_argument("--project", default="silica-synthesis")
    parser.add_argument("--batch-size", type=int, default=5)
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--max-batches", type=int, default=0)
    parser.add_argument("--receipt-dir", type=Path)
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 5:
        parser.error("--batch-size must be between 1 and 5")
    if args.poll_seconds < 5:
        parser.error("--poll-seconds must be at least 5")
    if args.max_batches < 0:
        parser.error("--max-batches cannot be negative")
    return args


def build_launcher_command(args: argparse.Namespace, launcher: Path) -> list[str]:
    return [
        sys.executable,
        str(launcher),
        "--payload-manifest",
        str(args.payload_manifest),
        "--output-folder",
        args.output_folder,
        "--run-label",
        args.run_label,
        "--project",
        args.project,
        "--period",
        "annual",
        "--years",
        args.years,
        "--expected-site-count",
        str(args.expected_site_count),
        "--expected-site-ids",
        str(args.expected_site_ids),
        "--max-new-tasks",
        str(args.batch_size),
    ]


def main() -> int:
    args = parse_args()
    launcher = Path(__file__).with_name("run_safe_era5_land_exports.py")
    receipt_dir = args.receipt_dir or Path(tempfile.mkdtemp(prefix="era5-finish-"))
    receipt_dir.mkdir(parents=True, exist_ok=True)
    ee.Initialize(project=args.project)

    base_command = build_launcher_command(args, launcher)

    completed_batches = 0
    while args.max_batches == 0 or completed_batches < args.max_batches:
        batch_number = completed_batches + 1
        receipt = receipt_dir / f"batch_{batch_number:02d}_receipt.json"
        task_log = receipt_dir / f"batch_{batch_number:02d}_tasks.json"
        plan_output = run_command(
            base_command + ["--receipt-output", str(receipt)]
        )
        if "No missing tasks remain; nothing was submitted." in plan_output:
            print("All missing ERA5-Land assets are complete.", flush=True)
            return 0
        match = MISSING_PATTERN.search(plan_output)
        if not match:
            raise RuntimeError("Could not read the missing-task plan")
        command_lines = [
            line.strip()
            for line in plan_output.splitlines()
            if line.strip().startswith("Rscript ")
        ]
        if len(command_lines) != 1:
            raise RuntimeError("Could not identify the quota preflight command")
        run_command(shlex.split(command_lines[0]))

        submit_output = run_command(
            base_command
            + [
                "--receipt-output",
                str(receipt),
                "--preflight-receipt",
                str(receipt),
                "--submit",
                "--task-log",
                str(task_log),
            ]
        )
        task_ids = STARTED_PATTERN.findall(submit_output)
        expected_batch = int(match.group("batch"))
        if len(task_ids) != expected_batch:
            raise RuntimeError(
                f"Expected {expected_batch} started tasks; found {len(task_ids)}"
            )
        wait_for_tasks(task_ids, args.poll_seconds)
        completed_batches += 1
        print(f"Completed batch {completed_batches}.", flush=True)

    print("Stopped at --max-batches with missing assets still possible.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
