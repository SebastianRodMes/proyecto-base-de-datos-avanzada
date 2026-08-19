/* =====================================================================
   ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
   Semana 3 | Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   40-crear-basedatos.sql

   Crea la base analitica TurismoDW: la estructura fisica separada de la
   base operacional que exige el escenario ("separar datos, acelerar
   consultas y continuar operando cuando falle el servidor principal").

   Decisiones de diseno:

   * Filegroups por proposito, no por tamano:
       PRIMARY  -> solo metadatos del sistema
       FG_DIM   -> dimensiones (pequenas, muy leidas, alta densidad de cache)
       FG_FACT  -> hechos (grandes, escritura masiva por ETL)
       FG_STG   -> staging del ETL (volatil, se trunca en cada corrida)
       FG_IDX   -> indices no agrupados que agregue el Integrante 2
     Cada filegroup usa varios archivos para repartir la E/S en escritura,
     que es el patron de carga dominante del ETL.

   * Recovery model FULL: prerrequisito de Database Mirroring (Integrante 3).

   * Los filegroups por rango de anio (particionamiento) NO se crean aqui:
     son responsabilidad del Integrante 2. Ver 00-docs/03-contrato-integrante2.md

   Requisitos previos: 99-setup/00-setup-admin.ps1 ejecutado como Administrador.
   Uso: sqlcmd -S TURISMODW -E -C -i 40-crear-basedatos.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE master;
GO

/* ---------------------------------------------------------------------
   Verificaciones previas

   El script se adapta a la edicion de la instancia destino:

     Developer / Enterprise / Standard  -> tamanos completos de archivo.
     Express                            -> tamanos reducidos.

   Express limita la base a 10 GB contando SOLO los archivos de datos (el
   log no cuenta, el Query Store si). Con los tamanos completos la base
   nacería con 7.4 GB preasignados y quedaría al borde del tope antes de
   cargar una sola fila, asi que se reducen a ~2.6 GB iniciales, que cubren
   los ~2.8 GB reales del modelo con margen para crecer.

   Express NO puede ser principal ni espejo de Database Mirroring (solo
   testigo). Se acepta como host provisional para validar el ETL y el
   modelo estrella; la instancia definitiva debe ser Developer.
   --------------------------------------------------------------------- */
DECLARE @esExpress bit = CASE WHEN SERVERPROPERTY('EngineEdition') = 4 THEN 1 ELSE 0 END;

PRINT '=== Instancia destino ===';
SELECT
    [Servidor]   = @@SERVERNAME,
    [Edicion]    = CONVERT(varchar(60), SERVERPROPERTY('Edition')),
    [Version]    = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')),
    [Nivel]      = CONVERT(varchar(30), SERVERPROPERTY('ProductLevel'));

IF @esExpress = 1
BEGIN
    PRINT '';
    PRINT '*** AVISO: instancia Express Edition ***';
    PRINT '  - Se usaran tamanos de archivo reducidos (tope de 10 GB por base).';
    PRINT '  - Express NO puede ser principal ni espejo de Mirroring, solo testigo.';
    PRINT '  - Host valido para validar el ETL y el modelo estrella.';
    PRINT '  - Para la entrega final, mover a una instancia Developer Edition.';
    PRINT '';
END
GO

/* ---------------------------------------------------------------------
   Recreacion limpia
   --------------------------------------------------------------------- */
IF DB_ID('TurismoDW') IS NOT NULL
BEGIN
    PRINT 'TurismoDW ya existe: se elimina para recrearla.';
    ALTER DATABASE TurismoDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TurismoDW;
END
GO

/* ---------------------------------------------------------------------
   CREATE DATABASE con filegroups por proposito
   --------------------------------------------------------------------- */
DECLARE @esExpress bit = CASE WHEN SERVERPROPERTY('EngineEdition') = 4 THEN 1 ELSE 0 END;
DECLARE @raiz sysname = N'D:\DB\mssql\TurismoDW\';

/* Tamanos iniciales segun la edicion (en MB). */
DECLARE @sys   varchar(10) = CASE WHEN @esExpress = 1 THEN  '64' ELSE  '128' END;
DECLARE @dim   varchar(10) = CASE WHEN @esExpress = 1 THEN '128' ELSE  '256' END;
DECLARE @fact  varchar(10) = CASE WHEN @esExpress = 1 THEN '512' ELSE '2048' END;
DECLARE @stg   varchar(10) = CASE WHEN @esExpress = 1 THEN '768' ELSE '2048' END;
DECLARE @idx   varchar(10) = CASE WHEN @esExpress = 1 THEN '256' ELSE '1024' END;
DECLARE @log   varchar(10) = CASE WHEN @esExpress = 1 THEN '512' ELSE '2048' END;
DECLARE @crece varchar(10) = CASE WHEN @esExpress = 1 THEN '128' ELSE  '512' END;

DECLARE @sql nvarchar(max) = N'
CREATE DATABASE TurismoDW
ON PRIMARY
(   NAME = N''TurismoDW_sys'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_sys.mdf'',
    SIZE = ' + @sys + N'MB,  FILEGROWTH = 64MB ),

FILEGROUP FG_DIM
(   NAME = N''TurismoDW_dim01'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_dim01.ndf'',
    SIZE = ' + @dim + N'MB,  FILEGROWTH = 128MB ),

