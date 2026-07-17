# ERA5-Land Run Reference

This is the authoritative technical reference for the annual ERA5-Land
watershed run.

## Production Gate — 2026-07-16

Do not accept another production run until `config/gee-assets.yml` points to a
verified asset with **529 rows and 529 distinct `site_id` values**.

The 543-row living site table currently resolves to 529 accepted watershed
rows and 14 excluded or unresolved rows. The critical decisions are:

| Site | Decision |
| --- | --- |
| KRR S65B | Exclude until a unique watershed exists. The combined `s_65bc` polygon is not a unique S65B watershed. |
| KRR S65C | Retain with `s_65bc`. |
| HYBAM Fazenda Vista Alegre | Use `fazenda_vista_alegre_hydrosheds`, HydroSHEDS ID 6120330250; do not use `rio_madeira`. |
| HYBAM Obidos | Exclude the duplicate row; retain GRO Obidos. |

The configured asset
`projects/silica-synthesis/assets/silica_gee_watersheds_530sites_20260715`
is superseded because it assigned `s_65bc` to both S65B and S65C. It also used
the Rio Madeira polygon for Fazenda Vista Alegre. Keep it only as an audit
artifact; the current configuration must not be used for a final run.

A corrected local 2026-07-16 package fixes Fazenda Vista Alegre but still has
530 rows because it retains S65B. Remove S65B, verify geometry and IDs, upload
the 529-row package, and then update `config/gee-assets.yml`.

## Existing ERA5-Land Runs

| Run | Status | Interpretation |
| --- | --- | --- |
| 497 rows × 2000-2025 | Completed | Valid for the included geometries, but 32 accepted rows are absent and three Finnish records need unique final IDs. |
| 530 rows × 2000-2025, launched 2026-07-16 | Non-final | Uses the superseded asset; do not merge into the final dataset. |
| 529 rows × 2000-2025 | Not yet launched | Required final production run. |

The completed 497-row run has 26 annual CSVs and 12,922 site-year rows. All six
ERA5-Land fields are populated. It used the fine-scale polygon retry for 24
tiny watersheds in every year (624 rows).

Two QA findings remain visible:

- small negative McMurdo actual/potential evaporation values represent net
  condensation after sign conversion, not missing data;
- McMurdo snow-water equivalent is 10,000 mm for all ten sites and all 26
  years and must be reviewed before analysis.

## Final Annual Run

- Notebook: `colab_notebooks/full_era5_land_annual_2000_2025.ipynb`
- Years: 2000-2025
- Task shape: one export per year for all accepted sites
- Expected tasks: 26
- Expected site-year rows: 13,754
- Shared cross-product comparison window: 2001-2022

Selected product: `ECMWF/ERA5_LAND/DAILY_AGGR`.

| Output | Earth Engine band | Units or annual metric |
| --- | --- | --- |
| `precip_mm` | `total_precipitation_sum` | mm/year |
| `temp_degC` | `temperature_2m` | annual mean °C |
| `evapotrans_mm` | `total_evaporation_sum` | mm/year |
| `potential_evap_mm` | `potential_evaporation_sum` | mm/year |
| `snow_cover_fraction` | `snow_cover` | watershed mean of annual maximum, converted to 0-1 |
| `snow_water_equiv_mm` | `snow_depth_water_equivalent` | mm |

For tiny watersheds, reduce the full polygon first. If the result is blank,
retry the same polygon at a finer scale and set `used_fine_scale_fallback`.
Never fill a missing polygon result with a centroid pixel.

## Run And Verify

1. Confirm that the notebook prints the expected 529-row asset and 529 selected
   rows.
2. Launch one or two years as a smoke test.
3. Launch all 26 annual tasks only after the smoke test passes.
4. If an all-sites annual task repeatedly fails, use
   `colab_notebooks/fallback_configured_gee_exports.ipynb` for grouped exports.
5. Organize Drive exports with `workflow/organize_drive_exports.R`.
6. Run `workflow/check_full_annual_era5_land.R` and
   `workflow/build_annual_inventory.R` before release.
7. Use `workflow/compare_full_annual_era5_land_to_old_drivers.R` for the
   old-versus-GEE comparison.

The notebook writes task and wall-clock timing CSVs under `timing-logs/`. Use
observed timings with `workflow/estimate_gee_run_size.R`; do not treat a generic
runtime estimate as a completion promise.

Band definitions are maintained in the
[Earth Engine catalog](https://developers.google.com/earth-engine/datasets/catalog/ECMWF_ERA5_LAND_DAILY_AGGR#bands).
