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

Current first pull:
- watershed upload file: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/silica_gee_watersheds_20260629_shapefile.zip`
- geometry check: `spatial-data-files/gee/earth-engine-input-files/20260629-gee-watersheds/watershed-geometry-check_20260629.csv`
- active run: `era5_land_annual_overlap_2001_2022`
- current test size: 2 annual exports, starting with `batch_001` for 2001 and 2002
- reason for this window: 2001-2022 is the shared annual window for ERA5-Land, MODIS NPP/greenup, and GLC_FCS30D land cover
- ERA5-Land columns: `precip_mm`, `temp_degC`, `evapotrans_mm`, `potential_evap_mm`, `snow_cover_fraction`, `snow_water_equiv_mm`
- snow cover note: the first pilot exports came through on a 0-100 scale, so the config now divides `snow_cover` by 100; rerun 2001 and 2002 before scaling up so all ERA5-Land outputs use the same fraction units
- small watershed note: if a watershed is too small to catch an ERA5 pixel center, the GEE code fills missing values from the watershed centroid; this is mainly for tiny AND basins in `batch_001`

Product periods:
- ERA5-Land daily aggregated: 1950-01-02 through near-current; use complete annual exports through 2025 for now
- MODIS annual NPP: 2001-2024
- MODIS greenup day: 2001-2023
- GLC_FCS30D annual land cover: 2000-2022

Record-length decision still needed:
- first cross-product annual pull: 2001-2022, because this is the shared window across ERA5-Land, MODIS, and GLC_FCS30D
- longer ERA5-Land-only pull: possible for 1950-2025, but we need to decide whether those extra years are useful without matching MODIS and land-cover products
- monthly ERA5-Land pull: planned, but needs chunking by year or multi-year block before launching long records

ERA5-Land band options:
- selected now: `total_precipitation_sum`, `temperature_2m`, `total_evaporation_sum`, `potential_evaporation_sum`, `snow_cover`, `snow_depth_water_equivalent`
- temperature and humidity: `dewpoint_temperature_2m`, `temperature_2m`, `skin_temperature`
- soil temperature: `soil_temperature_level_1`, `soil_temperature_level_2`, `soil_temperature_level_3`, `soil_temperature_level_4`
- lake variables: `lake_bottom_temperature`, `lake_ice_depth`, `lake_ice_temperature`, `lake_mix_layer_depth`, `lake_mix_layer_temperature`, `lake_shape_factor`, `lake_total_layer_temperature`
- snow variables: `snow_albedo`, `snow_cover`, `snow_density`, `snow_depth`, `snow_depth_water_equivalent`, `snowfall_sum`, `snowmelt_sum`, `temperature_of_snow_layer`
- soil and canopy water: `skin_reservoir_content`, `volumetric_soil_water_layer_1`, `volumetric_soil_water_layer_2`, `volumetric_soil_water_layer_3`, `volumetric_soil_water_layer_4`
- radiation and heat: `forecast_albedo`, `surface_latent_heat_flux_sum`, `surface_net_solar_radiation_sum`, `surface_net_thermal_radiation_sum`, `surface_sensible_heat_flux_sum`, `surface_solar_radiation_downwards_sum`, `surface_thermal_radiation_downwards_sum`
- evaporation and runoff: `evaporation_from_bare_soil_sum`, `evaporation_from_open_water_surfaces_excluding_oceans_sum`, `evaporation_from_the_top_of_canopy_sum`, `evaporation_from_vegetation_transpiration_sum`, `potential_evaporation_sum`, `runoff_sum`, `snow_evaporation_sum`, `sub_surface_runoff_sum`, `surface_runoff_sum`, `total_evaporation_sum`
- wind and pressure: `u_component_of_wind_10m`, `v_component_of_wind_10m`, `surface_pressure`
- vegetation: `leaf_area_index_high_vegetation`, `leaf_area_index_low_vegetation`
- daily minimum and maximum bands are also available for many non-sum variables, including temperature, snow, soil water, radiation, evaporation, runoff, wind, pressure, and leaf area index
- note from the Earth Engine catalog: the three component evaporation bands have a known swap issue in the ECMWF source data, so avoid those unless we specifically need them and check them carefully
- catalog: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands

Note: the current Earth Engine asset was uploaded from the zipped shapefile. Earth Engine shortened some field names during upload, so the uploaded run-group field is `run_grp`.