FILEGROUP FG_FACT
(   NAME = N''TurismoDW_fact01'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_fact01.ndf'',
    SIZE = ' + @fact + N'MB, FILEGROWTH = ' + @crece + N'MB ),
(   NAME = N''TurismoDW_fact02'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_fact02.ndf'',
    SIZE = ' + @fact + N'MB, FILEGROWTH = ' + @crece + N'MB ),

FILEGROUP FG_STG
(   NAME = N''TurismoDW_stg01'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_stg01.ndf'',
    SIZE = ' + @stg + N'MB, FILEGROWTH = ' + @crece + N'MB ),

FILEGROUP FG_IDX
(   NAME = N''TurismoDW_idx01'',
    FILENAME = N''' + @raiz + N'data\TurismoDW_idx01.ndf'',
    SIZE = ' + @idx + N'MB, FILEGROWTH = 256MB )

LOG ON
(   NAME = N''TurismoDW_log'',
    FILENAME = N''' + @raiz + N'log\TurismoDW_log.ldf'',
    SIZE = ' + @log + N'MB, FILEGROWTH = ' + @crece + N'MB );';

EXEC sys.sp_executesql @sql;
GO

/* ---------------------------------------------------------------------
   Configuracion de la base
   --------------------------------------------------------------------- */

-- FULL: obligatorio para Database Mirroring (Integrante 3).
ALTER DATABASE TurismoDW SET RECOVERY FULL;

-- Cierra la ventana de "consultas historicas que afectan las operaciones":
-- los lectores del dashboard no bloquean al ETL ni viceversa.
ALTER DATABASE TurismoDW SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
ALTER DATABASE TurismoDW SET ALLOW_SNAPSHOT_ISOLATION ON;

-- Estadisticas al dia sin intervencion manual entre corridas del ETL.
ALTER DATABASE TurismoDW SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE TurismoDW SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE TurismoDW SET AUTO_UPDATE_STATISTICS_ASYNC ON;

-- Evita que la base se cierre entre refrescos de Power BI.
ALTER DATABASE TurismoDW SET AUTO_CLOSE OFF;
ALTER DATABASE TurismoDW SET AUTO_SHRINK OFF;

ALTER DATABASE TurismoDW SET COMPATIBILITY_LEVEL = 160;
GO

-- Repositorio de planes: insumo directo para las pruebas de rendimiento
-- del Integrante 4 (comparacion antes/despues de indices).
-- El Query Store se guarda dentro de la base, asi que en Express su cuota
-- consume del tope de 10 GB: se reduce a 512 MB.
DECLARE @cuotaQS varchar(10) =
    CASE WHEN SERVERPROPERTY('EngineEdition') = 4 THEN '512' ELSE '2048' END;

EXEC ('ALTER DATABASE TurismoDW SET QUERY_STORE = ON');
EXEC ('ALTER DATABASE TurismoDW SET QUERY_STORE (
           OPERATION_MODE = READ_WRITE,
           DATA_FLUSH_INTERVAL_SECONDS = 900,
           INTERVAL_LENGTH_MINUTES = 15,
           MAX_STORAGE_SIZE_MB = ' + @cuotaQS + ',
           QUERY_CAPTURE_MODE = ALL,
           MAX_PLANS_PER_QUERY = 200 )');
GO

/* ---------------------------------------------------------------------
   FG_FACT como filegroup por defecto: cualquier objeto grande creado sin
   clausula ON cae en los archivos correctos, no en PRIMARY.
   --------------------------------------------------------------------- */
ALTER DATABASE TurismoDW MODIFY FILEGROUP FG_FACT DEFAULT;
GO

/* ---------------------------------------------------------------------
   Esquemas
   --------------------------------------------------------------------- */
USE TurismoDW;
GO

IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg AUTHORIZATION dbo;');  -- aterrizaje crudo del ETL
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw  AUTHORIZATION dbo;');  -- modelo estrella
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl AUTHORIZATION dbo;');  -- control y trazabilidad
GO

/* ---------------------------------------------------------------------
   Resultado
   --------------------------------------------------------------------- */
PRINT '';
PRINT '=== Filegroups creados ===';
SELECT
    [Filegroup]  = fg.name,
    [Archivo]    = df.name,
    [Ruta]       = df.physical_name,
    [Tamano_MB]  = df.size / 128,
    [Crecimiento]= CASE WHEN df.is_percent_growth = 1
                        THEN CONVERT(varchar(10), df.growth) + ' %'
                        ELSE CONVERT(varchar(10), df.growth / 128) + ' MB' END,
    [Default]    = CASE WHEN fg.is_default = 1 THEN 'SI' ELSE '' END
FROM sys.filegroups fg
JOIN sys.database_files df ON df.data_space_id = fg.data_space_id
UNION ALL
SELECT 'LOG', df.name, df.physical_name, df.size / 128,
       CONVERT(varchar(10), df.growth / 128) + ' MB', ''
FROM sys.database_files df
WHERE df.type_desc = 'LOG';

PRINT '';
PRINT '=== Configuracion ===';
SELECT
    [Base]              = name,
    [Recovery]          = recovery_model_desc,
    [RCSI]              = is_read_committed_snapshot_on,
    [QueryStore]        = is_query_store_on,
    [Compatibilidad]    = compatibility_level
FROM sys.databases
WHERE name = 'TurismoDW';
GO

PRINT '';
PRINT '>> TurismoDW creada. Siguiente: 41-esquema-staging.sql';
GO

SET NOEXEC OFF;
GO
