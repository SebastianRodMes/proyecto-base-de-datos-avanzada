/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   47b-particionamiento.rds.sql
   ---------------------------------------------------------------------
   Variante de 04-sqlserver/47b-particionamiento.sql (Integrante 2) para
   Amazon RDS for SQL Server.

   Que cambia y por que
   --------------------
   El original crea ocho filegroups anuales con archivos .ndf bajo la ruta
   del contenedor Linux, y mapea ps_TurismoAnio a esos ocho grupos.

   (La ruta no se escribe literal aqui a proposito: lleva una barra seguida
   de asterisco, y T-SQL admite comentarios ANIDADOS, asi que esa secuencia
   abre un bloque nuevo y deja el comentario sin cerrar. Este script fallo
   por eso en su primera corrida contra RDS, con "Missing end comment
   mark".)
   En RDS no se elige la ruta, y segun la edicion puede no aceptarse
   ADD FILEGROUP. Este script se adapta al modo en que quedo la base:

     Modo FILEGROUPS -> crea los ocho filegroups anuales con rutas
                        D:\rdsdbdata\DATA\ y mapea el esquema a ellos.
                        Equivalente exacto al original.

     Modo PRIMARY    -> crea el esquema con ALL TO ([PRIMARY]).
                        La particion LOGICA se conserva intacta: la
                        funcion, los limites, la eliminacion de
                        particiones y la alineacion de los columnstore
                        siguen funcionando igual. Lo unico que se pierde
                        es la separacion FISICA por archivo, que en RDS
                        no aporta nada porque el almacenamiento es un
                        volumen EBS unico gestionado por AWS.

   El modo se lee de dbo.MigracionModo, que escribe 40-crear-basedatos.rds.sql.

   Se respeta el contrato del Integrante 2:
     - NO se tocan los indices UQ_*_Negocio.
     - NO se cambian nombres de tablas ni de columnas.
     - Las PK pasan a (XxxKey, FechaClave) igual que en el original.

   Correr DESPUES de 41..45 y de haber capturado la linea base con 47a.
   ===================================================================== */
SET NOCOUNT ON;
GO
USE TurismoDW;
GO

DECLARE @modo varchar(20) = 'PRIMARY';
IF OBJECT_ID('dbo.MigracionModo') IS NOT NULL
    SELECT TOP (1) @modo = Modo FROM dbo.MigracionModo ORDER BY FechaAplicacion DESC;
PRINT '>> Modo de particionamiento: ' + @modo;
GO

/* ---------------------------------------------------------------------
   1) Filegroups anuales, solo si la base quedo en modo FILEGROUPS
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM dbo.MigracionModo WHERE Modo = 'FILEGROUPS')
BEGIN
    DECLARE @fg TABLE (orden int, nombre sysname, archivo sysname);
    INSERT INTO @fg VALUES
        (1,'FG_PRE2021','TurismoDW_pre2021'),
        (2,'FG_2021','TurismoDW_2021'), (3,'FG_2022','TurismoDW_2022'),
        (4,'FG_2023','TurismoDW_2023'), (5,'FG_2024','TurismoDW_2024'),
        (6,'FG_2025','TurismoDW_2025'), (7,'FG_2026','TurismoDW_2026'),
        (8,'FG_2027PLUS','TurismoDW_2027plus');

    DECLARE @n sysname, @a sysname, @sql nvarchar(max);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT nombre, archivo FROM @fg ORDER BY orden;
    OPEN cur;
    FETCH NEXT FROM cur INTO @n, @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = @n)
        BEGIN
            SET @sql = N'ALTER DATABASE TurismoDW ADD FILEGROUP ' + QUOTENAME(@n) + N';';
            EXEC sys.sp_executesql @sql;
            SET @sql = N'ALTER DATABASE TurismoDW ADD FILE (NAME=N''' + @a +
                       N''', FILENAME=N''D:\rdsdbdata\DATA\' + @a +
                       N'.ndf'', SIZE=64MB, FILEGROWTH=64MB) TO FILEGROUP ' + QUOTENAME(@n) + N';';
            EXEC sys.sp_executesql @sql;
            PRINT '   filegroup anual creado: ' + @n;
        END
        FETCH NEXT FROM cur INTO @n, @a;
    END
    CLOSE cur; DEALLOCATE cur;
END
ELSE
    PRINT '   (modo PRIMARY: no se crean filegroups anuales)';
GO

/* ---------------------------------------------------------------------
   2) Funcion de particion. Identica al original: RANGE RIGHT con 7
      limites yyyymmdd -> 8 particiones (P1 <2021, P2..P7 2021..2026,
      P8 >=2027).
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.partition_schemes   WHERE name = 'ps_TurismoAnio')
    DROP PARTITION SCHEME ps_TurismoAnio;
GO
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'pf_TurismoAnio')
    DROP PARTITION FUNCTION pf_TurismoAnio;
GO

CREATE PARTITION FUNCTION pf_TurismoAnio (int)
AS RANGE RIGHT FOR VALUES
    (20210101, 20220101, 20230101, 20240101, 20250101, 20260101, 20270101);
GO

/* ---------------------------------------------------------------------
   3) Esquema de particion, mapeado segun el modo.
   --------------------------------------------------------------------- */
DECLARE @sql nvarchar(max);
IF EXISTS (SELECT 1 FROM dbo.MigracionModo WHERE Modo = 'FILEGROUPS')
      AND EXISTS (SELECT 1 FROM sys.filegroups WHERE name = 'FG_2021')
BEGIN
    SET @sql = N'CREATE PARTITION SCHEME ps_TurismoAnio AS PARTITION pf_TurismoAnio
                 TO (FG_PRE2021, FG_2021, FG_2022, FG_2023, FG_2024, FG_2025, FG_2026, FG_2027PLUS);';
    PRINT '   esquema mapeado a los ocho filegroups anuales';
END
ELSE
BEGIN
    SET @sql = N'CREATE PARTITION SCHEME ps_TurismoAnio AS PARTITION pf_TurismoAnio
                 ALL TO ([PRIMARY]);';
    PRINT '   esquema mapeado a PRIMARY (particion logica, sin separacion fisica)';
END
EXEC sys.sp_executesql @sql;
GO

/* ---------------------------------------------------------------------
   4) Reparticionar las cuatro tablas de hechos grandes.

   Igual que en el original: para particionar una tabla existente hay que
   mover su indice agrupado al esquema, y SQL Server exige que la columna
   de particion forme parte de la clave del indice agrupado unico, por eso
   la PK pasa de (XxxKey) a (XxxKey, FechaClave).

   Los UQ_*_Negocio NO se tocan: quedan no alineados, igual que on-premise.
   Consecuencia identica a la del original: SWITCH PARTITION deshabilitado.
   --------------------------------------------------------------------- */
ALTER TABLE dw.FactReserva DROP CONSTRAINT PK_FactReserva;
ALTER TABLE dw.FactReserva ADD CONSTRAINT PK_FactReserva
    PRIMARY KEY CLUSTERED (ReservaKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

ALTER TABLE dw.FactReservaTour DROP CONSTRAINT PK_FactReservaTour;
ALTER TABLE dw.FactReservaTour ADD CONSTRAINT PK_FactReservaTour
    PRIMARY KEY CLUSTERED (ReservaTourKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

ALTER TABLE dw.FactReservaHabitacion DROP CONSTRAINT PK_FactReservaHabitacion;
ALTER TABLE dw.FactReservaHabitacion ADD CONSTRAINT PK_FactReservaHabitacion
    PRIMARY KEY CLUSTERED (ReservaHabitacionKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

ALTER TABLE dw.FactOcupacionDiaria DROP CONSTRAINT PK_FactOcupacionDiaria;
ALTER TABLE dw.FactOcupacionDiaria ADD CONSTRAINT PK_FactOcupacionDiaria
    PRIMARY KEY CLUSTERED (OcupacionKey, TiempoKey)
    ON ps_TurismoAnio(TiempoKey);
GO

/* ---------------------------------------------------------------------
   5) Verificacion: filas por particion. La distribucion debe coincidir
      con la de on-premise (evidencias-47/particionamiento.txt):
      P1 = 0, P2..P7 entre 331 702 y 334 499, P8 = 0.
   --------------------------------------------------------------------- */
PRINT '=== Distribucion de FactReserva por particion (RDS) ===';
SELECT p.partition_number AS Particion,
       fg.name            AS Filegroup,
       p.rows             AS Filas
FROM sys.partitions p
JOIN sys.indexes i           ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups fg       ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID('dw.FactReserva') AND i.index_id = 1
ORDER BY p.partition_number;
GO
