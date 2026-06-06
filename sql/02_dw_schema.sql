/*======================================================================
  02_dw_schema.sql  —  synthetic source (app), staging (stg), datamart (dw)
  app.*  = stand-in for an OLTP system (so the demo is self-contained)
  stg.*  = raw landing zone, truncated/loaded per batch
  dw.*   = star schema: DimCustomer (SCD Type 2) + FactOrder
======================================================================*/
IF SCHEMA_ID(N'app') IS NULL EXEC (N'CREATE SCHEMA app;');
IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg;');
IF SCHEMA_ID(N'dw')  IS NULL EXEC (N'CREATE SCHEMA dw;');
GO

/*---------- synthetic OLTP source ----------*/
IF OBJECT_ID(N'app.Customer') IS NULL
CREATE TABLE app.Customer
(
    CustomerId   INT          NOT NULL CONSTRAINT PK_app_Customer PRIMARY KEY,
    FullName     NVARCHAR(120) NOT NULL,
    Email        NVARCHAR(256) NULL,
    City         NVARCHAR(80)  NULL,
    ModifiedDate DATETIME2(3)  NOT NULL CONSTRAINT DF_app_Customer_Mod DEFAULT (SYSUTCDATETIME())
);
IF OBJECT_ID(N'app.[Order]') IS NULL
CREATE TABLE app.[Order]
(
    OrderId      INT           NOT NULL CONSTRAINT PK_app_Order PRIMARY KEY,
    CustomerId   INT           NOT NULL,
    OrderDate    DATE          NOT NULL,
    Amount       DECIMAL(12,2) NOT NULL,
    ModifiedDate DATETIME2(3)  NOT NULL CONSTRAINT DF_app_Order_Mod DEFAULT (SYSUTCDATETIME())
);
GO

/*---------- staging (landing) ----------*/
IF OBJECT_ID(N'stg.Customer') IS NULL
CREATE TABLE stg.Customer
(
    CustomerId INT NOT NULL, FullName NVARCHAR(120) NOT NULL, Email NVARCHAR(256) NULL,
    City NVARCHAR(80) NULL, ModifiedDate DATETIME2(3) NOT NULL, BatchId BIGINT NOT NULL
);
IF OBJECT_ID(N'stg.[Order]') IS NULL
CREATE TABLE stg.[Order]
(
    OrderId INT NOT NULL, CustomerId INT NOT NULL, OrderDate DATE NOT NULL,
    Amount DECIMAL(12,2) NOT NULL, ModifiedDate DATETIME2(3) NOT NULL, BatchId BIGINT NOT NULL
);
GO

/*---------- target: star schema ----------*/
-- SCD Type 2 dimension: full version history per customer.
IF OBJECT_ID(N'dw.DimCustomer') IS NULL
CREATE TABLE dw.DimCustomer
(
    CustomerKey INT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_DimCustomer PRIMARY KEY, -- surrogate
    CustomerId  INT           NOT NULL,                                                     -- business key
    FullName    NVARCHAR(120) NOT NULL,
    Email       NVARCHAR(256) NULL,
    City        NVARCHAR(80)  NULL,
    RowHash     BINARY(32)    NOT NULL,    -- hash of tracked columns, drives change detection
    ValidFrom   DATETIME2(3)  NOT NULL,
    ValidTo     DATETIME2(3)  NOT NULL CONSTRAINT DF_DimCustomer_ValidTo DEFAULT ('9999-12-31'),
    IsCurrent   BIT           NOT NULL CONSTRAINT DF_DimCustomer_IsCurrent DEFAULT (1)
);
GO
CREATE UNIQUE INDEX UX_DimCustomer_Current ON dw.DimCustomer(CustomerId) WHERE IsCurrent = 1;
CREATE INDEX IX_DimCustomer_BK ON dw.DimCustomer(CustomerId, ValidFrom, ValidTo);
GO

-- Inferred "Unknown" member so facts never lose a row to a missing dimension.
IF NOT EXISTS (SELECT 1 FROM dw.DimCustomer WHERE CustomerKey = -1)
BEGIN
    SET IDENTITY_INSERT dw.DimCustomer ON;
    INSERT dw.DimCustomer (CustomerKey, CustomerId, FullName, Email, City, RowHash, ValidFrom, ValidTo, IsCurrent)
    VALUES (-1, -1, N'(unknown)', NULL, NULL, 0x0, '1900-01-01', '9999-12-31', 1);
    SET IDENTITY_INSERT dw.DimCustomer OFF;
END
GO

IF OBJECT_ID(N'dw.FactOrder') IS NULL
CREATE TABLE dw.FactOrder
(
    OrderKey    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_FactOrder PRIMARY KEY,
    OrderId     INT           NOT NULL,
    CustomerKey INT           NOT NULL CONSTRAINT FK_FactOrder_DimCustomer REFERENCES dw.DimCustomer(CustomerKey),
    OrderDate   DATE          NOT NULL,
    Amount      DECIMAL(12,2) NOT NULL,
    BatchId     BIGINT        NOT NULL,
    CONSTRAINT UQ_FactOrder_OrderId UNIQUE (OrderId)
);
GO
