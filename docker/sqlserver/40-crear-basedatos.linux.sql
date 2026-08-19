/* =====================================================================
   40-crear-basedatos.linux.sql
   Version del 04-sqlserver/40-crear-basedatos.sql adaptada al contenedor
   Docker (SQL Server sobre Linux): rutas /var/opt/mssql/data/ en vez de
   D:\DB\mssql\. Tamanos de Developer (la imagen es Developer Edition).

   Mantiene identicas las decisiones de diseno del original:
   filegroups por proposito, recovery FULL, RCSI, Query Store, FG_FACT
   por defecto y los esquemas stg/dw/etl.
   ===================================================================== */
SET NOCOUNT ON;
GO
USE master;
GO

IF DB_ID('TurismoDW') IS NOT NULL
BEGIN
    ALTER DATABASE TurismoDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TurismoDW;
END
GO

CREATE DATABASE TurismoDW
ON PRIMARY
(   NAME = N'TurismoDW_sys',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_sys.mdf',
    SIZE = 128MB,  FILEGROWTH = 64MB ),

FILEGROUP FG_DIM
(   NAME = N'TurismoDW_dim01',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_dim01.ndf',
    SIZE = 256MB,  FILEGROWTH = 128MB ),

FILEGROUP FG_FACT
(   NAME = N'TurismoDW_fact01',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_fact01.ndf',
    SIZE = 2048MB, FILEGROWTH = 512MB ),
(   NAME = N'TurismoDW_fact02',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_fact02.ndf',
    SIZE = 2048MB, FILEGROWTH = 512MB ),

FILEGROUP FG_STG
(   NAME = N'TurismoDW_stg01',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_stg01.ndf',
    SIZE = 2048MB, FILEGROWTH = 512MB ),

FILEGROUP FG_IDX
(   NAME = N'TurismoDW_idx01',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_idx01.ndf',
    SIZE = 1024MB, FILEGROWTH = 256MB )

LOG ON
(   NAME = N'TurismoDW_log',
    FILENAME = N'/var/opt/mssql/data/TurismoDW_log.ldf',
    SIZE = 2048MB, FILEGROWTH = 512MB );
GO

ALTER DATABASE TurismoDW SET RECOVERY FULL;
ALTER DATABASE TurismoDW SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
ALTER DATABASE TurismoDW SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE TurismoDW SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE TurismoDW SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE TurismoDW SET AUTO_UPDATE_STATISTICS_ASYNC ON;
ALTER DATABASE TurismoDW SET AUTO_CLOSE OFF;
ALTER DATABASE TurismoDW SET AUTO_SHRINK OFF;
ALTER DATABASE TurismoDW SET COMPATIBILITY_LEVEL = 160;
GO

ALTER DATABASE TurismoDW SET QUERY_STORE = ON;
ALTER DATABASE TurismoDW SET QUERY_STORE (
    OPERATION_MODE = READ_WRITE,
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES = 15,
    MAX_STORAGE_SIZE_MB = 2048,
    QUERY_CAPTURE_MODE = ALL,
    MAX_PLANS_PER_QUERY = 200 );
GO

ALTER DATABASE TurismoDW MODIFY FILEGROUP FG_FACT DEFAULT;
GO

USE TurismoDW;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw  AUTHORIZATION dbo;');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl AUTHORIZATION dbo;');
GO
PRINT '>> TurismoDW creada (Linux). Siguiente: 41..45';
GO
