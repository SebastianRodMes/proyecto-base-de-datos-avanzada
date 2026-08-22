/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   40-crear-basedatos.rds.sql
   ---------------------------------------------------------------------
   Variante de 04-sqlserver/40-crear-basedatos.sql para Amazon RDS for
   SQL Server. El original NO corre en RDS: declara rutas fisicas
   (D:\DB\mssql\... o /var/opt/mssql/data/...) y RDS no permite elegir
   donde viven los archivos.

   Que cambia respecto del original y por que
   ------------------------------------------
   1. CREATE DATABASE sin clausula ON/LOG. RDS coloca los archivos en
      D:\rdsdbdata\DATA\ y no acepta un FILENAME arbitrario.
   2. No se fija RECOVERY FULL. En RDS el modelo de recuperacion lo
      determina la retencion de respaldos de la instancia; forzarlo es
      innecesario y en algunas configuraciones lo rechaza.
   3. Query Store con MAX_STORAGE_SIZE_MB = 256 en vez de 2048. En
      Express el Query Store consume del mismo tope de 10 GB que los
      datos, asi que se le da una cuota conservadora.
   4. MODIFY FILEGROUP ... DEFAULT solo se ejecuta si los filegroups
      pudieron crearse.
   5. El DROP usa rdsadmin.dbo.rds_drop_database cuando existe: en RDS
      el usuario maestro no siempre puede poner la base en SINGLE_USER.

   Los filegroups: el punto que decide el resto de la migracion
   -----------------------------------------------------------
   Los scripts 41 a 45 y 47b llevan clausulas ON FG_DIM, ON FG_FACT,
   ON FG_STG y ON FG_IDX incrustadas en casi cada CREATE TABLE y CREATE
   INDEX. Si RDS acepta ADD FILEGROUP / ADD FILE apuntando a
   D:\rdsdbdata\DATA\, esos scripts corren SIN UNA SOLA MODIFICACION y la
   migracion del esquema es literal.

   Si RDS los rechaza, hay que degradar todo a PRIMARY, y entonces los
   scripts 41..45 deben pasar por el adaptador de 75-migrar-dw.ps1, que
   elimina las clausulas ON FG_* al vuelo.

   Este script prueba la ruta buena y, si falla, cae a la degradada. En
   ambos casos deja el veredicto en dbo.MigracionModo, que es lo que
   75-migrar-dw.ps1 consulta para saber como seguir.

   Uso:
     sqlcmd -S <endpoint>,1433 -U <maestro> -P <pwd> -C -N -b -i este.sql
   ===================================================================== */
SET NOCOUNT ON;
GO
USE master;
GO

/* ---------------------------------------------------------------------
   0) Borrado previo (idempotencia)
   --------------------------------------------------------------------- */
IF DB_ID('TurismoDW') IS NOT NULL
BEGIN
    IF OBJECT_ID('rdsadmin.dbo.rds_drop_database') IS NOT NULL
    BEGIN
        PRINT '>> Base existente. Se elimina con rdsadmin.dbo.rds_drop_database.';
        EXEC rdsadmin.dbo.rds_drop_database N'TurismoDW';
    END
    ELSE
    BEGIN
        PRINT '>> Base existente. Se elimina con DROP DATABASE.';
        ALTER DATABASE TurismoDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE TurismoDW;
    END
END
GO

/* ---------------------------------------------------------------------
   1) Creacion. Sin rutas: RDS decide donde van los archivos.
   --------------------------------------------------------------------- */
CREATE DATABASE TurismoDW;
GO

/* ---------------------------------------------------------------------
   2) Intento de reproducir los filegroups por proposito.

   Se prueban con la ruta que RDS expone para datos. Si la instancia lo
   rechaza (cualquier error), se captura y se sigue en modo PRIMARY.
   --------------------------------------------------------------------- */
