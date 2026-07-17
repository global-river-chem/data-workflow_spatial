# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

## Useful Files

- `data-workflow_spatial.Rproj`: open this in RStudio for local work.
- `colab_notebooks/full_era5_land_annual_2000_2025.ipynb`: full annual ERA5-Land Colab notebook.
- `colab_notebooks/fallback_configured_gee_exports.ipynb`: config-driven fallback Colab notebook.
- `colab_notebooks/test_watershed_size_comparison_era5_land.ipynb`: small, medium, and large watershed comparison Colab notebook.
- `colab_notebooks/test_and_tiny_watersheds_era5_land.ipynb`: Andrews/tiny-watershed test Colab notebook.
- `colab_notebooks/run_human_impacts.ipynb`: global human-impact Colab notebook.
- `config/human-impact-products.yml`: human-impact dataset settings and output fields.
- `workflow/run_watershed_size_comparison_qa.R`: local R script for old-vs-GEE watershed-size QA.
- `workflow/check_full_annual_era5_land.R`: checks the complete annual ERA5-Land dataset and writes QA tables and plots to the [shared GEE output folder](https://drive.google.com/drive/folders/1Y4Hz9_vZsar61jjhYOrQXG4AR1oQWNAX?usp=share_link).
- `workflow/compare_full_annual_era5_land_to_old_drivers.R`: compares the complete ERA5-Land dataset with the previous annual spatial drivers.
- `workflow/build_annual_inventory.R`: local R script for building annual inventory tables from completed exports.
- `docs/era5-land-run-reference.md`: technical ERA5-Land run record.
- `docs/gee-extraction-scaling.md`: extraction scaling and task reference.
- `docs/human-impact-workflow.md`: human-impact run instructions.
- `docs/human-impact-product-reference.md`: human-impact product interpretation.

## References To Revisit

- Wang et al. 2022, Remote Sensing of Environment: MODIS and ERA5-Land land surface temperature comparison. Useful background for thinking through MODIS vs ERA5-Land product comparisons: https://doi.org/10.1016/j.rse.2022.113181

## Repo Layout

- `colab_notebooks/`: Colab notebooks for GEE extraction tests and full runs.
- `workflow/`: local R scripts for watershed inputs, Drive organization, QA, run estimates, and inventory tables.
- `src/gee_spatial/`: Python helpers used by the Colab GEE extraction notebooks.
- `config/`: Earth Engine assets, product settings, and run settings.
- `docs/`: longer workflow notes and draft Earth Engine Code Editor snippets.
