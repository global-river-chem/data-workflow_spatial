"""Small local checks for exported GEE CSV files."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

import pandas as pd


def csv_summary(path: str | Path) -> Dict[str, Any]:
    csv_path = Path(path)
    data = pd.read_csv(csv_path)

    return {
        "path": str(csv_path),
        "rows": int(len(data)),
        "columns": list(data.columns),
        "missing_by_column": {
            column: int(count)
            for column, count in data.isna().sum().sort_values(ascending=False).items()
        },
    }


def write_summary(summary: Dict[str, Any], path: str | Path) -> None:
    Path(path).write_text(json.dumps(summary, indent=2), encoding="utf-8")
