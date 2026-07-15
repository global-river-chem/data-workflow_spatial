# Spatial Data Workflow Progress Updates

Use this file for dated notes about work completed, decisions made, and what to
pick up next. Keep the current plan in [roadmap.md](roadmap.md).

## 2026-07-15

### Progress

- Moved the GEE roadmap notes into the repo documentation.
- Added the corrected small-watershed extraction method to the README, roadmap,
  ERA5-Land notes, and full-run plan.
- Added product-period notes and possible pre-2001 productivity or phenology
  options to the roadmap and ERA5-Land notes.

### Decisions

- For small watersheds, extract ERA5-Land values from the full polygon first.
- If the polygon extraction is blank, retry the same polygon at a finer scale
  and mark those rows with `used_fine_scale_fallback`.
- Do not fill blank values from watershed centroids.
- Keep the daily aggregated ERA5-Land product as the current workflow product;
  keep the hourly catalog link as a related reference.

## 2026-07-14

### Progress

- Completed the 2000-2025 ERA5-Land Earth Engine tasks with 26 annual CSVs.
- Added full annual QA notes for the completed ERA5-Land files.
- Added old-vs-ERA5 comparison work for precipitation, temperature, and
  evapotranspiration.
- Added AppEEARS/NASA/Aurora spatial-driver QA notes to the current work plan.

### Decisions

- The completed ERA5-Land run is not final because the uploaded asset missed 46
  source-table rows.
- Keep ERA5-Land snow cover in the new analysis, but keep it out of the old
  MODIS snow comparison.
- For tiny watersheds, use the full polygon first and retry the same polygon at
  a finer scale if the first extraction is blank.
- Do not fill blank tiny-watershed values from watershed centroids.
- Review McMurdo snow-water equivalent before using that variable in analysis.

### Next

- Fix missing watershed geometries.
- Rebuild the Earth Engine upload asset after geometry issues are resolved.
- Review full ERA5-Land QA outputs.
- Scan the AppEEARS/NASA/Aurora one-page-per-site QA plot set.
