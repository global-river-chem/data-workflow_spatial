from __future__ import annotations

from collections import Counter
from pathlib import Path
from typing import Any, Dict, List

try:
    import yaml
except ModuleNotFoundError:
    yaml = None


ROOT = Path(__file__).resolve().parents[1]
PRODUCT_CONFIG = ROOT / "config" / "driver-products.yml"

BASE_REQUIRED = {
    "status",
    "source",
    "gee_id",
    "type",
    "source_temporal_resolution",
    "output_temporal_resolution",
    "output_name",
}

CONTINUOUS_REQUIRED = {
    "band",
    "output_units",
    "scale_factor",
    "offset",
    "reducer",
}


def load_products() -> Dict[str, Any]:
    if yaml is not None:
        with PRODUCT_CONFIG.open(encoding="utf-8") as handle:
            config = yaml.safe_load(handle) or {}

        return config.get("products") or {}

    return load_products_without_yaml()


def parse_scalar(value: str) -> Any:
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value in {"null", "None", ""}:
        return None

    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def load_products_without_yaml() -> Dict[str, Any]:
    products: Dict[str, Any] = {}
    current_product = None
    in_products = False

    for raw_line in PRODUCT_CONFIG.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()

        if indent == 0 and line == "products:":
            in_products = True
            continue

        if not in_products:
            continue

        if indent == 2 and line.endswith(":"):
            current_product = line[:-1]
            products[current_product] = {}
            continue

        if indent == 4 and current_product and ":" in line:
            key, value = line.split(":", 1)
            products[current_product][key.strip()] = parse_scalar(value.strip())

    return products


def missing_fields(product: Dict[str, Any]) -> List[str]:
    required = set(BASE_REQUIRED)

    if product.get("type") == "continuous":
        required.update(CONTINUOUS_REQUIRED)

    if product.get("type") != "source_list" and product.get("source_temporal_resolution") != "static":
        required.add("selected_spatial_resolution_m")

    return sorted(field for field in required if field not in product)


def main() -> None:
    products = load_products()
    issues = []

    for name, settings in products.items():
        missing = missing_fields(settings or {})
        if missing:
            issues.append((name, missing))

    status_counts = Counter((settings or {}).get("status", "missing") for settings in products.values())
    type_counts = Counter((settings or {}).get("type", "missing") for settings in products.values())

    print(f"Products: {len(products)}")
    print("By status:", dict(sorted(status_counts.items())))
    print("By type:", dict(sorted(type_counts.items())))

    if issues:
        print("\nMissing fields:")
        for name, missing in issues:
            print(f"- {name}: {', '.join(missing)}")
        raise SystemExit(1)

    print("\nProduct config looks OK")


if __name__ == "__main__":
    main()
