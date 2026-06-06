/*======================================================================
  01_control_schema.sql  —  metadata + run-control objects
  The framework is driven by rows in etl.SourceTable, not by hardcoded
  procedures. Watermarks make extracts incremental; LoadBatch + RunLog
  make every run observable and restartable.
======================================================================*/
IF SCHEMA_ID(N'etl') IS NULL EXEC (N'CREATE SCHEMA etl;');
GO

-- One row per source object we ingest. Add a source = insert a row.
IF OBJECT_ID(N'etl.SourceTable') IS NULL
CREATE TABLE etl.SourceTable
(
    SourceTableId   INT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_SourceTable PRIMARY KEY,
    SourceName      SYSNAME       NOT NULL,                 -- logical name
    SourceObject    NVARCHAR(256) NOT NULL,                 -- e.g. app.Customer
    StagingObject   NVARCHAR(256) NOT NULL,                 -- e.g. stg.Customer
    WatermarkColumn SYSNAME       NOT NULL,                 -- incremental key, e.g. ModifiedDate
    IsActive        BIT           NOT NULL CONSTRAINT DF_SourceTable_IsActive DEFAULT (1),
    CONSTRAINT UQ_SourceTable_SourceName UNIQUE (SourceName)
);
GO

-- High-water mark per source: the max value successfully loaded so far.
IF OBJECT_ID(N'etl.Watermark') IS NULL
CREATE TABLE etl.Watermark
(
    SourceTableId INT          NOT NULL CONSTRAINT PK_Watermark PRIMARY KEY
        CONSTRAINT FK_Watermark_SourceTable REFERENCES etl.SourceTable(SourceTableId),
    HighWaterMark DATETIME2(3) NOT NULL CONSTRAINT DF_Watermark_HWM DEFAULT ('1900-01-01'),
    UpdatedAt     DATETIME2(3) NOT NULL CONSTRAINT DF_Watermark_UpdatedAt DEFAULT (SYSUTCDATETIME())
);
GO

-- One row per ETL run.
IF OBJECT_ID(N'etl.LoadBatch') IS NULL
CREATE TABLE etl.LoadBatch
(
    BatchId   BIGINT       NOT NULL IDENTITY(1,1) CONSTRAINT PK_LoadBatch PRIMARY KEY,
    StartedAt DATETIME2(3) NOT NULL CONSTRAINT DF_LoadBatch_StartedAt DEFAULT (SYSUTCDATETIME()),
    EndedAt   DATETIME2(3) NULL,
    Status    VARCHAR(12)  NOT NULL CONSTRAINT DF_LoadBatch_Status DEFAULT ('RUNNING')
        CONSTRAINT CK_LoadBatch_Status CHECK (Status IN ('RUNNING','SUCCEEDED','FAILED'))
);
GO

-- One row per step per batch: the audit trail you read at 2 a.m.
IF OBJECT_ID(N'etl.RunLog') IS NULL
CREATE TABLE etl.RunLog
(
    RunLogId      BIGINT       NOT NULL IDENTITY(1,1) CONSTRAINT PK_RunLog PRIMARY KEY,
    BatchId       BIGINT       NOT NULL CONSTRAINT FK_RunLog_LoadBatch REFERENCES etl.LoadBatch(BatchId),
    StepName      VARCHAR(64)  NOT NULL,
    SourceTableId INT          NULL CONSTRAINT FK_RunLog_SourceTable REFERENCES etl.SourceTable(SourceTableId),
    StartedAt     DATETIME2(3) NOT NULL CONSTRAINT DF_RunLog_StartedAt DEFAULT (SYSUTCDATETIME()),
    EndedAt       DATETIME2(3) NULL,
    RowsAffected  BIGINT       NULL,
    Status        VARCHAR(12)  NOT NULL CONSTRAINT DF_RunLog_Status DEFAULT ('RUNNING'),
    Message       NVARCHAR(2000) NULL
);
GO
CREATE INDEX IX_RunLog_BatchId ON etl.RunLog(BatchId) INCLUDE (StepName, Status);
GO
