"""Export helpers for Earth Engine tables."""

from __future__ import annotations

from typing import Iterable, Optional


def export_table_to_drive(
    collection,
    description: str,
    folder: str,
    file_name_prefix: Optional[str] = None,
    selectors: Optional[Iterable[str]] = None,
    file_format: str = "CSV",
):
    import ee

    kwargs = {
        "collection": collection,
        "description": description,
        "folder": folder,
        "fileFormat": file_format,
    }

    if file_name_prefix:
        kwargs["fileNamePrefix"] = file_name_prefix

    if selectors:
        kwargs["selectors"] = list(selectors)

    task = ee.batch.Export.table.toDrive(**kwargs)
    task.start()
    return task


def task_summary(task) -> dict:
    status = task.status()
    return {
        "id": status.get("id"),
        "description": status.get("description"),
        "state": status.get("state"),
    }
