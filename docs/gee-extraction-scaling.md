# GEE Extraction Scaling

Use the [ERA5-Land run reference](era5-land-run-reference.md) for the current
asset gate, annual task shape, QA findings, and run order.

The preferred annual run is one all-sites export per year: 26 tasks for
2000-2025. Use the grouped fallback only after an all-sites task fails
repeatedly. Monthly extraction should remain `monthly_by_year` and requires a
pilot before scale-up.

Estimate configured grouped runs with observed timing rather than a generic
runtime promise:

```bash
Rscript workflow/estimate_gee_run_size.R \
  --run era5_land_monthly_full \
  --timing-log timing-logs/gee_task_timing_YYYYMMDDTHHMMSSZ.csv
```

Earth Engine quota guidance is maintained in the
[official usage documentation](https://developers.google.com/earth-engine/guides/usage).
