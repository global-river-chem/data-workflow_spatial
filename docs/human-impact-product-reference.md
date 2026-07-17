# Human-Impact Product Reference

This file documents product definitions and interpretation limits. It is not
required to run the notebook.

## Population

- **GHSL** is the long-term residential-population measure: 100 m data for
  1975-2020 every five years. The workflow uses these measured dates only;
  its 2025 and 2030 images are future estimates. It is the best population
  measure here for slow, multi-decade change.
- **LandScan** is the annual measure for 2000-2024. It estimates average
  24-hour human presence, so it includes where people work and travel as well
  as where they live. It is useful for annual coverage, but it is not a
  residential measure.
- **WorldPop** is a possible future residential-population comparison series:
  about 100 m and annual for 2000-2020 in the public Earth Engine collection.
  It would add 21 tasks and should remain separate from LandScan and GHSL, not
  be combined into one population variable.
- **WorldPop Global 2** is promising (100 m, 2015-2030), but is not presently
  a public Earth Engine collection. Adding it would require a separate upload
  step and care with projected years.
- **GPW** is not included because it is roughly 1 km, only every five years,
  and supplies part of the population information used by GHSL.

For a DSi analysis, compare the population measures rather than treating them
as interchangeable. Population is a broad pressure marker; dams, fertilizer,
and wastewater are closer to possible mechanisms.

## Other datasets

- **Dams** are one current Global Dam Watch snapshot. The output includes count,
  storage capacity, and hydropower capacity where those fields are supplied.
- **Fertilizer** is a current NPKGRIDS crop-rate comparison score. It is not
  total fertilizer mass because the source lacks crop-area weights.
- **Wastewater** is one current HydroWASTE map. The workflow keeps plants
  marked operational, construction completed, or not reported, and uses the
  location supplied with the dataset.

## Sources

- [GHSL population in Earth Engine](https://developers.google.com/earth-engine/datasets/catalog/JRC_GHSL_P2023A_GHS_POP)
- [LandScan Global in Earth Engine](https://developers.google.com/earth-engine/datasets/catalog/projects_sat-io_open-datasets_ORNL_LANDSCAN_GLOBAL)
- [WorldPop legacy population in Earth Engine](https://developers.google.com/earth-engine/datasets/catalog/WorldPop_GP_100m_pop)
- [WorldPop Global 2 announcement](https://www.worldpop.org/blog/worldpop-unveils-global-2-next-generation-global-population-dataset/)
- [GPW population in Earth Engine](https://developers.google.com/earth-engine/datasets/catalog/CIESIN_GPWv411_GPW_Population_Count)
