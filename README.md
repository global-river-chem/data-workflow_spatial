# Spatial Data Workflow

Google Earth Engine spatial data workflow for the global river chemistry project.

This repo is for the new spatial extraction workflow. The older AppEEARS/NASA workflow stays in `lterwg-silica-spatial`.

Current contents:
- `scripts/prepare-shapefiles-for-gee.R`: prepares watershed shapefiles for Google Earth Engine upload
- `gee-code/derive-western-australia.js`: draft GEE script for Western Australia watershed checks

Next work:
- confirm watershed assets and site naming
- build GEE extraction scripts for selected spatial drivers
- export raw GEE outputs
- add simple checks before harmonization
