"""Finish missing ERA5-Land assets in quota-checked batches."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
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


# ---- status checks and connection recovery ----


def status_error_kind(error: Exception) -> str | None:
    # inspect the original http error when earth engine wraps it
    current = error
    seen = set()
    status = None
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        response = getattr(current, "resp", None)
        status = getattr(response, "status", None) or status
        current = current.__cause__ or current.__context__

    message = str(error).lower()
    if status == 401 or "not signed up for earth engine" in message:
        return "access"
    if status in {400, 403, 404}:
        return None
    if status in {408, 429, 500, 502, 503, 504}:
        return "temporary"
    if isinstance(error, (ConnectionError, TimeoutError, OSError)):
        return "temporary"
    if any(marker in message for marker in (
        "timed out", "connection reset", "connection aborted",
        "temporarily unavailable", "service unavailable",
        "internal server error", "too many requests", "rate limit",
        "name resolution", "server not found",
    )):
        return "temporary"
    return None


def task_status_with_retries(
    task_ids: list[str], project: str, attempts: int = 6
) -> object:
    refresh_connection = False
    access_errors = 0
    for attempt in range(1, attempts + 1):
        try:
            # reload saved credentials only after an access error
            if refresh_connection:
                ee.Reset()
                ee.Initialize(project=project)
                refresh_connection = False
            rows = ee.data.getTaskStatus(task_ids)
            if attempt > 1:
                print("Earth Engine status checks recovered.", flush=True)
            return rows
        except Exception as error:
            kind = status_error_kind(error)
            if kind is None:
                raise
            if kind == "access":
                access_errors += 1
            if attempt == attempts or access_errors >= 3:
                raise RuntimeError(
                    f"Earth Engine status checks stopped after {attempt} attempts: "
                    f"{error}. Existing exports remain in Earth Engine. "
                    "Check access and connection before resuming."
                ) from error
            refresh_connection = kind == "access"
            delay = min(300, 20 * 2 ** (attempt - 1))
            timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
            print(
                f"{timestamp} Earth Engine status check failed: {error}. "
                f"Retrying in {delay} seconds ({attempt}/{attempts}).",
                flush=True,
            )
            time.sleep(delay)
    raise RuntimeError("Earth Engine status checks returned no response")


def wait_for_tasks(
    task_ids: list[str], poll_seconds: int, project: str = "silica-synthesis"
) -> dict[str, str]:
    terminal = {"COMPLETED", "FAILED", "CANCELLED"}
    previous_states = None
    while True:
        status_rows = task_status_with_retries(task_ids, project)
        state_by_id = checked_task_states(task_ids, status_rows)
        # log changes rather than repeating the same states every poll
        if state_by_id != previous_states:
            timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
            print(
                timestamp + " Task states: " + json.dumps(state_by_id, sort_keys=True),
                flush=True,
            )
            previous_states = state_by_id
        if all(state in terminal for state in state_by_id.values()):
            return {
                task_id: state
                for task_id, state in state_by_id.items()
                if state != "COMPLETED"
            }
        time.sleep(poll_seconds)


def prepare_receipt_dir(parent: Path | None) -> Path:
    if parent is None:
        return Path(tempfile.mkdtemp(prefix="era5-finish-"))
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="run-", dir=parent))


def watchdog_requested_cancellation(receipt: Path) -> bool:
    log_path = Path(str(receipt) + ".watchdog.jsonl")
    if not log_path.exists():
        return False
    for line in log_path.read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("event") == "cancellation_requested":
            return True
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-manifest", type=Path, required=True)
    parser.add_argument("--output-folder", required=True)
    parser.add_argument("--run-label", required=True)
    parser.add_argument("--years", default="2000:2025")
    parser.add_argument("--expected-site-count", type=int, required=True)
    parser.add_argument("--expected-site-ids", type=Path, required=True)
    parser.add_argument("--project", default="silica-synthesis")
    parser.add_argument(
        "--period",
        choices=("annual", "daily", "monthly"),
        default="annual",
    )
    parser.add_argument("--months", default="1:12")
    parser.add_argument("--products")
    parser.add_argument("--spatial-statistics")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--max-batches", type=int, default=1)
    parser.add_argument("--max-batch-retries", type=int, default=0)
    parser.add_argument("--retry-delay-seconds", type=int, default=20)
    parser.add_argument("--receipt-dir", type=Path)
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 5:
        parser.error("--batch-size must be between 1 and 5")
    if args.poll_seconds < 5:
        parser.error("--poll-seconds must be at least 5")
    if args.max_batches < 0:
        parser.error("--max-batches cannot be negative")
    if args.max_batch_retries < 0:
        parser.error("--max-batch-retries cannot be negative")
    if args.retry_delay_seconds < 5:
        parser.error("--retry-delay-seconds must be at least 5")
    return args


def build_launcher_command(args: argparse.Namespace, launcher: Path) -> list[str]:
    command = [
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
        args.period,
        "--years",
        args.years,
        "--months",
        args.months,
        "--expected-site-count",
        str(args.expected_site_count),
        "--expected-site-ids",
        str(args.expected_site_ids),
        "--max-new-tasks",
        str(args.batch_size),
    ]
    if args.products:
        command.extend(["--products", args.products])
    if args.spatial_statistics:
        command.extend(["--spatial-statistics", args.spatial_statistics])
    return command


def main() -> int:
    args = parse_args()
    launcher = Path(__file__).with_name("run_safe_era5_land_exports.py")
    receipt_dir = prepare_receipt_dir(args.receipt_dir)
    ee.Initialize(project=args.project)

    base_command = build_launcher_command(args, launcher)

    completed_batches = 0
    launch_number = 0
    failed_launches = 0
    while args.max_batches == 0 or completed_batches < args.max_batches:
        launch_number += 1
        receipt = receipt_dir / f"launch_{launch_number:04d}_receipt.json"
        task_log = receipt_dir / f"launch_{launch_number:04d}_tasks.json"
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
        failed = wait_for_tasks(task_ids, args.poll_seconds, args.project)
        if failed:
            if watchdog_requested_cancellation(receipt):
                raise RuntimeError(
                    "The Earth Engine cost watchdog cancelled a task; "
                    "the run will not retry it."
                )
            failed_launches += 1
            if failed_launches > args.max_batch_retries:
                raise RuntimeError(
                    "An ERA5-Land task did not complete and the retry limit "
                    "was reached: " + json.dumps(failed, sort_keys=True)
                )
            print(
                "A task failed; replanning missing work after "
                f"{args.retry_delay_seconds} seconds. "
                f"Retry {failed_launches} of {args.max_batch_retries}.",
                flush=True,
            )
            time.sleep(args.retry_delay_seconds)
            continue

        failed_launches = 0
        completed_batches += 1
        print(f"Completed batch {completed_batches}.", flush=True)

    print("Stopped at --max-batches with missing assets still possible.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
