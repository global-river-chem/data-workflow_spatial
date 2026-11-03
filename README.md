# Spatial Data Workflow

This repository contains the Earth Engine, watershed, harmonization, and final
spatial-data assembly used by the global river chemistry project. AppEEARS
requests and local MODIS work stay in `lterwg-silica-spatial`.

BESSv2 GPP is the gross primary productivity source in the updated dataset.
The verified 1982–2022 release has 42,886 annual BESS values across 1,046 sites.
It retains original values, including zeros, along with coverage and trend flags.
The new NDVI and replacement greenup effort is discontinued. No further pilots, full
downloads, or additions of those predictors are planned.

The GLASS file dated `20261015` remains unchanged. The updated file dated
`20261028` uses ERA5-Land for overlapping climate, ET, and snow products, and
includes BESS GPP, MODIS NPP, MODIS greenup, and verified saved human and river results.

The completed vegetation pilots are outside the Updated release.

## Product information

### Glass dataset

| Data product | Variable | Resolution and source details | Period or timing | Units and summary |
|---|---|---|---|---|
| MODIS Terra MOD16A2GF v6.1 | Evapotranspiration | NASA LP DAAC; 500 m; gap-filled eight-day ET composites, accessed through AppEEARS | 2001-2025; annual totals and monthly climatology | kg water/m² (equivalent to mm); mean across watershed pixels; composite totals distributed to days, then summed |
| MODIS Terra MOD17A3HGF v6.1 | Net primary production | NASA LP DAAC; 500 m; annual gap-filled NPP, accessed through AppEEARS | 2001-2025; annual | kg C/m²/year; mean annual NPP across valid watershed pixels; invalid values excluded |
| MODIS Terra MOD10A2 v6.1 | Snow cover | NASA NSIDC DAAC; 500 m; eight-day maximum snow extent and daily snow chronology bits | 2002-2025; annual and monthly climatology | Days with snow; annual maximum watershed snow-area fraction; monthly mean snow-area fraction |
| MODIS Terra and Aqua MCD12Q2 v6.1 | Greenup dates | NASA LP DAAC; 500 m; annual land-surface phenology; Greenup_1 and Greenup_2 mark 15% of seasonal EVI2 amplitude | 2001-2024; up to two cycles each year | Calendar dates; watershed mean of valid pixel dates, rounded down to a whole day; cycles kept separately |
| GPCP Monthly Precipitation CDR v2.3 | Precipitation | NOAA NCEI; merged satellite and rain-gauge observations; monthly 2.5° grid; doi:10.7289/V56971M6 | 1979-2025 in this dataset; annual means and monthly climatology | mm/day; watershed mean of grid cells, then mean of monthly rates; annual values are mean daily rates, not totals |
| GHCN_CAMS Gridded 2 m Temperature (Land) | Air temperature | Global Historical Climatology Network and Climate Anomaly Monitoring System; NOAA PSL; 0.5° grid; monthly 2 m land-air temperature | 1948-2025 in this dataset; monthly inputs, annual means, and monthly climatology | °C; watershed mean of monthly grid cells, then mean across months. Original source: psl.noaa.gov/data/gridded/data.ghcncams.html |
| WorldClim v2.1 | Elevation | Global elevation grid wc2.1_30s_elev.tif; 30 arcseconds (about 1 km at the equator) | Static | m above sea level; watershed mean, median, minimum, and maximum |
|  | Basin slope | Slope calculated from the WorldClim elevation grid using terra terrain; surrounding cells retained for calculation | Static | Degrees; watershed mean, median, minimum, and maximum |
| Global Lithological Map (GLiM) | Lithology | Global rock-type map; 0.5-degree raster glim_wgs84_0point5deg.txt.asc; source classes grouped into broader rock types | Static | Dominant rock class and fractions of watershed pixels in each rock group |
| OpenLandMap USDA soil taxonomy | Soil orders | 250 m soil-suborder grid TAXOUSDA_250m_suborder_classes.tif; suborders grouped into USDA soil orders using the classification lookup table | Static | Dominant soil order and fractions of watershed pixels in each soil order |
| GlobPermafrost PERPROB (Obu et al., 2018) | Permafrost occurrence probability | AWI / PANGAEA Northern Hemisphere permafrost map; 1 km grid; doi:10.1594/PANGAEA.888600 | Static; modeled for 2000-2016; Northern Hemisphere land north of 25°N | Fraction (0-1); watershed mean, median, minimum, maximum. Original values unchanged; legacy _m suffix does not mean meters |
| Global Land Cover with Fine Classification System (GLC-FCS30D) | Land cover | Landsat-based global land-cover maps; 30 m; detailed source classes combined into eleven land-cover groups | 1985-2022; observed source years | Percent of watershed area in each of eleven land-cover groups; years without source observations remain missing |

