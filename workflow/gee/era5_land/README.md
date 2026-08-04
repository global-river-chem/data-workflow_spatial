# ERA5-Land extraction

The workflow extracts daily ERA5-Land values once and creates monthly or
weekly summaries locally. The default products are precipitation,
temperature, evapotranspiration, potential evaporation, snow cover, and
snow-water equivalent.

ERA5-Land stores evaporation as a negative flux; the export reports positive
evapotranspiration. Very small watersheds without a native-grid pixel center
use the native-grid value at the watershed centroid.

## Build watershed batches

Use the current watershed GeoPackage:

```bash
Rscript workflow/gee/build_gee_vector_payloads.R \
  --watersheds PATH/TO/watersheds.gpkg \
  --output-root PATH/TO/era5-payloads \
  --payload-prefix era5 \
  --simplification-profile coarse-1km \
  --expected-site-count SITE_COUNT \
  --analysis-scale-m 11100 \
  --time-slices-per-task 31 \
  --bands-per-slice 6
```

## Plan and submit one task

Run the export script without `--submit` first:

```bash
python3 workflow/gee/era5_land/run_safe_era5_land_exports.py \
  --payload-manifest PATH/TO/payload_manifest.csv \
  --output-folder projects/PROJECT/assets/era5_land_daily \
  --run-label RELEASE_NAME \
  --period daily \
  --years 2000:2025 \
  --max-new-tasks 1
```

The script prints the safety-check command. Run it, then repeat the same
command with `--submit --preflight-receipt PATH`. Check the completed
task and its Earth Engine cost before raising the task limit.

## Make local summaries

```bash
Rscript workflow/gee/era5_land/aggregate_daily_era5_land.R \
  --daily-input PATH/TO/daily-csv-files \
  --output-root PATH/TO/era5-summaries
```

Add `--write-weekly true` only when a weekly analysis is needed. A month or
week with missing days is marked incomplete rather than silently averaged.
