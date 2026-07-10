# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

## Workflow Notes And Data Decisions

- This workflow is still being tested and organized.
- For local R work, open `data-workflow_spatial.Rproj` in RStudio.
- Colab notebooks are for Google Earth Engine extraction steps.
- Local R scripts handle watershed inputs, post-export organization, QA, and inventory work.
- Current annual ERA5-Land run being tested: 2000-2025.
- Current annual ERA5-Land run shape: one export per year for all selected sites, which is 26 yearly exports.
- ERA5-Land can go back to 1950. We are not using 1950 as the current default start year, but it is available if we decide to extend climate variables farther back.
- Shared old-vs-GEE comparison window: 2001-2022.
- The 2001-2022 comparison window is driven by overlap among ERA5-Land, MODIS NPP/greenup, and the current land-cover product.
- ERA5-Land variables currently included: precipitation, air temperature, actual evapotranspiration, potential evapotranspiration, snow cover fraction, and snow-water equivalent.
- MODIS NPP starts in 2001 and currently runs through 2024 in the workflow config.
- MODIS greenup day starts in 2001 and currently runs through 2023 in the workflow config.
- If we want NPP or phenology metrics before 2001, we need to identify alternative products or alternative metrics.
- The current land-use/land-cover product goes back to 1985 and stops in 2022.
- We still need to confirm whether the land-use/land-cover product will be updated past 2022 or whether we need a replacement for later years.
- The watershed-size comparison checks ERA5-Land against the old spatial-driver products across small, medium, and large watersheds.
- Tiny watersheds use polygon reduction first, then a finer-scale polygon retry if needed.
- Rows filled by the finer-scale retry are flagged with `used_fine_scale_fallback`.
- Run-group chunks are a fallback if all-sites-by-year exports are too large.

## Repo Layout

- `notebooks/`: Colab notebooks for GEE extraction tests and full runs.
- `src/gee_spatial/`: Python extraction helpers called by the Colab notebooks.
- `config/`: Earth Engine assets, product settings, and run settings.
- `scripts/`, `post_export/`, `qa/`, `inventory/`: local R workflow pieces.
- `docs/`: longer workflow notes.
- `gee-code/`: draft Earth Engine Code Editor scripts; archive or remove later if not needed.
