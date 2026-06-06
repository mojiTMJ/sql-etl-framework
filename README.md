# sql-etl-framework

A small, **metadata-driven incremental ETL framework for SQL Server / Azure SQL** — the pattern I use to load operational data into a star-schema datamart: watermark-based incremental extract, **SCD Type 2** dimensions, surrogate keys, and per-step batch logging with restartability.

Everything here runs on **synthetic data** and standard T-SQL — no external dependencies, no client data. It's a reference you can read top-to-bottom in 20 minutes and adapt.

> Built to show the shape of a real datamart load without shipping anyone's data.

---

## What it demonstrates

| Concern | How it's handled |
|---|---|
| **Incremental extract** | High-water-mark per source table in `etl.Watermark`; only rows newer than the last successful batch are pulled into staging. |
| **Metadata-driven** | Sources are rows in `etl.SourceTable`, not hardcoded procs. Add a source = insert a row. |
| **Slowly Changing Dimensions** | `dw.DimCustomer` is **SCD Type 2** (versioned history) via a single `MERGE` + history insert. |
| **Surrogate keys & late-arriving members** | Facts resolve to the dimension version effective at the event date; unknown members map to a `-1` inferred row. |
| **Observability & restartability** | Every step writes start/rows/end/status to `etl.RunLog`; a failed batch can be re-run idempotently. |
| **Idempotency** | Staging load is delete-by-watermark + insert; dimension/fact merges are set-based and re-runnable. |

## Architecture

```
 source (synthetic OLTP)          control                target (datamart)
 ┌────────────────┐     ┌────────────────────────┐     ┌──────────────────┐
 │ app.Customer   │     │ etl.SourceTable  (config)│     │ dw.DimCustomer    │ SCD2
 │ app.[Order]    │ ──▶ │ etl.Watermark    (HWM)   │ ──▶ │ dw.FactOrder      │
 └────────────────┘     │ etl.LoadBatch    (runs)  │     └──────────────────┘
        │               │ etl.RunLog       (steps) │              ▲
        └──▶ stg.* ──────┴────────────────────────┘──────────────┘
              (landing)            procedures
```

Load order per batch: **StartBatch → LoadStaging → MergeDimCustomer (SCD2) → LoadFactOrder → EndBatch**.

## Run it

```sql
-- 1. schema + procedures (run in order)
:r sql/01_control_schema.sql
:r sql/02_dw_schema.sql
:r sql/03_procedures.sql
:r sql/04_sample_source_data.sql   -- synthetic OLTP + seed config

-- 2. run a batch
:r examples/run_pipeline.sql        -- StartBatch ... EndBatch

-- 3. change some source rows, run examples/run_pipeline.sql again
--    → only changed rows re-stage; customer changes create SCD2 versions
```

Tested on SQL Server 2019+ and Azure SQL Database. See [`docs/architecture.md`](docs/architecture.md) for the design rationale.

## Why it's built this way

- **Metadata over code** — adding a source shouldn't mean writing a procedure.
- **Set-based, not row-by-row** — every load is a single statement against the batch's delta.
- **Log everything** — when a 2 a.m. load fails, `etl.RunLog` tells you which step, how many rows, and why, so you can restart from there.

## License
MIT — see [LICENSE](LICENSE).
