# Priority Human-Impact GEE Workflow

Run [the Colab notebook](https://colab.research.google.com/github/global-river-chem/data-workflow_spatial/blob/main/colab_notebooks/run_human_impacts_priority.ipynb).

The notebook exports watershed summaries for:

- LandScan population, each year from 2000-2024;
- GHSL residential population, every five years from 1975-2020;
- Global Dam Watch dams, one current map;
- NPKGRIDS fertilizer, one current estimate;
- HydroWASTE wastewater plants, one current map.

## Run it

1. Open the notebook and run the setup cells.
2. In **Edit Run Settings**, choose sites and, if needed, change the year lists.
3. Set `MAX_TASKS_TO_LAUNCH = 5` for a small test run. It runs one export for
   each dataset. Leave it as `None` for all 38 exports.
4. Run the source-data check, launch exports, and use the final cell to watch
   their status.

Exports go to the `Google-Earth-Engine` folder in Google Drive. Their names
begin with `human_impacts_`.

Files:

- `colab_notebooks/run_human_impacts_priority.ipynb`: Colab launcher;
- `config/human-impact-products.yml`: dataset settings and exported fields;
- `src/gee_spatial/human_impacts.py`: the code that summarizes each watershed.

See [human-impact-notes.md](human-impact-notes.md) for dataset choices, population-product differences,
and interpretation limits.
