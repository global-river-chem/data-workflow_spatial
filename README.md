# Spatial Data Workflow

Google Earth Engine spatial data workflow for the global river chemistry project.

This repo keeps the reusable GEE code in GitHub and uses Colab as the online runner for authentication and exports.

Current contents:
- `scripts/prepare-shapefiles-for-gee.R`: prepares watershed shapefiles for Google Earth Engine upload
- `notebooks/run-gee-spatial-extractions.ipynb`: Colab runner that installs this repo and starts GEE
- `src/gee_spatial/`: reusable Python helpers for GEE extraction, export, and CSV checks
- `config/`: Earth Engine asset and product settings
- `gee-code/derive-western-australia.js`: draft GEE script for Western Australia watershed checks

Run in Colab:
[open the runner notebook](https://colab.research.google.com/github/global-river-chem/spatial-data-workflow/blob/main/notebooks/run-gee-spatial-extractions.ipynb)

Basic flow:
1. Prepare watershed shapefiles with `scripts/prepare-shapefiles-for-gee.R`
2. Upload watershed assets to Earth Engine
3. Set the watershed asset and export folder in `config/gee-assets.yml`
4. Run the Colab notebook
5. Download exported CSVs and check them with `src/gee_spatial/checks.py`
