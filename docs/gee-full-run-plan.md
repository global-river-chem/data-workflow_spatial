# GEE Full Run Plan

This note is for scaling the current Earth Engine pilot to all current watershed rows and the longer ERA5-Land record.

## Current Watershed Set

- Watershed asset: `projects/silica-synthesis/assets/silica_gee_watersheds_20260629`
- Geometry check file: `watershed-geometry-check_20260629.csv`
- Matched watershed rows in the current asset file: 497
- Run groups: 47
- Tiny watersheds are marked with `tiny_watershed`.
- Rows filled from centroid sampling are marked with `used_centroid_fallback`.

## ERA5-Land Runs

The full ERA5-Land annual run is now listed as `era5_land_annual_full_1950_2025`.

The full monthly run is listed as `era5_land_monthly_full`, but it uses `monthly_by_year` timing. That means one export file contains all 12 months for one year and one run group.

The current run configs use the ERA5-Land products already listed in `config/driver-products.yml`. The export code now builds the ERA5 columns from the products listed for a run, so adding more ERA5-Land bands will widen each CSV instead of dropping the extra columns. It may make individual tasks slower, but it does not change the task counts below. The full catalog band list is here: https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands

Expected task counts with the current 497-row watershed asset:

| Run | Years | Run groups | Export files/tasks | Exported site-period rows |
|---|---:|---:|---:|---:|
| ERA5 annual, 2001-2022 overlap | 22 | 47 | 1,034 | 10,934 |
| ERA5 annual, 1950-2025 full | 76 | 47 | 3,572 | 37,772 |
| ERA5 monthly, 1950-2025 full, bundled by year | 76 | 47 | 3,572 | 453,264 |
| ERA5 monthly, 1950-2025 full, one task per month | 912 | 47 | 42,864 | 453,264 |

So the monthly run should use `monthly_by_year`. It creates the same number of rows as a one-file-per-month approach, but far fewer files and tasks.

If we later add weekly or daily ERA5-Land outputs for the same 1950-2025 window, the row counts get much larger: about 1,964,144 site-week rows or 13,796,223 site-day rows. The best task chunking for those runs still needs a pilot, because a year of daily reductions may be too much for one export task even when the final CSV size is manageable.

Earth Engine's default average batch-task concurrency is 2, and the ready queue limit is 3,000 tasks. That means we should not queue a whole 3,572-task full run in one sitting. Use small chunks, check outputs, then keep moving through the run list. Quota details: https://developers.google.com/earth-engine/guides/usage

Use this command to estimate any configured run:

```bash
python3 scripts/plan-gee-runs.py --run era5_land_monthly_full
```

Once a pilot task finishes, add the observed average runtime:

```bash
python3 scripts/plan-gee-runs.py --run era5_land_monthly_full --minutes-per-task 10
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
python3 scripts/plan-gee-runs.py --run era5_land_monthly_full --timing-log timing-logs/gee_task_timing_era5_land_monthly_year_pilot_YYYYMMDDTHHMMSSZ.csv
```

You can filter the timing rows if a log has mixed runs:

```bash
python3 scripts/plan-gee-runs.py --run era5_land_monthly_full --timing-log timing-logs/gee_task_timing.csv --timing-mode era5_land --timing-period monthly_by_year
```

For true per-variable timing, run a one-band pilot. If several ERA5-Land bands are exported together, the timing row describes that multi-band export, not the separate cost of each band.

Weekly and daily outputs are not configured yet. Once we add them, the same timing pattern should work: run a small pilot, write the timing CSV, then feed that observed runtime into `scripts/plan-gee-runs.py`.

## Recommended Order

1. Rerun the small ERA5 annual pilot after the snow-cover and small-watershed fixes.
2. Run `era5_land_monthly_year_pilot` for one group and one year.
3. If both checks look good, run the 2001-2022 annual overlap across all groups.
4. Run the full ERA5 annual record in chunks.
5. Run the full ERA5 monthly record in `monthly_by_year` chunks.
6. Then add MODIS annual products, land cover, elevation, soils, lithology, permafrost, and the selected human-impact layers.

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
