"""Earth Engine authentication helpers."""

from __future__ import annotations

from typing import Optional


def initialize(project: Optional[str] = None):
    """Authenticate if needed, then initialize Earth Engine."""

    import ee

    kwargs = {"project": project} if project else {}

    try:
        ee.Initialize(**kwargs)
    except Exception:
        ee.Authenticate()
        ee.Initialize(**kwargs)

    return ee
