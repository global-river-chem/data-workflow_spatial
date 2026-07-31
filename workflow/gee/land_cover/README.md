# GLC-FCS30D land-cover extraction

This workflow extracts the 30 m GLC-FCS30D land-cover product for 1985, 1990,
1995, and 2000–2022. Human-impact variables are handled by their own Earth
Engine workflow; they are not part of the Aurora extraction.

Large watersheds cannot be scanned repeatedly at 30 m within a reasonable
quota. The export script therefore uses exact pixels for smaller watersheds
and a fixed, reproducible sample for larger ones. Both methods use the same
source product and retain method and sample-size fields in the output.

Do not rerun the older notebook or the archived `other_targets` queue. Those
runs did not bound work by watershed size.

## Build watershed batches

```bash
Rscript workflow/gee/build_gee_vector_payloads.R \
  --watersheds PATH/TO/watersheds.gpkg \
  --output-root PATH/TO/glc-payloads \
  --payload-prefix glc \
  --property-prefix glc \
  --simplification-profile fine-30m \
  --expected-site-count SITE_COUNT
```

## Plan and submit one task

```bash
python3 workflow/gee/land_cover/run_safe_glc_fcs30d_exports.py \
  --manifest PATH/TO/payload_manifest.csv \
  --project PROJECT \
  --run-label RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT \
  --max-new-tasks 1
```

This is a dry run. Follow the printed safety-check command, then repeat the
same launch with `--submit --preflight-receipt PATH`. Review the first result
and its Earth Engine cost before submitting more tasks.

## Download and check the complete run

```bash
python3 workflow/gee/land_cover/consolidate_safe_glc_fcs30d_exports.py \
  --manifest PATH/TO/payload_manifest.csv \
  --project PROJECT \
  --run-label RELEASE_NAME \
  --method auto \
  --expected-site-count SITE_COUNT
```

Add `--download` only after the status check reports no missing assets. The
combined file retains the land-cover method, sample count, and uncertainty
fields needed for review.