BEGIN TRY
    DECLARE @fg TABLE (orden int, nombre sysname, archivo sysname, mb int);
    INSERT INTO @fg VALUES
        (1, 'FG_DIM',  'TurismoDW_dim01',  128),
        (2, 'FG_FACT', 'TurismoDW_fact01', 512),
        (3, 'FG_FACT', 'TurismoDW_fact02', 512),
        (4, 'FG_STG',  'TurismoDW_stg01',  512),
        (5, 'FG_IDX',  'TurismoDW_idx01',  256);

    DECLARE @n sysname, @a sysname, @mb int, @sql nvarchar(max);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT nombre, archivo, mb FROM @fg ORDER BY orden;
    OPEN cur;
    FETCH NEXT FROM cur INTO @n, @a, @mb;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM TurismoDW.sys.filegroups WHERE name = @n)
        BEGIN
            SET @sql = N'ALTER DATABASE TurismoDW ADD FILEGROUP ' + QUOTENAME(@n) + N';';
            EXEC sys.sp_executesql @sql;
        END

        SET @sql = N'ALTER DATABASE TurismoDW ADD FILE (NAME=N''' + @a +
                   N''', FILENAME=N''D:\rdsdbdata\DATA\' + @a + N'.ndf'', SIZE=' +
                   CAST(@mb AS nvarchar(10)) + N'MB, FILEGROWTH=128MB) TO FILEGROUP ' +
                   QUOTENAME(@n) + N';';
        EXEC sys.sp_executesql @sql;
        PRINT '   filegroup/archivo creado: ' + @n + ' / ' + @a;

        FETCH NEXT FROM cur INTO @n, @a, @mb;
    END
    CLOSE cur; DEALLOCATE cur;

    ALTER DATABASE TurismoDW MODIFY FILEGROUP FG_FACT DEFAULT;
    PRINT '>> MODO FILEGROUPS: RDS acepto los filegroups por proposito.';
    PRINT '   Los scripts 41..45 y 47b corren sin modificacion.';
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'cur') >= 0
    BEGIN
        CLOSE cur;
        DEALLOCATE cur;
    END
    PRINT '>> MODO PRIMARY: RDS rechazo los filegroups.';
    PRINT '   Motivo: ' + LEFT(ERROR_MESSAGE(), 800);
    PRINT '   75-migrar-dw.ps1 debe adaptar 41..45 y 47b quitando ON FG_*.';
END CATCH
GO

/* ---------------------------------------------------------------------
   3) Opciones de base soportadas en RDS
   --------------------------------------------------------------------- */
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
    MAX_STORAGE_SIZE_MB = 256,
    QUERY_CAPTURE_MODE = AUTO,
    MAX_PLANS_PER_QUERY = 200 );
GO

/* ---------------------------------------------------------------------
   4) Esquemas y registro del modo aplicado
   --------------------------------------------------------------------- */
USE TurismoDW;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg AUTHORIZATION dbo;');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw  AUTHORIZATION dbo;');
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

/* Deja constancia de en que modo quedo la base. 75-migrar-dw.ps1 lee esto
   para decidir si adapta los scripts 41..45 antes de ejecutarlos. */
IF OBJECT_ID('dbo.MigracionModo') IS NOT NULL DROP TABLE dbo.MigracionModo;
GO
CREATE TABLE dbo.MigracionModo (
    Modo              varchar(20)   NOT NULL,
    Motor             nvarchar(200) NOT NULL,
    Edicion           nvarchar(200) NOT NULL,
    FilegroupsUsuario int           NOT NULL,
    FechaAplicacion   datetime2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

INSERT INTO dbo.MigracionModo (Modo, Motor, Edicion, FilegroupsUsuario)
SELECT CASE WHEN COUNT(*) > 0 THEN 'FILEGROUPS' ELSE 'PRIMARY' END,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(200)),
       CAST(SERVERPROPERTY('Edition')        AS nvarchar(200)),
       COUNT(*)
FROM sys.filegroups
WHERE name <> 'PRIMARY' AND type = 'FG';
GO

SELECT Modo, Edicion, FilegroupsUsuario FROM dbo.MigracionModo;
GO
PRINT '>> TurismoDW creada en RDS. Siguiente: 41..45 (adaptados si Modo=PRIMARY).';
GO
