"""Earth Engine authentication helpers."""

from __future__ import annotations

from typing import Optional


def initialize(project: Optional[str] = None):
    """Authenticate if needed, then initialize Earth Engine."""

    import ee

    kwargs = {"project": project} if project else {}
    auth_kwargs = {}

    try:
        import google.colab  # type: ignore  # noqa: F401

        auth_kwargs["auth_mode"] = "colab"
    except ImportError:
        pass

    try:
        ee.Initialize(**kwargs)
    except Exception:
        ee.Authenticate(**auth_kwargs)
        ee.Initialize(**kwargs)

    return ee
