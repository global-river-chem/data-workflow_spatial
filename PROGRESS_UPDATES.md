# Spatial Data Progress Updates

This file records major workflow changes. Row-level corrections are documented in the current Site Reference Table and its audit workbook.

## 2026-07-30

- Finalized the revised Site Reference Table and froze the changed watershed inputs for this extraction round.
- Started the Aurora soil, lithology, elevation, permafrost, precipitation, and air-temperature run from an isolated copy of the workflow.
- Kept Aurora and AppEEARS running independently. The remaining MODIS results will be downloaded, extracted locally, checked, and merged after both paths finish.
- Set the final coverage check to require every spatial site and every available annual driver year from 2002–2025. GLC-FCS30D will be checked through 2022, the last year available in that product.

## 2026-07-29

- Finished the full Site Reference Table audit across the required site, version, location, drainage-area, discharge, and watershed fields.
- Restored MCM stream-channel areas and linked them to the Wright et al. (2023) stream-channel dataset. These values are not full topographic drainage areas.
- Restored the separate Amazon, GRO, and HYBAM Obidos watershed assignments.
- Checked GEMS, Danube, Seine, Australia, and other corrected watershed names against the local watershed files.
- Added the drainage-area review field so derived watersheds without an independent reported area can be identified.
- Kept `Use_WRTDS` unchanged during the spatial audit.
- Continued the local AppEEARS download and MODIS extraction queue for new and corrected watersheds.
- Kept the Aurora handoff separate from MODIS so the non-MODIS work could run independently after its watershed files passed validation.
- Moved current GEE quota checks, ERA5-Land tools, and GLC land-cover tools to `data-workflow_spatial/workflow/gee/`.
- Replaced dated and single-site watershed scripts with reusable AppEEARS, HydroBASINS, NLDI, and Earth Engine tools driven by the current table and small TSV override files.
- Removed preliminary workbooks, plots, downloaded source packages, duplicate watershed copies, caches, and cancelled test outputs. Active AppEEARS files, request records, final review files, and Aurora inputs were kept.

## 2026-07-28

- Checked the July AppEEARS requests against the current Site Reference Table and watershed names.
- Submitted missing or corrected MODIS requests for the audited sites, including replacement watersheds and 2023–2025 coverage where needed.
- Kept first-time MODIS work for sites without earlier products and avoided rerunning sites whose accepted MODIS products already matched the current watershed.
- Prepared the completed MODIS results for the later combined spatial file. Human impacts and GLC land cover remain GEE tasks and are not part of the Aurora raster workflow.

## 2026-07-23

- Completed the main row-by-row audit of the expanded Site Reference Table.
- Checked coordinates, drainage areas, aliases, discharge metadata, and watershed assignments against LTER, agency, PI, and publication sources.
- Recovered or rebuilt missing and corrected watersheds for PIE, Krycklan, Sweden, Tanguro, UMR/USGS, Danube/GEMS, and McMurdo Dry Valleys.
- Reorganized the watershed library into version folders and kept rejected or superseded candidates only where they were needed to explain a decision.
- Added a safety check that blocks oversized Earth Engine submissions before they start.
- Used the July AppEEARS quota earlier than planned after an overnight request was too large. Remaining requests were split into smaller checked batches.

## 2026-07-20

- Completed the earlier 524-site AppEEARS spatial file and its watershed package.
- Corrected missing ET and snow values for targeted sites and documented unresolved source-data gaps.
- Began the expanded audit and follow-up requests for new and corrected watersheds.

## 2026-07-17

- Added reliable watersheds for Andrews Creek, selected HYBAM sites, LMP sites, and corrected USGS sites.
- Replaced incorrect or duplicated watershed assignments before rerunning affected AppEEARS products.

## 2026-06-29

- Combined the May and June spatial updates into the working release file.
- Added new sites only when a usable watershed and the required chemistry or discharge record were available.

## 2025-03-25

- Archived the original AppEEARS/NASA spatial extract used as the baseline for later corrections.
