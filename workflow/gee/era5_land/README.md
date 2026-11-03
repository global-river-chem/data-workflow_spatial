# ERA5-Land extraction

The workflow supports the accepted annual 2000–2025 ERA5-Land run and a
separate daily per-watershed dataset for sequence models. Annual exports keep
the established six products. Daily exports use 13 products:
precipitation, mean/minimum/maximum temperature, evapotranspiration, potential
evaporation, snow cover, snow-water equivalent, runoff, incoming solar energy,
shallow and deep soil water, and vapor pressure derived from dew point.

The current daily run keeps one row for each watershed and date. For every
product, it records the spatial mean, median, minimum, maximum, and population
standard deviation across valid grid cells within that watershed. These 65
exported statistics, plus two locally derived humidity estimates, preserve the
daily sequence while describing variation within the watershed. They are not
monthly or weekly summaries, and the output does not contain one row per pixel.
Minimum and maximum values are grid-cell extremes and can be more sensitive to
watershed size than the other statistics.

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

## Daily sequence run

Build a fresh full watershed collection from the accepted spatial table. The
builder checks the supplied geometry libraries in order, so place the primary
library first and any approved fallback library after it. Daily payloads use a
31-day, 13-band workload estimate. Sites without an accepted watershed cannot
be included and should remain explicit in the coverage report:

```bash
Rscript workflow/gee/build_gee_vector_payloads.R \
  --watersheds PATH/TO/current_watersheds.gpkg \
  --output-root PATH/TO/era5-daily-payloads \
  --payload-prefix era5_daily \
  --simplification-profile coarse-1km \
  --expected-site-count SITE_COUNT \
  --analysis-scale-m 11100 \
  --time-slices-per-task 31 \
  --bands-per-slice 13
```

Plan and submit one month first. The spatial-statistics option explicitly
requests all five within-watershed statistics. Omitting it retains the older
mean-only daily format:

```bash
python3 workflow/gee/era5_land/run_safe_era5_land_exports.py \
  --payload-manifest PATH/TO/payload_manifest.csv \
  --output-folder projects/PROJECT/assets/era5_land_daily_watershed_stats_1984_2025 \
  --run-label DAILY_SPATIAL_STATS_RUN_NAME \
  --period daily \
  --years 1984:2025 \
  --months 1:12 \
  --spatial-statistics mean,median,min,max,sd \
  --expected-site-count SITE_COUNT \
  --expected-site-ids PATH/TO/site_aliases.tsv \
  --max-new-tasks 1
```

Each exported row also includes `watershed_area_km2`, `native_pixel_count`,
`reduction_scale_m`, and `used_fine_scale_fallback`. The native reduction uses
an 11.1 km scale. If any requested product has no valid native-scale cell for a
watershed-day, the whole row is recalculated at 1.11 km so its statistics use a
consistent scale. Very small watersheds may therefore have identical summary
values and a standard deviation of zero.

After the first asset passes row, range, snow-scale, and Earth Engine cost
checks, finish missing tasks in checked batches with
`finish_missing_era5_land_assets.py`. Its safe defaults run one task batch and
stop; use `--max-batches 0` only after the new workflow has passed review.
For a long unattended run, `--max-batch-retries 2` retries ordinary failed
tasks after replanning, but never retries a cost-watchdog cancellation.

Download the completed assets as checked, compressed yearly tables:

```bash
Rscript workflow/gee/era5_land/download_daily_era5_land_assets.R \
  --folder projects/PROJECT/assets/era5_land_daily_watershed_stats_1984_2025 \
  --asset-prefix era5d13s5_ \
  --site-aliases PATH/TO/site_aliases.tsv \
  --output-root PATH/TO/era5-daily-data \
  --spatial-statistics mean,median,min,max,sd \
  --years 1984:2025
```

The downloader requires one row per unique watershed and date, preserves leap
days, checks physical ranges and the ordering of the five statistics, and
expands shared watersheds back to site rows. It also checks the native pixel
count, reduction scale, and fallback flag before writing yearly tables.

The downloader also adds two daily humidity estimates without starting new
Earth Engine tasks:
`relative_humidity_percent_from_spatial_means` and
`vapor_pressure_deficit_kpa_from_spatial_means`. It calculates mean daily
saturation vapor pressure from the watershed spatial means of daily minimum
and maximum air temperature, then combines it with watershed mean actual vapor
pressure. Relative humidity is limited to 0–100 percent and vapor-pressure
deficit to values at or above zero.

These two fields are useful watershed-day atmospheric-demand estimates, but
they are not exact spatial means. The exported temperature and vapor-pressure
statistics do not preserve the paired grid-cell values needed to reconstruct
the exact mean, median, minimum, maximum, or standard deviation of a nonlinear
humidity calculation. Exact spatial statistics would require calculating the
humidity bands for each grid cell in Earth Engine and exporting them again.

## Optional daily summaries

Keep the checked daily tables as the source data. The five values for each
driver summarize space within a watershed on a single day; they do not
summarize across days. Derive monthly or weekly summaries only when a separate
analysis needs them:

```bash
Rscript workflow/gee/era5_land/aggregate_daily_era5_land.R \
  --daily-input PATH/TO/daily-csv-files \
  --output-root PATH/TO/era5-summaries
```

Add `--write-weekly true` only when a weekly analysis is needed. A month or
week with missing days is marked incomplete rather than silently averaged.
