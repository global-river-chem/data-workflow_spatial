# GEE Full Run Plan

This note is for scaling the current Earth Engine pilot to all current watershed rows for the annual ERA5-Land workflow.

## Current Watershed Set

- Watershed asset: `projects/silica-synthesis/assets/silica_gee_watersheds_20260706_shapefile`
- Geometry check file: `watershed-geometry-check_20260706.csv`
- Matched watershed rows in the current asset file: 497
- Run groups: 49
- `expected_area_km2` is the drainage area used for run grouping and checks.
- `drainage_area_source` says where that drainage area came from: the active wide spatial file, the site reference table, the base watershed file, or polygon geometry.
- Tiny watersheds are marked with `tiny_watershed`.
- Rows filled by the finer-scale polygon retry are marked with `used_fine_scale_fallback`.

## ERA5-Land Runs

The primary full annual ERA5-Land notebook is `notebooks/full_runs/run_all_sites_annual_era5_land_2000_2025.ipynb`. It launches one export per year for all selected sites.

The config-driven grouped fallback is listed as `era5_land_annual_full_2000_2025` in `config/run-list.yml`. Use that route only if the all-sites-by-year tasks are too large or fail repeatedly.

The full monthly run is listed as `era5_land_monthly_full`, but it uses `monthly_by_year` timing. That means one export file contains all 12 months for one year and one run group.

The current run configs use the ERA5-Land products already listed in `config/driver-products.yml`. The export code now builds the ERA5 columns from the products listed for a run, so adding more ERA5-Land bands will widen each CSV instead of dropping the extra columns. It may make individual tasks slower, but it does not change the task counts below. The full catalog band list is here: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands

Expected task counts with the current 497-row watershed asset:

| Run | Years | Run groups | Export files/tasks | Exported site-period rows |
|---|---:|---:|---:|---:|
| ERA5 annual, 2000-2025 full, all sites by year | 26 | none | 26 | 12,922 |
| ERA5 annual, 2000-2025 full, grouped fallback | 26 | 49 | 1,274 | 12,922 |
| ERA5 annual, 2001-2022 overlap | 22 | 49 | 1,078 | 10,934 |
| ERA5 monthly, 2000-2025 full, bundled by year | 26 | 49 | 1,274 | 155,064 |
| ERA5 monthly, 2000-2025 full, one task per month | 312 | 49 | 15,288 | 155,064 |

So the monthly run should use `monthly_by_year`. It creates the same number of rows as a one-file-per-month approach, but far fewer files and tasks.

If we later add weekly or daily ERA5-Land outputs for the same 2000-2025 window, the row counts get much larger. The best task chunking for those runs still needs a pilot, because a year of daily reductions may be too much for one export task even when the final CSV size is manageable.

Earth Engine's default average batch-task concurrency is 2, and the ready queue limit is 3,000 tasks. Start with the 26-task all-sites-by-year annual run. If those tasks are too large, switch to the 1,274-task grouped fallback and move through small chunks. Quota details: https://developers.google.com/earth-engine/guides/usage

Use this command to estimate any configured grouped run:

```bash
Rscript scripts/plan-gee-runs.R --run era5_land_monthly_full
```

Once a pilot task finishes, add the observed average runtime:

```bash
Rscript scripts/plan-gee-runs.R --run era5_land_monthly_full --minutes-per-task 10
```

That converts the task count into a rough time estimate using two concurrent Earth Engine batch tasks.

## Wall-Clock Timing

The Colab notebook writes a timing CSV while export tasks run:

```text
timing-logs/gee_task_timing_<active_run>_<timestamp>.csv
```

Each row records the export name, run group, period, year/month, selected watershed rows, site-period rows, product fields, launch time, last checked time, finish time, elapsed minutes, task state, and any task error message.

Use that file to estimate larger runs:

```bash
Rscript scripts/plan-gee-runs.R --run era5_land_monthly_full --timing-log timing-logs/gee_task_timing_era5_land_monthly_year_pilot_YYYYMMDDTHHMMSSZ.csv
```

You can filter the timing rows if a log has mixed runs:

```bash
Rscript scripts/plan-gee-runs.R --run era5_land_monthly_full --timing-log timing-logs/gee_task_timing.csv --timing-mode era5_land --timing-period monthly_by_year
```

For true per-variable timing, run a one-band pilot. If several ERA5-Land bands are exported together, the timing row describes that multi-band export, not the separate cost of each band.

Weekly and daily outputs are not configured yet. Once we add them, the same timing pattern should work: run a small pilot, write the timing CSV, then feed that observed runtime into `scripts/plan-gee-runs.R`.

## Recommended Order

1. Run a one- or two-year smoke test from `notebooks/full_runs/run_all_sites_annual_era5_land_2000_2025.ipynb`.
2. If the smoke test finishes cleanly, run the full annual ERA5-Land workflow for 2000-2025 from the same notebook.
3. If all-sites-by-year tasks fail, switch to the grouped fallback in `notebooks/full_runs/run_configured_gee_spatial_extractions.ipynb`.
4. Run the watershed-size comparison notebook and local QA when we need old-vs-GEE comparison plots/tables.
5. Run `era5_land_monthly_year_pilot` for one group and one year before any monthly scale-up.
6. Run the full ERA5 monthly record in `monthly_by_year` chunks only after the monthly pilot checks out.
7. Then add MODIS annual products, land cover, elevation, soils, lithology, permafrost, and the selected human-impact layers.

## Cloud Storage

Drive is still the default export destination because it is easy for pilot checks.

For larger runs, Cloud Storage is a better landing place because it is easier to script downloads from thousands of files. To switch, edit `config/gee-assets.yml`:

```yaml
exports:
  destination: cloud_storage
  gcs_bucket: YOUR_BUCKET_NAME
  gcs_prefix: gee-exports
```

Use Drive for checks, then Cloud Storage for long runs once a bucket is ready.

Export docs: https://developers.google.com/earth-engine/guides/exporting_tables

## Dataset Upload List

Already available in Earth Engine, so no upload is needed:

- ERA5-Land daily aggregated: `ECMWF/ERA5_LAND/DAILY_AGGR`
- MODIS NPP: `MODIS/061/MOD17A3HGF`
- MODIS greenup day: `MODIS/061/MCD12Q2`
- GLC_FCS30D land cover: `projects/sat-io/open-datasets/GLC-FCS30D/annual`
- SRTM elevation: `USGS/SRTMGL1_003`
- OpenLandMap soils: `OpenLandMap/SOL/SOL_GRTGROUP_USDA-SOILTAX_C/v01`
- GLiM lithology candidate: `projects/sat-io/open-datasets/GLiM`
- Human-impact candidate layers listed in `data-documentation/gee-human-impact-datasets.md`

Upload to this Earth Engine project as project assets:

- Current watershed polygons, because these are project-specific.
- The selected permafrost raster, unless we choose a clean public GEE replacement.
- A lithology raster only if we decide not to use the existing GLiM Community Catalog asset.
- Any custom human-impact layer we derive ourselves before extraction.

Likely Community Catalog candidates:

- None of the project-specific watershed or extracted-driver outputs.
- Permafrost or lithology only if the source license allows redistribution and the uploaded product would be useful beyond this project.
- A custom derived layer only if we can document the source data, processing, units, license, and citation clearly.

The practical default is to upload missing inputs to project assets first, then only consider Community Catalog submission for reusable public data products.
