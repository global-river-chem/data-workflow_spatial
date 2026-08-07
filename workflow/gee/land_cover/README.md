# GLC-FCS30D land-cover extraction

This workflow summarizes the 30 m GLC-FCS30D maps for 1985, 1990, 1995, and
2000–2022. Human-impact variables use a separate Earth Engine workflow.

Small watersheds use every 30 m pixel. Large watersheds use a fixed set of
points created locally. The same points are reused for every year, making the
result reproducible while keeping Earth Engine work within a known limit.

Do not rerun the older notebook or the archived `other_targets` queue. Those
runs did not limit work by watershed size.

## Build watershed inputs

```bash
Rscript workflow/gee/build_gee_vector_payloads.R \
  --watersheds PATH/TO/watersheds.gpkg \
  --output-root PATH/TO/glc-payloads \
  --payload-prefix glc \
  --property-prefix glc \
  --simplification-profile coarse-1km \
  --maximum-area-error-pct 0.1 \
  --expected-site-count SITE_COUNT
```

Create local sample points for watersheds that are too large for a full pixel
count. This step does not use Earth Engine.

```bash
Rscript workflow/gee/land_cover/build_local_glc_sample_points.R \
  --watersheds PATH/TO/watersheds.gpkg \
  --output-root PATH/TO/glc-local-points \
  --sample-points 10000 \
  --exact-max-work 260000 \
  --expected-sampled-sites SAMPLED_SITE_COUNT
```

## Export annual class areas

Run without `--submit` first. The script prints the quota check required for
the selected task. After that check succeeds, repeat the same command with
`--submit --preflight-receipt PATH`. Start with one task and review its result
and Earth Engine cost before allowing a larger batch.

```bash
python3 workflow/gee/land_cover/run_safe_glc_fcs30d_exports.py \
  --manifest PATH/TO/payload_manifest.csv \
  --local-point-manifest PATH/TO/glc-local-points/point_sample_manifest.csv \
  --project PROJECT \
  --run-label RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT \
  --max-new-tasks 1
```

Each output records whether it used a full pixel count or local sample. Sampled
outputs also record the point file and sample size used for that watershed.

## Export only major land cover

Use the major-land script when an analysis only needs the dominant simplified
class. It calculates that result in Earth Engine, so annual class tables do not
need to be downloaded first.

The calculation matches the 1900–2022 harmonized record. The 1985 map
represents 88 years, the 1990 and 1995 maps represent five years each, the 2000
map represents three years, and each 2001–2022 map represents one year. Source
classes are then combined with the simplified land-cover crosswalk. Classes 0
and 184 are not candidates for major land cover, but they remain in the yearly
total used to calculate fractions.

If classes tie for the largest weighted fraction, the export keeps every tied
class and marks the tie. It does not choose one arbitrarily.

Use a run label reserved for major-land results, such as
`major_land_RELEASE_NAME`. This keeps annual and major-land assets distinct
while preserving the task names used by the current run.

```bash
python3 workflow/gee/land_cover/run_safe_glc_major_land_exports.py \
  --manifest PATH/TO/payload_manifest.csv \
  --local-point-manifest PATH/TO/glc-local-points/point_sample_manifest.csv \
  --project PROJECT \
  --run-label major_land_RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT \
  --max-new-tasks 1
```

## Check and download results

Both consolidation scripts report completed and missing assets without
downloading anything. Add `--download` only after every expected asset exists.

Annual sampled output must contain at least 99% of the requested points. After
review, a different cutoff can be set with
`--minimum-sample-fraction FRACTION`.

Annual class areas:

```bash
Rscript workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.R \
  --manifest PATH/TO/payload_manifest.csv \
  --project PROJECT \
  --run-label RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT
```

Major land cover:

```bash
Rscript workflow/gee/land_cover/consolidate_safe_glc_major_land_exports.R \
  --manifest PATH/TO/payload_manifest.csv \
  --project PROJECT \
  --run-label major_land_RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT
```

The consolidators apply the rules in `shared_watershed_aliases.csv` after the
downloaded rows pass validation. The current rule copies the complete accepted
S65B watershed result to S65C. It does not divide the result between sites.
