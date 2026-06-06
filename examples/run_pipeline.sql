/*======================================================================
  run_pipeline.sql  —  run one batch end-to-end, then inspect results.
  Re-run it after changing source rows (see the block at the bottom) to
  watch the incremental load and SCD2 versioning in action.
======================================================================*/
SET XACT_ABORT ON;
DECLARE @BatchId BIGINT;

BEGIN TRY
    EXEC etl.usp_StartBatch       @BatchId OUTPUT;
    EXEC etl.usp_LoadStaging      @BatchId;
    EXEC etl.usp_MergeDimCustomer @BatchId;
    EXEC etl.usp_LoadFactOrder    @BatchId;
    EXEC etl.usp_EndBatch         @BatchId, 'SUCCEEDED';
END TRY
BEGIN CATCH
    IF @BatchId IS NOT NULL EXEC etl.usp_EndBatch @BatchId, 'FAILED';
    INSERT etl.RunLog (BatchId, StepName, Status, EndedAt, Message)
    VALUES (ISNULL(@BatchId, 0), 'PIPELINE', 'FAILED', SYSUTCDATETIME(), ERROR_MESSAGE());
    THROW;
END CATCH;

/*---------- inspect the run ----------*/
SELECT * FROM etl.LoadBatch ORDER BY BatchId DESC;
SELECT StepName, SourceTableId, RowsAffected, Status, Message
FROM etl.RunLog WHERE BatchId = @BatchId ORDER BY RunLogId;

SELECT CustomerKey, CustomerId, FullName, City, IsCurrent, ValidFrom, ValidTo
FROM dw.DimCustomer ORDER BY CustomerId, ValidFrom;

SELECT * FROM dw.FactOrder ORDER BY OrderId;

/*======================================================================
  Try the incremental + SCD2 behaviour:
  1. Run this whole script once  -> 3 customers, 3 orders loaded.
  2. Uncomment the block below, then run run_pipeline.sql again:
       - only the touched rows re-stage (watermark moved forward)
       - customer 1 gets a 2nd DimCustomer version (Milano -> Bologna),
         IsCurrent flips, and the old version keeps its ValidFrom/ValidTo
       - order 1004 lands and resolves to customer 1's *current* version
======================================================================*/
-- UPDATE app.Customer SET City = N'Bologna', ModifiedDate = SYSUTCDATETIME() WHERE CustomerId = 1;
-- INSERT app.[Order] (OrderId, CustomerId, OrderDate, Amount, ModifiedDate)
--   VALUES (1004, 1, CAST(SYSUTCDATETIME() AS DATE), 99.90, SYSUTCDATETIME());
