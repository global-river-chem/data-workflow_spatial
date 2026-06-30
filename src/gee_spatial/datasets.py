"""Dataset helpers for GEE spatial products."""

from __future__ import annotations

from typing import Any, Dict, List


def product_names(config: Dict[str, Any]) -> List[str]:
    products = config.get("products") or {}
    return sorted(products.keys())


def planned_products(config: Dict[str, Any]) -> List[str]:
    products = config.get("products") or {}
    return sorted(
        name
        for name, settings in products.items()
        if (settings or {}).get("status") == "planned"
    )
