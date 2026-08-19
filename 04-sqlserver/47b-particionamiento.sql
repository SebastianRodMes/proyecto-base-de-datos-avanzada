/* =====================================================================
   ITI-821 Escenario 8 - Integrante 2 (Sebastian)
   47b-particionamiento.sql
   ---------------------------------------------------------------------
   Crea los filegroups por rango de anio, la funcion y el esquema de
   particion, y reparticiona las tablas de hechos grandes por FechaInicioKey.

   Rutas: contenedor Docker Linux -> /var/opt/mssql/data/
   Correr DESPUES de restaurar TurismoDW y de haber capturado la linea base
   con 47a-medicion-testigo.sql.

   Respeta el contrato:
     - NO toca los indices UQ_*_Negocio (garantia de idempotencia del ETL).
     - NO cambia nombres de tablas/columnas ni el recovery FULL.
   ===================================================================== */
SET NOCOUNT ON;
USE TurismoDW;
GO

/* ---------------------------------------------------------------------
   1) Filegroups por anio (uno por particion resultante)
      La funcion RANGE RIGHT con 7 limites da 8 particiones:
        P1 (<2021)  P2..P7 (2021..2026)  P8 (>=2027)
   --------------------------------------------------------------------- */
DECLARE @fg TABLE (nombre sysname, archivo sysname);
INSERT INTO @fg VALUES
 ('FG_PRE2021','TurismoDW_pre2021'),
 ('FG_2021','TurismoDW_2021'),('FG_2022','TurismoDW_2022'),
 ('FG_2023','TurismoDW_2023'),('FG_2024','TurismoDW_2024'),
 ('FG_2025','TurismoDW_2025'),('FG_2026','TurismoDW_2026'),
 ('FG_2027PLUS','TurismoDW_2027plus');

DECLARE @n sysname, @a sysname, @sql nvarchar(max);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT nombre, archivo FROM @fg;
OPEN cur;
FETCH NEXT FROM cur INTO @n, @a;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = @n)
    BEGIN
        SET @sql = N'ALTER DATABASE TurismoDW ADD FILEGROUP ' + QUOTENAME(@n) + N';';
        EXEC sys.sp_executesql @sql;
        SET @sql = N'ALTER DATABASE TurismoDW ADD FILE (NAME=N''' + @a +
                   N''', FILENAME=N''/var/opt/mssql/data/' + @a +
                   N'.ndf'', SIZE=128MB, FILEGROWTH=128MB) TO FILEGROUP ' + QUOTENAME(@n) + N';';
        EXEC sys.sp_executesql @sql;
        PRINT 'Filegroup + archivo creado: ' + @n;
    END
    FETCH NEXT FROM cur INTO @n, @a;
END
CLOSE cur; DEALLOCATE cur;
GO

/* ---------------------------------------------------------------------
   2) Funcion y esquema de particion (clave acordada: yyyymmdd int)
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name='pf_TurismoAnio')
    DROP PARTITION FUNCTION pf_TurismoAnio;  -- solo si aun no hay esquemas usandola
GO
CREATE PARTITION FUNCTION pf_TurismoAnio (int)
AS RANGE RIGHT FOR VALUES
    (20210101, 20220101, 20230101, 20240101, 20250101, 20260101, 20270101);
GO

CREATE PARTITION SCHEME ps_TurismoAnio
AS PARTITION pf_TurismoAnio
TO (FG_PRE2021, FG_2021, FG_2022, FG_2023, FG_2024, FG_2025, FG_2026, FG_2027PLUS);
GO

/* ---------------------------------------------------------------------
   3) Reparticionar las tablas de hechos.

   Para particionar una tabla existente hay que mover su INDICE AGRUPADO
   al esquema de particion. SQL Server exige que la columna de particion
   forme parte de la clave del indice agrupado unico, por eso la PK pasa
   de (XxxKey) a (XxxKey, FechaInicioKey). La clave de negocio sigue siendo
   XxxKey; agregar FechaInicioKey no cambia la unicidad porque cada fila
   tiene exactamente una FechaInicioKey.

   Los UQ_*_Negocio NO se tocan: quedan como indices NO alineados en FG_IDX.
   Consecuencia: SWITCH PARTITION queda deshabilitado mientras existan.
   Si mas adelante se quiere archivar por SWITCH, hay que alinearlos, lo que
   cambia su semantica -> coordinar antes con el Integrante 1.
   --------------------------------------------------------------------- */

-- FactReserva (particiona por FechaInicioKey)
ALTER TABLE dw.FactReserva DROP CONSTRAINT PK_FactReserva;
ALTER TABLE dw.FactReserva ADD CONSTRAINT PK_FactReserva
    PRIMARY KEY CLUSTERED (ReservaKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

-- FactReservaTour (alineada por FechaInicioKey -> colocacion en JOINs)
ALTER TABLE dw.FactReservaTour DROP CONSTRAINT PK_FactReservaTour;
ALTER TABLE dw.FactReservaTour ADD CONSTRAINT PK_FactReservaTour
    PRIMARY KEY CLUSTERED (ReservaTourKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

-- FactReservaHabitacion (alineada por FechaInicioKey)
ALTER TABLE dw.FactReservaHabitacion DROP CONSTRAINT PK_FactReservaHabitacion;
ALTER TABLE dw.FactReservaHabitacion ADD CONSTRAINT PK_FactReservaHabitacion
    PRIMARY KEY CLUSTERED (ReservaHabitacionKey, FechaInicioKey)
    ON ps_TurismoAnio(FechaInicioKey);
GO

-- FactOcupacionDiaria (misma funcion, pero su fecha es TiempoKey)
ALTER TABLE dw.FactOcupacionDiaria DROP CONSTRAINT PK_FactOcupacionDiaria;
ALTER TABLE dw.FactOcupacionDiaria ADD CONSTRAINT PK_FactOcupacionDiaria
    PRIMARY KEY CLUSTERED (OcupacionKey, TiempoKey)
    ON ps_TurismoAnio(TiempoKey);
GO

/* ---------------------------------------------------------------------
   4) Verificacion: filas por particion (deben repartirse por anio)
   --------------------------------------------------------------------- */
PRINT '=== Distribucion de FactReserva por particion ===';
SELECT p.partition_number AS Particion,
       fg.name            AS Filegroup,
       p.rows             AS Filas
FROM sys.partitions p
JOIN sys.indexes i       ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups fg   ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID('dw.FactReserva') AND i.index_id = 1
ORDER BY p.partition_number;
GO
