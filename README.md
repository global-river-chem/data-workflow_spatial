# Data Workflow: Spatial

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
- run one product group, one time slice, and one site group at a time
- split large watersheds into smaller `run_group` batches
- generate the full run list from `config/run-list.yml`
- launch only a small chunk of tasks per Colab session
- check exported CSVs before launching the next batch

Run in Colab:
[open the runner notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/run-gee-spatial-extractions.ipynb)

Basic flow:
1. Build the watershed input files with `scripts/build-gee-watershed-upload.R`
2. Upload watershed assets to Earth Engine
3. Set the watershed asset and export folder in `config/gee-assets.yml`
4. Pick the active run in `config/run-list.yml`
5. Run the Colab notebook
6. Download exported CSVs and check them with `src/gee_spatial/checks.py`

Current pilot:
- watershed upload file: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/silica_gee_watersheds_20260629_shapefile.zip`
- geometry check: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/watershed-geometry-check_20260629.csv`
- active run: `era5_land_annual_pilot`
- ERA5-Land pilot columns: `precip_mm`, `temp_degC`, `evapotrans_mm`, `potential_evap_mm`, `snow_cover_fraction`, `snow_water_equiv_mm`

Note: the current Earth Engine asset was uploaded from the zipped shapefile. Earth Engine shortened some field names during upload, so the uploaded run-group field is `run_grp`.