### Updated dataset

| Data product | Variable | Resolution and source details | Period or timing | Units and summary |
|---|---|---|---|---|
| BESSv2 | Annual GPP | 0.05 degrees; monthly NetCDF | 1982-2022; annual | g C/m²/year; retain valid days, area fraction, and source-zero flags |
| ERA5-Land | Precipitation | About 11.1 km; daily aggregates | 2000-2025; annual | mm; annual sum, watershed mean |
|  | Mean air temperature | About 11.1 km; daily aggregates | 2000-2025; annual | °C; annual and watershed mean |
|  | Evapotranspiration | About 11.1 km; daily aggregates | 2000-2025; annual | mm; sign corrected annual sum |
|  | Potential evaporation | About 11.1 km; daily aggregates | 2000-2025; annual | mm; sign corrected annual sum |
|  | Snow cover | About 11.1 km; daily aggregates | 2000-2025; annual | Fraction; annual maximum image, watershed mean |
|  | Snow water equivalent | About 11.1 km; daily aggregates | 2000-2025; annual | mm; annual peak watershed mean |
| LandScan Global | Ambient population | Oak Ridge National Laboratory; about 1 km; annual ambient population grids | 2000-2024; annual | People and people/km²; retain data coverage fractions |
| Global Dam Watch v1.0 | Dams | Global Dam Watch barrier locations; counts and capacity attributes within each watershed | 2024 release; static | Count, density per 1,000 km², storage in million m³, hydropower in MW; retain record counts |
| NPKGRIDS | Fertilizer application index | About 5.6 km; crop-rate layers | Circa 2020; static | N, P₂O₅, K₂O rate-sum indices in kg/ha; not total fertilizer mass; retain crop-layer counts |
| HydroWASTE v1.0 | Wastewater treatment plants | HydroWASTE wastewater-treatment plant locations and attributes within each watershed | 2022 release; static | Counts, density, population served, discharge in m³/day, treatment classes; retain record counts |
| HydroRIVERS routing | Distance to coast and outlet | HydroRIVERS river reaches; downstream network distances from the matched reach to outlet and ocean | Static | km; retain match status and routing diagnostics; ocean distance missing for closed basins |
| MODIS Terra MOD17A3HGF v6.1 | Net primary production | NASA LP DAAC; 500 m; annual gap-filled NPP, accessed through AppEEARS | 2001-2025; annual | kg C/m²/year; mean annual NPP across valid watershed pixels; invalid values excluded |
| MODIS Terra and Aqua MCD12Q2 v6.1 | Greenup dates | NASA LP DAAC; 500 m; annual land-surface phenology; Greenup_1 and Greenup_2 mark 15% of seasonal EVI2 amplitude | 2001-2024; up to two cycles each year | Calendar dates; watershed mean of valid pixel dates, rounded down to a whole day; cycles kept separately |
| Global Land Cover with Fine Classification System (GLC-FCS30D) | Land cover | Landsat-based global land-cover maps; 30 m; detailed source classes combined into eleven land-cover groups | 1985-2022; observed source years | Percent of watershed area in each of eleven land-cover groups; years without source observations remain missing |
| WorldClim v2.1 | Elevation | Global elevation grid wc2.1_30s_elev.tif; 30 arcseconds (about 1 km at the equator) | Static | m above sea level; watershed mean, median, minimum, and maximum |
|  | Basin slope | Slope calculated from the WorldClim elevation grid using terra terrain; surrounding cells retained for calculation | Static | Degrees; watershed mean, median, minimum, and maximum |
| Global Lithological Map (GLiM) | Lithology | Global rock-type map; 0.5-degree raster glim_wgs84_0point5deg.txt.asc; source classes grouped into broader rock types | Static | Dominant rock class and fractions of watershed pixels in each rock group |
| OpenLandMap USDA soil taxonomy | Soil orders | 250 m soil-suborder grid TAXOUSDA_250m_suborder_classes.tif; suborders grouped into USDA soil orders using the classification lookup table | Static | Dominant soil order and fractions of watershed pixels in each soil order |
| GlobPermafrost PERPROB (Obu et al., 2018) | Permafrost occurrence probability | AWI / PANGAEA Northern Hemisphere permafrost map; 1 km grid; doi:10.1594/PANGAEA.888600 | Static; modeled for 2000-2016; Northern Hemisphere land north of 25°N | Fraction (0-1); watershed mean, median, minimum, maximum. Original values unchanged; legacy _m suffix does not mean meters |

