# Current ERA5-Land Notes

This note holds the current run details that used to make the main README too long.

## Current First Pull

- Watershed upload file: `spatial-data-files/gee/earth-engine-input-files/20260706-gee-watersheds/silica_gee_watersheds_20260706_shapefile.zip`
- Geometry check: `spatial-data-files/gee/earth-engine-input-files/20260706-gee-watersheds/watershed-geometry-check_20260706.csv`
- Active full annual run: `era5_land_annual_full_2000_2025`
- Shared comparison-window run: `era5_land_annual_overlap_2001_2022`
- Primary full annual notebook: `colab_notebooks/full_era5_land_annual_2000_2025.ipynb`
- Primary full annual task shape: one export per year for all selected sites, so 26 exports for 2000-2025.
- Drainage area: `expected_area_km2` comes from the active wide spatial file, with `drainSqKm` from the site reference table and polygon geometry as fallbacks.
- New exports include `drainage_area_source` so drainage-area provenance is visible row by row.
- Full annual ERA5-Land workflow: 2000-2025.
- Shared comparison window: 2001-2022 for ERA5-Land, MODIS NPP/greenup, and GLC_FCS30D land cover.
- ERA5-Land output columns: `precip_mm`, `temp_degC`, `evapotrans_mm`, `potential_evap_mm`, `snow_cover_fraction`, `snow_water_equiv_mm`.
- Snow cover: annual exports keep the ERA5-Land metric from the original workflow, which is the annual maximum snow-cover image summarized as a watershed mean.
- Snow cover units: early pilot exports came through on a 0-100 scale; config divides `snow_cover` by 100 so outputs use fraction units.
- Snow cover is kept for the new ERA5-Land analysis, but it is not included in the old-vs-GEE comparison QA.
- Small watersheds: watersheds at or below 10 km2 are marked `tiny_watershed`; blank polygon reductions retry the same polygon at a finer scale and mark `used_fine_scale_fallback`.

## Product Periods

- ERA5-Land daily aggregated: available from 1950-01-02 through near-current. The current annual workflow should start at 2000 unless a specific comparison run says otherwise.
- MODIS annual NPP: 2001-2024.
- MODIS greenup day: 2001-2023.
- GLC_FCS30D annual land cover: 1985-2022. We still need to confirm whether it will be updated past 2022 or whether we need a replacement for later years.

## Record-Length Plan

- Cross-product annual comparison pull: 2001-2022, because MODIS NPP/greenup start in 2001 and the current land-cover product stops in 2022.
- If we want NPP or phenology metrics before 2001, we need to identify alternative products or alternative metrics.
- Current ERA5-Land annual workflow: 2000-2025.
- Monthly ERA5-Land pull: use `monthly_by_year` timing, launch in chunks, and check the pilot before scaling up.
- Wider ERA5-Land source availability can be revisited later, but do not treat 1950 as the default current workflow start.

## ERA5-Land Bands

- Selected now: `total_precipitation_sum`, `temperature_2m`, `total_evaporation_sum`, `potential_evaporation_sum`, `snow_cover`, `snow_depth_water_equivalent`.
- Other available bands are listed in the Earth Engine catalog: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands
- The ERA5 export column list follows the products listed for the run, so added bands are exported instead of dropped.

## Planning Links

- Scaling/task-count notes: `docs/gee-full-run-plan.md`
- Active run config: `config/run-list.yml`
- Product config: `config/driver-products.yml`
