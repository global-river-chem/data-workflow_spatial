# Spatial Data Workflow

This repository contains the Earth Engine, watershed, harmonization, and final
spatial-data assembly used by the global river chemistry project. AppEEARS
requests and local MODIS work stay in `lterwg-silica-spatial`.

## Dataset assembly

Use `workflow/release/build_spatial_dataset_files.R` to build the Updated annual
release. For an offline build, pass `--combined-input`, `--metadata`,
`--glass-input` (read-only), `--saved-input`, and `--output-root` pointing to
a new folder. The builder checks source matches and writes eight product tables
and one site metadata table. `update_new_spatial_dataset.R` applies the source
selection rules to the combined input. The BESS and saved-result recovery scripts
prepare upstream inputs.

To include the verified CAMREX additions, supply all four inputs together. Each
is a data frame saved as RDS or a CSV with the matching release table headers.

| Option | Input table |
| --- | --- |
| `--camrex-bess-input` | BESS GPP values, coverage, and reliability fields |
| `--camrex-npp-input` | MODIS NPP values, gap-filling percentages, and match status |
| `--camrex-greenup-input` | Both MODIS greenup cycles, separate coverage percentages and flags, and match status |
| `--camrex-coverage-input` | Site metadata with CAMREX coverage and corrected Ferguson notes |

Product tables can contain just the six CAMREX rows. Each needs `LTER`,
`Stream_Name`, `Latitude`, and `Longitude` for the watershed checks. Include the
corrected Ferguson metadata row when Ferguson is in the build. Ferguson land
cover and static predictors and the full CAMREX ERA5-Land record remain pending.

## Main entry points

- `workflow/build_watershed_collection.R` builds the current watershed layer
  from the finalized site table and exact spatial-data version folders.
- `workflow/watershed_delineation/` contains reusable source-specific
  delineation tools. Site-specific outlet or source IDs live in small TSV
  files under its `config/` folder.
- `workflow/gee/` contains the safe ERA5-Land, human-impact, and GLC-FCS30D
  workflows.
- `workflow/appeears/` groups reviewed area requests and assembles checked
  MODIS summary tables.
- `workflow/aurora/stage_selected_watersheds.R` prepares checked watershed
  bundles for the Aurora extraction workflow.
- `workflow/release/build_spatial_dataset_files.R` splits the checked
  harmonized inputs into product-specific release files and one site metadata
  file. Public files join on `LTER` and `Stream_Name`. Predictor files repeat
  only coordinates, drainage area, and the site flag; source, watershed,
  discharge, version, and note fields are kept in the site metadata file.
- `workflow/build_updated_watershed_asset.py` merges checked additions into an
  existing Earth Engine watershed asset without hard-coded row counts.
- `workflow/site_reference/audit_wrtds_eligibility.R` checks every site against
  the current WRTDS input rules while retaining manual `Use_WRTDS` decisions.

The release builder now requires `--chemistry` with the finalized master,
`--data-root` with the shared spatial-data extraction folder, and
`--land-cover-key` with the existing full-to-simple class translation. Its
`recover_saved_spatial_results.R` helper uses the chemistry site list and the
current reference table. It fills missing cells from the reviewed July MODIS
chunks and saved land-cover results without replacing existing values. Land
cover is recovered only for observed source years; intervening years remain
blank rather than receiving a new interpolation. Sites marked as having no
spatial data remain in the site list with blank predictors. The metadata
records recovered results and missing ERA5-Land values. Human impacts and
distance to coast use verified watershed matches. Ferguson uses the corrected
boundary; predictors without a matching extraction remain blank.

Product and asset settings are under `config/`; generated exports and
temporary files do not belong in this checkout. Write them directly to the
shared spatial-data extraction folder or another explicit external path.

## Reviewed StreamStats recovery

The StreamStats recovery accepts watersheds only for the eight sites in the
reviewed validation table. Pass that tracked table explicitly so the evidence
used for acceptance is reproducible.

