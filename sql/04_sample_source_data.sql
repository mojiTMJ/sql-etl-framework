/*======================================================================
  04_sample_source_data.sql  —  register sources + seed synthetic OLTP
  Idempotent: safe to re-run.
======================================================================*/
SET NOCOUNT ON;

-- register the two sources in control metadata
IF NOT EXISTS (SELECT 1 FROM etl.SourceTable WHERE SourceName = N'Customer')
    INSERT etl.SourceTable (SourceName, SourceObject, StagingObject, WatermarkColumn)
    VALUES (N'Customer', N'app.Customer', N'stg.Customer', N'ModifiedDate');

IF NOT EXISTS (SELECT 1 FROM etl.SourceTable WHERE SourceName = N'Order')
    INSERT etl.SourceTable (SourceName, SourceObject, StagingObject, WatermarkColumn)
    VALUES (N'Order', N'app.[Order]', N'stg.[Order]', N'ModifiedDate');

-- ensure a watermark row exists per source
INSERT etl.Watermark (SourceTableId)
SELECT st.SourceTableId FROM etl.SourceTable st
WHERE NOT EXISTS (SELECT 1 FROM etl.Watermark w WHERE w.SourceTableId = st.SourceTableId);

-- synthetic OLTP data (only seed once)
IF NOT EXISTS (SELECT 1 FROM app.Customer)
    INSERT app.Customer (CustomerId, FullName, Email, City, ModifiedDate) VALUES
        (1, N'Giulia Rossi',  N'giulia.rossi@example.com',  N'Milano', '2026-01-10T09:00:00'),
        (2, N'Marco Bianchi', N'marco.bianchi@example.com', N'Roma',   '2026-01-10T09:00:00'),
        (3, N'Sara Conti',    N'sara.conti@example.com',    N'Torino', '2026-01-11T09:00:00');

IF NOT EXISTS (SELECT 1 FROM app.[Order])
    INSERT app.[Order] (OrderId, CustomerId, OrderDate, Amount, ModifiedDate) VALUES
        (1001, 1, '2026-01-12', 120.00, '2026-01-12T10:00:00'),
        (1002, 2, '2026-01-12',  75.50, '2026-01-12T10:05:00'),
        (1003, 3, '2026-01-13', 240.00, '2026-01-13T11:00:00');
GO
