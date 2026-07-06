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


def export_table_to_cloud_storage(
    collection,
    description: str,
    bucket: str,
    file_name_prefix: Optional[str] = None,
    selectors: Optional[Iterable[str]] = None,
    file_format: str = "CSV",
):
    if not bucket:
        raise ValueError("Set exports.gcs_bucket in config/gee-assets.yml before exporting to Cloud Storage")

    import ee

    kwargs = {
        "collection": collection,
        "description": description,
        "bucket": bucket,
        "fileFormat": file_format,
    }

    if file_name_prefix:
        kwargs["fileNamePrefix"] = file_name_prefix

    if selectors:
        kwargs["selectors"] = list(selectors)

    task = ee.batch.Export.table.toCloudStorage(**kwargs)
    task.start()
    return task


def export_table(
    collection,
    description: str,
    export_config: dict,
    file_name_prefix: Optional[str] = None,
    selectors: Optional[Iterable[str]] = None,
    file_format: str = "CSV",
):
    destination = export_config.get("destination", "drive")

    if destination in {"drive", "google_drive"}:
        return export_table_to_drive(
            collection=collection,
            description=description,
            folder=export_config["drive_folder"],
            file_name_prefix=file_name_prefix,
            selectors=selectors,
            file_format=file_format,
        )

    if destination in {"cloud_storage", "gcs"}:
        prefix = export_config.get("gcs_prefix", "")
        gcs_name = file_name_prefix
        if prefix and file_name_prefix:
            gcs_name = f"{prefix.rstrip('/')}/{file_name_prefix}"

        return export_table_to_cloud_storage(
            collection=collection,
            description=description,
            bucket=export_config.get("gcs_bucket", ""),
            file_name_prefix=gcs_name,
            selectors=selectors,
            file_format=file_format,
        )

    raise ValueError(f"Unsupported export destination: {destination}")


def task_summary(task) -> dict:
    status = task.status()
    return {
        "id": status.get("id"),
        "description": status.get("description"),
        "state": status.get("state"),
    }
