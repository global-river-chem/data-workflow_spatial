# ERA5-Land extraction

The final workflow extends the accepted annual 2000–2025 ERA5-Land run instead
of rerunning unchanged sites. Its six products are precipitation, temperature,
evapotranspiration, potential evaporation, snow cover, and snow-water
equivalent.

Annual precipitation and evaporation use sums, temperature uses a mean, and
snow cover and snow-water equivalent use maxima. Snow cover is converted from
percent to a 0–1 fraction. ERA5-Land stores evaporation as a negative flux, so
the export reports positive evapotranspiration. A blank native-scale polygon
reduction retries the same polygon at a finer scale; it never substitutes a
centroid pixel. The row geometry is the watershed centroid only to keep the
Earth Engine table asset lightweight.

For the current release, reuse accepted annual outputs only where the current
watershed file and spatial-data version are unchanged. Build payloads from the
incremental target GeoPackage and validate them against the incremental site
inventory, not the full current alias table.

## Build watershed batches

Use the audited incremental watershed GeoPackage:

```bash
Rscript workflow/gee/build_gee_vector_payloads.R \
  --watersheds PATH/TO/era5_human_incremental_targets.gpkg \
  --output-root PATH/TO/era5-payloads \
  --payload-prefix era5 \
  --simplification-profile coarse-1km \
  --expected-site-count SITE_COUNT \
  --analysis-scale-m 11100 \
  --time-slices-per-task 366 \
  --bands-per-slice 6
```

## Plan and submit one task

Run the export script without `--submit` first:

```bash
python3 workflow/gee/era5_land/run_safe_era5_land_exports.py \
  --payload-manifest PATH/TO/payload_manifest.csv \
  --output-folder projects/PROJECT/assets/era5_land_incremental \
  --run-label RELEASE_NAME \
  --period annual \
  --years 2000:2025 \
  --expected-site-count INCREMENTAL_SITE_COUNT \
  --expected-site-ids PATH/TO/incremental_site_inventory.csv \
  --max-new-tasks 1
```

The script prints the safety-check command. Run it, then repeat the same
command with `--submit --preflight-receipt PATH`. Check the completed
task and its Earth Engine cost before raising the task limit.

The launcher requires payload IDs to match the supplied target set exactly.
Annual tasks are ordered by year across every payload so the incremental sites
advance together. Combine the completed incremental assets with the accepted
prior annual assets only after confirming that reused and newly extracted IDs
are disjoint and together equal the full current watershed set.

## Optional daily summaries

Daily export is not the final annual workflow. Use it only when monthly or
weekly values are explicitly needed, and keep its assets separate from annual
production.

```bash
Rscript workflow/gee/era5_land/aggregate_daily_era5_land.R \
  --daily-input PATH/TO/daily-csv-files \
  --output-root PATH/TO/era5-summaries
```

Add `--write-weekly true` only when a weekly analysis is needed. A month or
week with missing days is marked incomplete rather than silently averaged.
