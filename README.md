# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

## Start Here

- [Full annual ERA5-Land notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/colab_notebooks/full_era5_land_annual_2000_2025.ipynb)
- [Human-impact notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/colab_notebooks/run_human_impacts.ipynb)
- [Earth Engine assets and export settings](config/gee-assets.yml)
- [Driver-product settings](config/driver-products.yml)
- [Human-impact product settings](config/human-impact-products.yml)

Technical references are in [`docs/`](docs/). Local QA and file-organization scripts are in [`workflow/`](workflow/).

## References To Revisit

- Wang et al. 2022, Remote Sensing of Environment: MODIS and ERA5-Land land surface temperature comparison. Useful background for thinking through MODIS vs ERA5-Land product comparisons: https://doi.org/10.1016/j.rse.2022.113181

## Repo Layout

- `colab_notebooks/`: Colab notebooks for GEE extraction tests and full runs.
- `workflow/`: local R scripts for watershed inputs, Drive organization, QA, run estimates, and inventory tables.
- `src/gee_spatial/`: Python helpers used by the Colab GEE extraction notebooks.
- `config/`: Earth Engine assets, product settings, and run settings.
- `docs/`: longer workflow notes and draft Earth Engine Code Editor snippets.
