# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

This repo is for the GEE workflow. Older APPEEARS/NASA/Aurora spatial extraction work lives outside this repo.

## Start Here

- Full annual ERA5-Land Colab: [run_all_sites_annual_era5_land_2000_2025.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/full_runs/run_all_sites_annual_era5_land_2000_2025.ipynb)
- Watershed-size comparison Colab: [run_watershed_size_comparison_sites_annual_era5_land.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/tests/watershed_size_comparison_sites/run_watershed_size_comparison_sites_annual_era5_land.ipynb)
- AND tiny-watershed test Colab: [run_and_tiny_watersheds_annual_era5_land.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/tests/and_tiny_watersheds/run_and_tiny_watersheds_annual_era5_land.ipynb)
- Current ERA5-Land notes: `docs/current-era5-land-notes.md`
- Full-run planning notes: `docs/gee-full-run-plan.md`

## Folder Map

- `notebooks/full_runs/`: Colab notebooks for main GEE extraction runs.
- `notebooks/tests/`: Colab notebooks for test/comparison extractions.
- `src/gee_spatial/`: Python helpers used by the Colab GEE extraction notebooks.
- `scripts/`: R setup and planning scripts.
- `post_export/`: R scripts for organizing completed GEE exports.
- `qa/`: R scripts for comparison plots and QA tables.
- `inventory/`: R scripts for building query-ready output tables.
- `config/`: run settings, product settings, and Earth Engine asset paths.
- `docs/`: notes that are useful but too detailed for this README.
- `gee-code/`: draft Earth Engine Code Editor scripts.

## Current Notes

- Current full annual ERA5-Land run: 2000-2025.
- Current full annual run shape: one export per year for all selected sites.
- Current full annual task count: 26 yearly exports.
- Shared comparison window: 2001-2022.
- ERA5-Land variables now included: precipitation, air temperature, actual evapotranspiration, potential evapotranspiration, snow cover fraction, and snow-water equivalent.
- Tiny watersheds use polygon reduction first, then a finer-scale polygon retry if needed.
- Rows filled by the retry are flagged with `used_fine_scale_fallback`.
- Run-group chunks are a fallback if all-sites-by-year exports are too large.

## Local R Commands

```bash
Rscript scripts/check-product-config.R
Rscript scripts/plan-gee-runs.R
Rscript qa/old_vs_gee/run_watershed_size_comparison_qa.R
Rscript inventory/build_all_sites_annual_inventory.R
```
