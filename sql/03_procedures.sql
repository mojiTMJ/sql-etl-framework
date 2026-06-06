/*======================================================================
  03_procedures.sql  —  the framework
  StartBatch -> LoadStaging -> MergeDimCustomer -> LoadFactOrder -> EndBatch
  Object names come from the etl.SourceTable control table (trusted
  metadata, not user input), so the staging load is fully generic.
======================================================================*/
SET ANSI_NULLS, QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE etl.usp_StartBatch
    @BatchId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT etl.LoadBatch DEFAULT VALUES;
    SET @BatchId = SCOPE_IDENTITY();
END
GO

/*----------------------------------------------------------------------
  Incremental landing: per active source, truncate staging and pull only
  rows newer than the source's high-water mark. Generic via metadata.
----------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE etl.usp_LoadStaging
    @BatchId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT, @src NVARCHAR(256), @stg NVARCHAR(256), @wm SYSNAME,
            @hwm DATETIME2(3), @rows BIGINT, @t0 DATETIME2(3), @sql NVARCHAR(MAX);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT SourceTableId, SourceObject, StagingObject, WatermarkColumn
        FROM etl.SourceTable WHERE IsActive = 1 ORDER BY SourceTableId;
    OPEN c; FETCH NEXT FROM c INTO @id, @src, @stg, @wm;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @t0 = SYSUTCDATETIME();
        SELECT @hwm = HighWaterMark FROM etl.Watermark WHERE SourceTableId = @id;

        SET @sql = N'TRUNCATE TABLE ' + @stg + N';'
                 + N'INSERT INTO ' + @stg + N' SELECT s.*, @BatchId FROM ' + @src
                 + N' AS s WHERE s.' + QUOTENAME(@wm) + N' > @hwm;'
                 + N'SET @rows = @@ROWCOUNT;';
        EXEC sys.sp_executesql @sql,
             N'@BatchId BIGINT, @hwm DATETIME2(3), @rows BIGINT OUTPUT',
             @BatchId = @BatchId, @hwm = @hwm, @rows = @rows OUTPUT;

        INSERT etl.RunLog (BatchId, StepName, SourceTableId, StartedAt, EndedAt, RowsAffected, Status)
        VALUES (@BatchId, 'LoadStaging', @id, @t0, SYSUTCDATETIME(), @rows, 'SUCCEEDED');

        FETCH NEXT FROM c INTO @id, @src, @stg, @wm;
    END
    CLOSE c; DEALLOCATE c;
END
GO

/*----------------------------------------------------------------------
  SCD Type 2 merge: change detection by row-hash. Changed members get
  their current row closed and a new version inserted; new members are
  inserted as current. Single set-based pass.
----------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE etl.usp_MergeDimCustomer
    @BatchId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME(), @t0 DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @changed TABLE (Act VARCHAR(10), CustomerId INT, FullName NVARCHAR(120),
                            Email NVARCHAR(256), City NVARCHAR(80), RowHash BINARY(32));

    ;WITH src AS (
        SELECT CustomerId, FullName, Email, City,
               HASHBYTES('SHA2_256', CONCAT(FullName, N'|', ISNULL(Email,N''), N'|', ISNULL(City,N''))) AS RowHash
        FROM stg.Customer
    )
    MERGE dw.DimCustomer AS tgt
    USING src ON tgt.CustomerId = src.CustomerId AND tgt.IsCurrent = 1
    WHEN MATCHED AND tgt.RowHash <> src.RowHash THEN
        UPDATE SET tgt.IsCurrent = 0, tgt.ValidTo = @now      -- close the old version
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (CustomerId, FullName, Email, City, RowHash, ValidFrom, ValidTo, IsCurrent)
        VALUES (src.CustomerId, src.FullName, src.Email, src.City, src.RowHash, @now, '9999-12-31', 1)
    OUTPUT $action, src.CustomerId, src.FullName, src.Email, src.City, src.RowHash INTO @changed;

    -- open a new current version for every member we just closed
    INSERT dw.DimCustomer (CustomerId, FullName, Email, City, RowHash, ValidFrom, ValidTo, IsCurrent)
    SELECT CustomerId, FullName, Email, City, RowHash, @now, '9999-12-31', 1
    FROM @changed WHERE Act = 'UPDATE';

    INSERT etl.RunLog (BatchId, StepName, StartedAt, EndedAt, RowsAffected, Status, Message)
    VALUES (@BatchId, 'MergeDimCustomer', @t0, SYSUTCDATETIME(),
            (SELECT COUNT(*) FROM @changed), 'SUCCEEDED',
            CONCAT('new=', (SELECT COUNT(*) FROM @changed WHERE Act='INSERT'),
                   ' changed=', (SELECT COUNT(*) FROM @changed WHERE Act='UPDATE')));
END
GO

/*----------------------------------------------------------------------
  Fact load: insert new orders only, resolving the dimension version that
  was effective on the order date (SCD2 lookup). Unmatched -> Unknown(-1).
----------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE etl.usp_LoadFactOrder
    @BatchId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(3) = SYSUTCDATETIME();

    INSERT dw.FactOrder (OrderId, CustomerKey, OrderDate, Amount, BatchId)
    SELECT s.OrderId, ISNULL(d.CustomerKey, -1), s.OrderDate, s.Amount, @BatchId
    FROM stg.[Order] AS s
    LEFT JOIN dw.DimCustomer AS d
           ON d.CustomerId = s.CustomerId
          AND CAST(s.OrderDate AS DATETIME2(3)) >= d.ValidFrom
          AND CAST(s.OrderDate AS DATETIME2(3)) <  d.ValidTo
    WHERE NOT EXISTS (SELECT 1 FROM dw.FactOrder f WHERE f.OrderId = s.OrderId);

    INSERT etl.RunLog (BatchId, StepName, StartedAt, EndedAt, RowsAffected, Status)
    VALUES (@BatchId, 'LoadFactOrder', @t0, SYSUTCDATETIME(), @@ROWCOUNT, 'SUCCEEDED');
END
GO

/*----------------------------------------------------------------------
  Close the batch. On success, advance each source's high-water mark to
  the max watermark value that actually landed in staging.
----------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE etl.usp_EndBatch
    @BatchId BIGINT,
    @Status  VARCHAR(12) = 'SUCCEEDED'
AS
BEGIN
    SET NOCOUNT ON;
    IF @Status = 'SUCCEEDED'
    BEGIN
        DECLARE @id INT, @stg NVARCHAR(256), @wm SYSNAME, @sql NVARCHAR(MAX), @max DATETIME2(3);
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT SourceTableId, StagingObject, WatermarkColumn FROM etl.SourceTable WHERE IsActive = 1;
        OPEN c; FETCH NEXT FROM c INTO @id, @stg, @wm;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @max = NULL;
            SET @sql = N'SELECT @max = MAX(' + QUOTENAME(@wm) + N') FROM ' + @stg + N';';
            EXEC sys.sp_executesql @sql, N'@max DATETIME2(3) OUTPUT', @max = @max OUTPUT;
            IF @max IS NOT NULL
                UPDATE etl.Watermark SET HighWaterMark = @max, UpdatedAt = SYSUTCDATETIME()
                WHERE SourceTableId = @id AND @max > HighWaterMark;
            FETCH NEXT FROM c INTO @id, @stg, @wm;
        END
        CLOSE c; DEALLOCATE c;
    END

    UPDATE etl.LoadBatch SET EndedAt = SYSUTCDATETIME(), Status = @Status WHERE BatchId = @BatchId;
END
GO
