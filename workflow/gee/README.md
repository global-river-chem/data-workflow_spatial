# Google Earth Engine workflows

This folder contains the Earth Engine work used by the spatial data workflow.
It covers ERA5-Land climate data, human impacts, and GLC-FCS30D land cover.
AppEEARS work stays in `lterwg-silica-spatial`.

Generated batch files, downloaded exports, credentials, and status files should
not be committed. Keep them in `generated_outputs/` or shared storage.

## Product strategy

Use GEE now for GLC-FCS30D, the six ERA5-Land variables, and human impacts.
Reuse a prior GEE result only when the current site points to the same
watershed file and spatial-data version; build the remaining target set with
`build_incremental_targets.R`.

Keep MODIS NPP and greenup day in the established AppEEARS workflow for the
current final release. A future GEE port should run as a small overlap study
first and match the AppEEARS QA masks, watershed reducer, phenology-cycle
selection, and date conversion before it replaces those outputs.

## Standard workflow

### Build the current watershed file

Build the GeoPackage from the finalized site table and versioned watershed
library. Divide it into balanced input batches with
`build_gee_vector_payloads.R`.

### Check one export

Run the export script without `--submit`, then run the safety check printed by
the script. Submit that same task with the generated safety file and check its
result and Earth Engine cost.

### Finish the run

Raise the task limit only after the first export passes review. Download and
validate the complete set before using it in the combined spatial file.

The export scripts limit both task size and task count. Do not bypass those
checks. For a new or changed workflow, start with one task.

## Entry points

| Data | Script |
|---|---|
| Build watershed batches | `build_gee_vector_payloads.R` |
| Exclude accepted prior coverage | `build_incremental_targets.R` |
| ERA5-Land | `era5_land/run_safe_era5_land_exports.py` |
| Build local GLC sample points | `land_cover/build_local_glc_sample_points.R` |
| Monthly or weekly ERA5 summaries | `era5_land/aggregate_daily_era5_land.R` |
| GLC-FCS30D land cover | `land_cover/run_safe_glc_fcs30d_exports.py` |
| Download and check GLC results | `land_cover/consolidate_safe_glc_fcs30d_exports.py` |
| Human impacts for missing sites | `human_impacts/run_missing_site_exports.py` |
| Organize completed Drive exports | `post_export/organize_gee_exports_in_drive.R` |
| Compare annual exports with an earlier run | `post_run_qa/run_old_vs_gee_annual_comparison_qa.R` |
| Quota safety check | `gee_quota_preflight.py` |
| Monitor running tasks | `gee_task_watchdog.py` |

Use `workflow/build_updated_watershed_asset.py` when a checked additions asset
must be merged with an existing Earth Engine watershed asset. It derives all
row counts from the supplied local GeoJSON files.

See the ERA5-Land and land-cover READMEs for short command examples.