The GLASS file dated `20261015` remains unchanged (1,111 sites, 942 columns).
It already contains some ERA5-Land and GLC additions; those saved columns remain intact.
The Updated annual release has 1,170 sites. ERA5-Land replaces
the overlapping climate, MODIS ET, and MODIS snow fields. MODIS NPP and greenup
are included alongside BESS GPP. New NDVI and replacement greenup work remains closed.
GHSL has no saved results in the checked input and is not included.
Human-impact results match 881 current watersheds. MODIS NPP has values at 953 sites,
greenup at 959, and ocean distance at 872. Keep source coverage, record counts,
routing status, and the original BESS values and reliability flags. Missing matches stay blank.

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

The current CAMREX input tables and verified Updated release are in Box under
`SiSyn/spatial-data-extractions/spatial-data/current-updated-release/`.
Use `camrex-bess-gpp.rds`, `camrex-modis-npp.rds`,
`camrex-modis-greenup.rds`, and `camrex-site-metadata.rds` for the four options above.
Use the existing combined input, site metadata, Glass file, and saved extraction
table from the spatial-data folder. Keep these inputs and release outputs outside Git.

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
- `workflow/vegetation/` reproduces the BESSv2 annual GPP results.
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

## CAMREX watershed recovery

Six CAMREX mainstem sites have reviewed GLORICH catchments derived from
HydroSHEDS 15-arc-second data. Recover them from the local GLORICH source
archive with the tracked site identifiers and area checks:

```bash
Rscript workflow/watershed_delineation/recover_glorich_watersheds.R \
  --source-archive /path/to/Glorich_V01_CSV_plus_Shapefiles_2019_05_24.zip \
  --targets workflow/watershed_delineation/config/glorich_camrex_targets.tsv \
  --output-root /path/to/reviewed-camrex-watersheds
```

The recovery stops if a polygon is invalid, differs from its published area
by more than one percent, lies more than two kilometers from its CAMREX point,
or breaks the expected downstream nesting order. It writes each shape under
the `data_release_3` folder expected by the watershed builder and records the
site-reference fields and checks in `glorich_recovery_qa.tsv`.

## Annual BESS GPP

Install the R packages `sf`, `terra`, `jsonlite`, `ncdf4`, and `googledrive`.
Use reviewed watershed boundaries and keep downloaded files outside this repo.

The BESS scripts use monthly NetCDF files to build annual GPP for 1982–2022.
They retain the source files, check each file, and multiply monthly mean daily GPP by
calendar days before summing. Annual totals use the same cells for all twelve
months and remain missing below 80% watershed coverage. Zeros are valid GPP.
The source uses a special value for missing cells and provides no separate quality field.

