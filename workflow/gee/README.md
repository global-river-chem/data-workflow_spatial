# Google Earth Engine workflows

This folder contains the Earth Engine work used by the spatial data workflow.
It covers ERA5-Land climate data, human impacts, GLC-FCS30D land cover, and
the checked MODIS fallback used when AppEEARS does not provide usable summary
tables. AppEEARS request and summary scripts are in `workflow/appeears`.

Generated batch files, downloaded exports, credentials, and status files should
not be created in this checkout. Pass an output path in the shared spatial-data
extraction folder or another external work directory.

## Product strategy

Use GEE now for GLC-FCS30D, the six ERA5-Land variables, and human impacts.
Reuse a prior GEE result only when the current site points to the same
watershed file and spatial-data version; build the remaining target set with
`build_incremental_targets.R`.

Use AppEEARS for MODIS ET, NPP, and green-up when its area summary tables are
available. Use the checked GEE parity workflow for the bit-packed MOD10A2 snow
product and for missing AppEEARS summaries. Do not mix the two sources within
one product without first checking an overlap set.

## Standard workflow

### Build the current watershed file

Build the GeoPackage from the finalized site table and versioned watershed
library. Divide it into balanced input batches with
`build_gee_vector_payloads.R`.

### Check one export

Run the export script without `--submit`, then run the safety check printed by
the script. Submit that same task with the generated safety file and check its
result and Earth Engine cost.

For an unmeasured workflow, add `--watchdog-cancel-eecu-hours HOURS` to the
printed safety command when a stricter first-task cap is warranted. The option
can lower but cannot raise the automatic watchdog threshold.

### Finish the run

Raise the task limit only after the first export passes review. Download and
validate the complete set before using it in the combined spatial file.

The export scripts limit both task size and task count. Do not bypass those
checks. For a new or changed workflow, start with one task.

Local preparation, quota accounting, monitoring, consolidation, and QA are R
workflows. Python is reserved for launchers that construct and submit Earth
Engine computations.

## Entry points

| Data | Script |
|---|---|
| Build watershed batches | `build_gee_vector_payloads.R` |
| Exclude accepted prior coverage | `build_incremental_targets.R` |
| ERA5-Land | `era5_land/run_safe_era5_land_exports.py` |
| Build local GLC sample points | `land_cover/build_local_glc_sample_points.R` |
| Monthly or weekly ERA5 summaries | `era5_land/aggregate_daily_era5_land.R` |
| Finish missing annual ERA5 assets | `era5_land/finish_missing_annual_assets.py` |
| GLC-FCS30D land cover | `land_cover/run_safe_glc_fcs30d_exports.py` |
| GLC-FCS30D major land cover | `land_cover/run_safe_glc_major_land_exports.py` |
| Download and check GLC results | `land_cover/consolidate_safe_glc_fcs30d_exports.R` |
| Download and check major land cover | `land_cover/consolidate_safe_glc_major_land_exports.R` |
| Human impacts for missing sites | `human_impacts/run_missing_site_exports.py` |
| MODIS parity summaries | `modis/run_safe_modis_parity_exports.py` |
| Finish missing MODIS assets | `modis/finish_missing_modis_assets.py` |
| Consolidate MODIS assets | `modis/consolidate_modis_parity_exports.R` |
| Organize completed Drive exports | `post_export/organize_gee_exports_in_drive.R` |
| Compare annual exports with an earlier run | `post_run_qa/run_old_vs_gee_annual_comparison_qa.R` |
| Quota safety check | `gee_quota_preflight.R` |
| Monitor running tasks | `gee_task_watchdog.R` |

Use `workflow/build_updated_watershed_asset.py` when a checked additions asset
must be merged with an existing Earth Engine watershed asset. It derives all
row counts from the supplied local GeoJSON files.

See the ERA5-Land and land-cover READMEs for short command examples.
