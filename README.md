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
- `workflow/build_updated_watershed_asset.py` merges checked additions into an
  existing Earth Engine watershed asset without hard-coded row counts.

Progress notes are kept in [PROGRESS_UPDATES.md](PROGRESS_UPDATES.md). Product
and asset settings are under `config/`; generated exports and temporary files
do not belong in Git.

## Final coverage checks

The final annual file is checked against every spatial site and every available
driver year from 2002–2025. GLC-FCS30D ends in 2022 and is not extended into
later years. Coverage reports keep source limits separate from extraction
failures.