```bash
Rscript workflow/watershed_delineation/recover_streamstats_watersheds.R \
  --audit /path/to/watershed-site-audit.tsv \
  --existing-watersheds /path/to/accepted-watersheds.gpkg \
  --validation workflow/watershed_delineation/config/streamstats_reviewed_validation.tsv \
  --output-root /path/to/streamstats-review \
  --shapefile-root /path/to/spatial-data
```

## Verified boundary updates

The [corrected Ferguson boundary on Drive](https://drive.google.com/file/d/1ICybKkvH3i-HI9LdBXZv9KO9ksFGO0fT/view) contains 25 connected BoM network catchments, covering 104.973609 km² above station 611026. The same file, `ferguson_611026_verified.gpkg`, is in Box under `SiSyn/spatial-data-extractions/spatial-data/`. Boundary data are not included in Git. The area matches BoM's upstream drainage area, the sampling point is inside, and the polygon is valid. The original HydroBASINS shapefile is unchanged.

When Ferguson is included, the watershed builder and spatial release download this file from shared Drive and keep it in R's user cache outside the repository. The first download requires access through `googledrive`. Later runs use the cached file. Both scripts also accept `--boundary-updates` followed by the path to the Box copy; `SISYN_BOUNDARY_UPDATES` provides the same setting. `--download-boundary false` allows cached or explicitly supplied files only. Every load checks the file against the reviewed checksum. If the file is missing, changed, or cannot be downloaded, the run stops instead of using the old polygon.

The spatial release does not reuse Ferguson's old predictors, because they describe the oversized watershed. ERA5-Land for 2000–2025 has been recovered using the corrected boundary. Other predictors stay blank with a metadata note until they are extracted again. Loading this boundary does not start any extraction or upload.

## WRTDS site audit

The WRTDS audit retains every manual `Use_WRTDS` decision. An optional decision
table can fill blank rows only when a separate decision-check table supports
the same result; conflicting or unchecked values stay review items. Remaining
blank rows receive a proposed `Yes` only when the supplied chemistry and
discharge inputs are ready. Manual `Use_WRTDS = Yes` records intended inclusion;
it does not mean the current files are fully ready. `WRTDS_Readiness_Status`
stays on hold until chemistry basis, units, censoring, ambiguous site aliases,
discharge gaps, nonpositive values, duplicate dates, date buffers, and cropping
instructions are resolved or documented. Valid year crops are applied before
the checks.
Blank-time chemistry instructions, discharge rows marked for removal, and
discharge gaps of 30 days or longer remain blockers because the current WRTDS
scripts do not safely resolve them. The audit accepts the discharge units
converted by the harmonization workflow: `cms`, `cfs`, `Ls`, `cmh`, and `cmd`.

```bash
Rscript workflow/site_reference/audit_wrtds_eligibility.R \
  --site-reference /path/to/site-reference.csv \
  --decision-reference /path/to/reviewed-site-decisions.csv \
  --decision-check /path/to/independent-wrtds-check.tsv \
  --chemistry-cropping /path/to/Data_Cropping_WRTDS.xlsx \
  --discharge-cropping /path/to/Discharge_Cropping_WRTDS.xlsx \
  --chemistry /path/to/master-chemistry.csv \
  --discharge /path/to/master-discharge.csv \
  --discharge-dir /path/to/additional-discharge-files \
  --output /path/to/wrtds-eligibility.tsv
```

Run `Rscript workflow/site_reference/audit_wrtds_eligibility.R --self-test`
to check the decision-preservation and new-site rules without writing output.

## Final coverage checks

The final annual file is checked against every spatial site and every available
driver year from 2002–2025. GLC-FCS30D ends in 2022 and is not extended into
later years. Coverage reports keep source limits separate from extraction
failures.

## Offline release assembly check

Run from the repository root to check source matching and file protection.

```bash
Rscript workflow/release/tests/test_dataset_assembly.R
```
