# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

## Workflow Notes And Data Decisions

- This workflow is still being tested and organized.
- Use Colab for Google Earth Engine extraction steps.
- Use RStudio for local R workflow scripts.
- Colab notebooks launch Earth Engine exports and then stop after one status snapshot by default.
- Set `WAIT_FOR_TASKS = TRUE` in a Colab notebook only if you want Colab to keep polling until all launched tasks finish.
- Current annual ERA5-Land run being tested: 2000-2025.
- Current annual ERA5-Land shape: one export per year for all selected sites, or 26 yearly exports.
- ERA5-Land can go back to 1950, but the current default start year is 2000.
- Shared old-vs-GEE comparison window: 2001-2022.
- The comparison window is driven by overlap among ERA5-Land, MODIS NPP/greenup, and the current land-cover product.
- ERA5-Land variables currently included: precipitation, air temperature, actual evapotranspiration, potential evapotranspiration, snow cover fraction, and snow-water equivalent.
- Use `snow_cover_fraction` for the new ERA5-Land analysis.
- Snow cover is not included in the old-vs-GEE comparison QA.
- MODIS NPP starts in 2001 and currently runs through 2024 in the workflow config.
- MODIS greenup day starts in 2001 and currently runs through 2023 in the workflow config.
- If we want NPP or phenology metrics before 2001, we need to identify alternative products or alternative metrics.
- The current land-use/land-cover product goes back to 1985 and stops in 2022.
- We still need to confirm whether the land-use/land-cover product will be updated past 2022 or whether we need a replacement for later years.
- The watershed-size comparison checks ERA5-Land against old spatial-driver products across small, medium, and large watersheds.
- Tiny watersheds use polygon reduction first, then a finer-scale polygon retry if needed.
- Rows filled by the finer-scale retry are flagged with `used_fine_scale_fallback`.
- Run-group chunks are a fallback if all-sites-by-year exports are too large.

## Useful Files

- `data-workflow_spatial.Rproj`: open this in RStudio for local work.
- `colab_notebooks/full_era5_land_annual_2000_2025.ipynb`: full annual ERA5-Land Colab notebook.
- `colab_notebooks/fallback_configured_gee_exports.ipynb`: config-driven fallback Colab notebook.
- `colab_notebooks/test_watershed_size_comparison_era5_land.ipynb`: small, medium, and large watershed comparison Colab notebook.
- `colab_notebooks/test_and_tiny_watersheds_era5_land.ipynb`: Andrews/tiny-watershed test Colab notebook.
- `workflow/run_watershed_size_comparison_qa.R`: local R script for old-vs-GEE watershed-size QA.
- `workflow/build_annual_inventory.R`: local R script for building annual inventory tables from completed exports.
- `docs/current-era5-land-notes.md`: current run notes.
- `docs/gee-full-run-plan.md`: scaling and timing notes.

## References To Revisit

- Wang et al. 2022, Remote Sensing of Environment: MODIS and ERA5-Land land surface temperature comparison. Useful background for thinking through MODIS vs ERA5-Land product comparisons: https://doi.org/10.1016/j.rse.2022.113181

## Repo Layout

- `colab_notebooks/`: Colab notebooks for GEE extraction tests and full runs.
- `workflow/`: local R scripts for watershed inputs, Drive organization, QA, run estimates, and inventory tables.
- `src/gee_spatial/`: Python helpers used by the Colab GEE extraction notebooks.
- `config/`: Earth Engine assets, product settings, and run settings.
- `docs/`: longer workflow notes and draft Earth Engine Code Editor snippets.
