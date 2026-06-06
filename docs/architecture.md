# Architecture & design notes

## Layers
- **`app.*`** — a synthetic OLTP source so the repo is self-contained. In real life this is one or more upstream systems reached over a linked server, ADF copy, or extract files.
- **`stg.*`** — a raw landing zone. Truncated and reloaded each batch with only the incremental delta. No transformation here; staging exists so the load is restartable and the source connection is held open as briefly as possible.
- **`dw.*`** — the consumable star schema: conformed dimensions + facts.
- **`etl.*`** — control plane: source config, watermarks, batch + step logs.

## Incremental extract (watermarks)
Each source has a row in `etl.Watermark` holding the highest watermark-column value successfully loaded. `usp_LoadStaging` pulls only `WHERE <wm> > HighWaterMark`; `usp_EndBatch` advances the mark to the max value that actually landed — **and only on success**, so a failed batch re-pulls the same delta next time (idempotent).

## SCD Type 2 (`dw.DimCustomer`)
Change is detected with a `HASHBYTES('SHA2_256', ...)` over the tracked columns — cheaper and clearer than column-by-column comparison.

A single `MERGE`:
- **new member** → insert as current (`IsCurrent = 1`, `ValidTo = 9999-12-31`);
- **changed member** → close the current row (`IsCurrent = 0`, `ValidTo = now`) and capture it via `OUTPUT`;
- the captured rows then get a fresh current version inserted.

This keeps full history: a customer who moves city has two rows, each valid for a date range.

## Surrogate keys & late-arriving dimensions
Facts carry the dimension **surrogate** key (`CustomerKey`), not the business key, so history and renames don't break the join. The fact load resolves the dimension **version effective on the order date**:

```sql
ON d.CustomerId = s.CustomerId
AND s.OrderDate >= d.ValidFrom AND s.OrderDate < d.ValidTo
```

Anything unmatched maps to the inferred `-1` "unknown" member so a fact row is never silently dropped.

## Observability & restartability
`etl.LoadBatch` is one row per run; `etl.RunLog` is one row per step with rows-affected and status. When a 2 a.m. load fails you can see exactly which step, how many rows, and the error message — then re-run, because every step is set-based and idempotent.

## What I'd add for production
- Parallelise independent source loads (Service Broker / SQL Agent / ADF fan-out).
- Data-quality gates between staging and the merge (row counts, referential checks, null thresholds) that can fail the batch.
- Partition-switch loads for large facts.
- A `DimDate` and proper date keys on the fact.
- Schema-drift detection driven from the same metadata.