For all sites, `prepare_bess_roster.R` matches site names to reviewed watershed
shapes and uses the corrected Ferguson boundary. It keeps sites without
watershed shapes in `site-roster.rds`. Put the inputs on the computer running
the extraction so the job can read them even if it cannot open Box files.

```bash
Rscript workflow/vegetation/prepare_bess_roster.R \
  --metadata /path/to/combined-metadata.csv \
  --watersheds /path/to/reviewed-watersheds.gpkg \
  --shapefile-root /path/to/silica-shapefiles \
  --boundary-updates /path/to/ferguson_611026_verified.gpkg \
  --output-dir /path/to/bess-full/inputs

Rscript workflow/vegetation/prepare_vegetation_points.R \
  --watersheds /path/to/bess-full/inputs/watersheds.gpkg --id-column site \
  --product bess --output /path/to/bess-full/inputs/bess-points.rds

Rscript workflow/vegetation/extract_bess_gpp.R --mode monthly \
  --points /path/to/bess-full/inputs/bess-points.rds \
  --site-roster /path/to/bess-full/inputs/site-roster.rds \
  --years 1982:2022 --drive-folder 1ZSBnVT7IoeVh5Oj6zRwKjRRoY2qpVhJH \
  --auth-cache /path/to/existing-drive-login.rds --output-dir /path/to/bess-full
```

The RDS stores cell locations and weights in a table, which uses less
memory than storing each location as a map point. Add `--status-file FILE` to record progress.
Monthly mode accepts `--test` to check one real file and stop before completing
an annual total. It checks all requested months before starting and saves after
each month in `monthly-checkpoint.rds`. `annual-gpp.rds` expands shared
watersheds back to the original spatial site names for release review. Sites
without spatial data stay in the saved roster and remain missing in the
combined release. The full source transfer is about 2.45 GB across 492 files.
The annual results include `bess_trend_flag` and `bess_trend_note`.
`source_zero_history` flags all years for the reviewed Canadian Weasel River
(`sisyn_canada_eccc_wsc_nw10uf0003`) and Very River
(`sisyn_canada_eccc_wsc_nw10vk0002`) watersheds. Exclude those histories from
vegetation trend interpretation; their original GPP values remain unchanged.
`not_flagged` means no issue was identified by this specific review, rather
than independent validation of the site's trend.
To add the reviewed RDS results to an existing combined spatial CSV, use
`Rscript workflow/release/add_bess_to_combined.R --combined-input UPDATED_FILE --glass-input GLASS_FILE --bess-input ANNUAL_RDS --site-reference ROSTER_RDS --overwrite true`.
This BESS merge checks every added value after writing, excludes discontinued
NDVI and replacement greenup fields, and preserves MODIS NPP, MODIS greenup,
other predictors, and site order.
It can refresh an existing BESS version with the same reviewed source values.
Never use it to overwrite the separate AppEEARS/GLASS version.
Each year gains GPP, valid days, area fraction, trend flag, and
trend note columns under `bess_gpp_YEAR_`. Sites without BESS remain blank.
Keep a frozen runtime copy for long jobs so later code edits do not change
the running extraction.

Run the offline checks with `Rscript workflow/vegetation/tests/test_bess.R`.

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

The updated annual release has Ferguson's ERA5-Land values for 2000–2025 and
BESS GPP for 1982–2022. The MODIS vegetation, human-impact, and river-routing
results match the corrected watershed name and area. There are 24 annual NPP
values and 25 greenup dates across two cycles. Land cover and the static
terrain, lithology, soil, and permafrost predictors remain blank. The release
metadata records these gaps.

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

## Offline checks

Run these from the repository root; they do not submit Earth Engine jobs:

```bash
Rscript workflow/check_product_settings.R
Rscript workflow/release/tests/test_dataset_assembly.R
Rscript workflow/gee/tests/test_gee_workflows.R
Rscript workflow/vegetation/tests/test_bess.R
```

The BESS checks require the R packages listed under Annual BESS GPP.
