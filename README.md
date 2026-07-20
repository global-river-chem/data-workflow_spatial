# Data Workflow: Spatial

Google Earth Engine spatial extraction workflow for the global river chemistry project.

## Start Here

- [Spatial-data progress updates](PROGRESS_UPDATES.md)
- [Full annual ERA5-Land notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/colab_notebooks/full_era5_land_annual_2000_2025.ipynb)
- [ERA5-Land run status and QA](docs/era5-land-run-reference.md)
- [Human-impact notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/colab_notebooks/run_human_impacts.ipynb)
- [Human-impact workflow](docs/human-impact-workflow.md)
- [Earth Engine assets and export settings](config/gee-assets.yml)
- [Driver-product settings](config/driver-products.yml)
- [Human-impact product settings](config/human-impact-products.yml)

Local QA and file-organization scripts are in [`workflow/`](workflow/).

## Repo Layout

- `colab_notebooks/`: Colab notebooks for GEE extraction tests and full runs.
- `workflow/`: local R scripts for watershed inputs, Drive organization, QA, run estimates, and inventory tables.
- `src/gee_spatial/`: Python helpers used by the Colab GEE extraction notebooks.
- `config/`: Earth Engine assets, product settings, and run settings.
- `docs/`: concise technical run and product references.
