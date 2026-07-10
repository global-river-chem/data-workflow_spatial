# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

This repo keeps the reusable GEE extraction code, run configuration, and Colab runner. Product-search notes and dataset decisions live in `global-river-chem/data-documentation`; older non-GEE APPEEARS/NASA/Aurora workflows live outside this repo.

## Quick Links

- Full annual ERA5-Land Colab: [run_all_sites_annual_era5_land_2000_2025.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/full_runs/run_all_sites_annual_era5_land_2000_2025.ipynb)
- Watershed-size comparison Colab: [run_watershed_size_comparison_sites_annual_era5_land.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/tests/watershed_size_comparison_sites/run_watershed_size_comparison_sites_annual_era5_land.ipynb)
- AND tiny-watershed test Colab: [run_and_tiny_watersheds_annual_era5_land.ipynb](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/notebooks/tests/and_tiny_watersheds/run_and_tiny_watersheds_annual_era5_land.ipynb)
- Full-run planning: `docs/gee-full-run-plan.md`
- Current ERA5-Land notes: `docs/current-era5-land-notes.md`
- Active run list: `config/run-list.yml`
- Product settings: `config/driver-products.yml`

## What Lives Here

- `notebooks/`: Colab runners for GEE authentication and exports.
- `src/gee_spatial/`: reusable Python helpers used by the Colab GEE extraction runner.
- `scripts/`: R utilities for watershed prep, config checks, and run planning.
- `post_export/`, `qa/`, `inventory/`: local R steps after GEE exports finish.
- `config/`: Earth Engine assets, product settings, and run lists.
- `gee-code/`: draft Earth Engine scripts for one-off checks.
- `docs/`: run planning, current-run notes, and scaling notes.

## Basic Flow

1. Build the watershed input files with `scripts/build-gee-watershed-upload.R`.
2. Upload watershed assets to Earth Engine.
3. Set the watershed asset and export folder in `config/gee-assets.yml`.
4. Pick the active run in `config/run-list.yml`.
5. Check task counts before launching a run with `Rscript scripts/plan-gee-runs.R`.
6. Run the Colab notebook.
7. Check exported CSVs before launching the next batch.

Post-export R examples:

```bash
Rscript qa/old_vs_gee/run_watershed_size_comparison_qa.R
Rscript inventory/build_all_sites_annual_inventory.R
```

## Current ERA5-Land Direction

For the current annual ERA5-Land workflow, start at 2000 unless a specific comparison run intentionally uses the 2001-2022 shared product window. Keep long-record or monthly ideas in planning docs until pilots have been checked.

Current selected annual ERA5-Land outputs:

- precipitation
- air temperature
- actual evapotranspiration
- potential evapotranspiration
- snow cover fraction
- snow-water equivalent

Tiny watersheds are handled with polygon reduction first, then a finer-scale polygon retry when needed. Rows filled by the retry are flagged with `used_fine_scale_fallback`.

## Run Pattern

- Use one Colab runner.
- Run one product group, one time slice, and one site group at a time.
- Launch small task chunks first.
- Use timing logs to estimate the full run.
- Check outputs before scaling up.

Earth Engine may shorten uploaded shapefile field names; the uploaded run-group field is currently `run_grp`.
