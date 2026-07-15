# Spatial Data Workflow Roadmap

GitHub: https://github.com/global-river-chem/data-workflow_spatial

Progress updates: [progress_updates.md](progress_updates.md)

## What This Is For

Finish the ERA5-Land annual extraction and QA work for the global river
chemistry spatial dataset.

## What Exists Now

- The 2000-2025 ERA5-Land Earth Engine tasks completed with 26 annual CSVs.
- The completed files include 497 sites per year and all six selected variables.
- The run is not final yet because 46 rows from the 543-site source spatial
  table were not included in the uploaded Earth Engine asset.
- Six missing rows are marked as HydroSHEDS sites in the source table.
- Snow cover is kept for the new ERA5-Land analysis, but it is not included in
  the old-vs-GEE comparison QA.
- ERA5-Land native resolution is about 11 km, so small watersheds need explicit
  extraction checks.
- Tiny watersheds are handled by trying the full polygon first, then retrying
  the same polygon at a finer scale if the first extraction is blank.
- Rows filled by the finer-scale retry are marked with
  `used_fine_scale_fallback`.
- Tiny-watershed values should not be filled from the watershed centroid.

## Current ERA5-Land Variables

- Precipitation
- Air temperature
- Actual evapotranspiration
- Potential evapotranspiration
- Snow cover fraction
- Snow-water equivalent

## Product Periods

- ERA5-Land: available from 1950-01-02 through near-present
- Current ERA5-Land workflow: 2000-2025
- Shared old-vs-GEE comparison window: 2001-2022
- MODIS NPP: 2001-2024
- MODIS greenup day: 2001-2023
- GLC_FCS30D annual land cover: 1985-2022
- GLC_FCS30D is interpolated every 5 years from 2000 back to 1985

## Next Steps

1. Fix the missing watershed geometries before treating the full run as final.
2. Rebuild the Earth Engine upload asset after the missing geometry issue is
   resolved.
3. Rerun the full annual ERA5-Land extraction if the asset changes.
4. Review McMurdo snow-water equivalent before using that variable in analysis.
5. Review the old-vs-ERA5 comparison plots for precipitation, temperature, and
   evapotranspiration.
6. Keep ERA5-Land snow cover out of the old MODIS snow comparison.
7. Confirm whether GLC_FCS30D will be updated past 2022 or whether a replacement
   land-cover product is needed.
8. Decide whether any pre-2001 productivity or phenology variables are needed.
9. Review possible alternatives for pre-2001 productivity or phenology, such as
   Landsat NDVI or other vegetation metrics, and simple daylength or latitude
   summaries for greenup timing.

## Useful Files

- `docs/current-era5-land-notes.md`: detailed run notes and QA findings
- `docs/gee-full-run-plan.md`: scaling and task-count notes
- `workflow/build_watershed_upload_file.R`: builds the Earth Engine watershed
  upload file
- `workflow/check_full_annual_era5_land.R`: checks the completed annual
  ERA5-Land files
- `workflow/compare_full_annual_era5_land_to_old_drivers.R`: compares full
  annual ERA5-Land outputs with the previous annual spatial drivers
