# Data Workflow: Spatial

Google Earth Engine spatial data workflow for the global river chemistry project.

This repo keeps the reusable GEE code in GitHub and uses Colab as the online runner for authentication and exports.

Current contents:
- `scripts/build-gee-watershed-upload.R`: builds the watershed file used by Google Earth Engine
- `scripts/check-product-config.py`: checks the product settings before running GEE exports
- `scripts/plan-gee-runs.py`: estimates export tasks and rows before launching a run
- `notebooks/run-gee-spatial-extractions.ipynb`: Colab runner that installs this repo and starts GEE
- `src/gee_spatial/`: reusable Python helpers for GEE extraction, export, and CSV checks
- `config/`: Earth Engine asset and product settings
- `docs/gee-full-run-plan.md`: notes for scaling from pilot runs to all sites and full ERA5-Land records
- `gee-code/derive-western-australia.js`: draft GEE script for Western Australia watershed checks

Product search and dataset decisions live in `global-river-chem/data-documentation`. This repo is for the code that runs those decisions.

Run pattern:
- use one Colab runner
- run one product group, one time slice, and one site group at a time
- split large watersheds into smaller `run_group` batches
- generate the full run list from `config/run-list.yml`
- use `monthly_by_year` for long monthly ERA5-Land runs so each export has all 12 months for one group-year
- launch only a small chunk of tasks per Colab session
- check exported CSVs before launching the next batch

Run in Colab:
[open the runner notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/run-gee-spatial-extractions.ipynb)

Basic flow:
1. Build the watershed input files with `scripts/build-gee-watershed-upload.R`
2. Upload watershed assets to Earth Engine
3. Set the watershed asset and export folder in `config/gee-assets.yml`
4. Pick the active run in `config/run-list.yml`
5. Check the task count with `python3 scripts/plan-gee-runs.py`
6. Run the Colab notebook
7. Download exported CSVs and check them with `src/gee_spatial/checks.py`

Current first pull:
- watershed upload file: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/silica_gee_watersheds_20260629_shapefile.zip`
- geometry check: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/watershed-geometry-check_20260629.csv`
- active run: `era5_land_annual_overlap_2001_2022`
- current test size: 2 annual exports, starting with `batch_001` for 2001 and 2002
- drainage area note: `expected_area_km2` comes from the active wide spatial file, with `drainSqKm` from the site reference table as a fallback; new exports include `drainage_area_source` so this is visible row by row
- reason for this window: 2001-2022 is the shared annual window for ERA5-Land, MODIS NPP/greenup, and GLC_FCS30D land cover
- ERA5-Land columns: `precip_mm`, `temp_degC`, `evapotrans_mm`, `potential_evap_mm`, `snow_cover_fraction`, `snow_water_equiv_mm`
- snow cover note: the first pilot exports came through on a 0-100 scale, so the config now divides `snow_cover` by 100; rerun 2001 and 2002 before scaling up so all ERA5-Land outputs use the same fraction units
- small watershed note: watersheds with polygon area at or below 10 km2 are marked `tiny_watershed`; the GEE code clips each image to the watershed before reducing it, and if that still comes back blank, it fills from the watershed centroid and marks that row with `used_centroid_fallback`

Product periods:
- ERA5-Land daily aggregated: 1950-01-02 through near-current; use complete annual exports through 2025 for now
- MODIS annual NPP: 2001-2024
- MODIS greenup day: 2001-2023
- GLC_FCS30D annual land cover: 2000-2022

Record-length plan:
- first cross-product annual pull: 2001-2022, because this is the shared window across ERA5-Land, MODIS, and GLC_FCS30D
- longer ERA5-Land-only pull: 1950-2025 is listed as a full annual run
- monthly ERA5-Land pull: use `monthly_by_year` timing, launch it in chunks, and check the pilot before scaling up

Full-run planning:
- use `docs/gee-full-run-plan.md` for task counts, rough timing, and upload notes
- the Colab notebook writes a wall-clock timing CSV in `timing-logs/` while tasks run
- current full ERA5-Land configs are present but `launch_export: false`
- Drive is the default export destination; Cloud Storage can be switched on in `config/gee-assets.yml` for longer runs

ERA5-Land band options:
- selected now: `total_precipitation_sum`, `temperature_2m`, `total_evaporation_sum`, `potential_evaporation_sum`, `snow_cover`, `snow_depth_water_equivalent`
- other available bands are listed in the Earth Engine catalog: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands
- the ERA5 export column list now follows the products listed for the run, so added bands will be exported instead of dropped

Note: the current Earth Engine asset was uploaded from the zipped shapefile. Earth Engine shortened some field names during upload, so the uploaded run-group field is `run_grp`.
