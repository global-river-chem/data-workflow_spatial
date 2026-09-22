# Spatial Data Workflow

This repository contains the Earth Engine, watershed, harmonization, and final
spatial-data assembly used by the global river chemistry project. AppEEARS
requests and local MODIS work stay in `lterwg-silica-spatial`.

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
  harmonized inputs into product-specific release files.
- `workflow/build_updated_watershed_asset.py` merges checked additions into an
  existing Earth Engine watershed asset without hard-coded row counts.
- `workflow/site_reference/audit_wrtds_eligibility.R` checks every site against
  the current WRTDS input rules while retaining manual `Use_WRTDS` decisions.

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
