# Spatial Data Workflow

Google Earth Engine spatial data workflow for the global river chemistry project.

This repo keeps the reusable GEE code in GitHub and uses Colab as the online runner for authentication and exports.

Current contents:
- `scripts/build-gee-watershed-upload.R`: builds the watershed file used by Google Earth Engine
- `scripts/check-product-config.py`: checks the product settings before running GEE exports
- `notebooks/run-gee-spatial-extractions.ipynb`: Colab runner that installs this repo and starts GEE
- `src/gee_spatial/`: reusable Python helpers for GEE extraction, export, and CSV checks
- `config/`: Earth Engine asset and product settings
- `gee-code/derive-western-australia.js`: draft GEE script for Western Australia watershed checks

Product search and dataset decisions live in `global-river-chem/data-documentation`. This repo is for the code that runs those decisions.

Run pattern:
- use one Colab runner
- run one product, one time slice, and one site group at a time
- split large watersheds into smaller `run_group` batches
- check exported CSVs before launching the next batch

Run in Colab:
[open the runner notebook](https://colab.research.google.com/github/global-river-chem/spatial-data-workflow/blob/main/notebooks/run-gee-spatial-extractions.ipynb)

Basic flow:
1. Build the watershed input file with `scripts/build-gee-watershed-upload.R`
2. Upload watershed assets to Earth Engine
3. Set the watershed asset and export folder in `config/gee-assets.yml`
4. Run the Colab notebook
5. Download exported CSVs and check them with `src/gee_spatial/checks.py`

Current pilot:
- watershed file: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/silica_gee_watersheds_20260629.geojson`
- geometry check: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/watershed-geometry-check_20260629.csv`
- first test run: `precip`, `2020`, `batch_001`
