/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   76-validacion-post-migracion.sql
   ---------------------------------------------------------------------
   Verifica que el DW migrado a la nube contenga exactamente lo mismo que
   el DW de origen.

   Diseno: el MISMO script corre en los DOS entornos
   -------------------------------------------------
   No es un script "de la nube". Produce un conjunto de metricas
   normalizado —una fila por tabla con conteo, suma de control y
   checksum— que se obtiene igual en local y en RDS. La comparacion se
   hace despues, en 77-comparar-local-cloud.ps1, restando ambos conjuntos.

   La alternativa habria sido que el script consultara los dos servidores
   a la vez con un servidor vinculado. No se hizo: RDS no admite servidores
   vinculados hacia una maquina de escritorio, y aunque los admitiera,
   atarlos obligaria a abrir el laboratorio local a internet.

   Sobre CHECKSUM_AGG
   ------------------
   Comparar conteos detecta filas perdidas, pero no filas alteradas. El
   checksum agregado si: si un solo valor cambio en la copia, cambia. Se
   calcula sobre las columnas de negocio y NO sobre las claves subrogadas
   ni sobre las columnas de auditoria (EjecucionIdCarga, FechaCarga), que
   por diseno son distintas en cada carga y harian que el checksum nunca
   coincidiera.

   Parametros (obligatorios, igual que 46-validacion-consistencia.sql):
     ReservasOrigen, MontoOrigen, ResenasOrigen, InteraccionesOrigen

   Uso:
     sqlcmd -S <endpoint>,1433 -U <usuario> -P <clave> -C -N -d TurismoDW \
       -i 76-validacion-post-migracion.sql \
       -v ReservasOrigen=2000005 MontoOrigen=16709495659.28 \
          ResenasOrigen=500000 InteraccionesOrigen=1500000
   ===================================================================== */
SET NOCOUNT ON;
GO

/* --- Comprobacion de parametros -------------------------------------- */
IF '$(ReservasOrigen)' = '' OR '$(MontoOrigen)' = ''
   OR '$(ResenasOrigen)' = '' OR '$(InteraccionesOrigen)' = ''
BEGIN
    RAISERROR('Faltan parametros. Use -v ReservasOrigen=.. MontoOrigen=.. ResenasOrigen=.. InteraccionesOrigen=..', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @ReservasOrigen      bigint        = $(ReservasOrigen);
DECLARE @MontoOrigen         decimal(18,2) = $(MontoOrigen);
DECLARE @ResenasOrigen       bigint        = $(ResenasOrigen);
DECLARE @InteraccionesOrigen bigint        = $(InteraccionesOrigen);

PRINT '';
PRINT '=====================================================================';
PRINT ' VALIDACION POST-MIGRACION';
PRINT '=====================================================================';
PRINT '';

SELECT [Entorno]  = CONVERT(varchar(60), @@SERVERNAME),
       [Edicion]  = CONVERT(varchar(50), SERVERPROPERTY('Edition')),
       [Version]  = CONVERT(varchar(24), SERVERPROPERTY('ProductVersion')),
       [Base]     = DB_NAME(),
       [Fecha]    = CONVERT(varchar(19), SYSDATETIME(), 120);

/* =====================================================================
   BLOQUE 1. Reconciliacion contra el origen
   ===================================================================== */
PRINT '';
PRINT '=== 1. Reconciliacion contra los conteos del origen ===';

DECLARE @res TABLE (
    Num int IDENTITY(1,1), Control varchar(70),
    Esperado varchar(40), Obtenido varchar(40),
    Diferencia varchar(24), Veredicto varchar(10));

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Reservas migradas',
       FORMAT(@ReservasOrigen, 'N0'),
       FORMAT(COUNT_BIG(*), 'N0'),
       FORMAT(COUNT_BIG(*) - @ReservasOrigen, 'N0'),
       CASE WHEN COUNT_BIG(*) = @ReservasOrigen THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva;

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Suma de MontoTotal',
       FORMAT(@MontoOrigen, 'N2'),
       FORMAT(SUM(MontoTotal), 'N2'),
       FORMAT(SUM(MontoTotal) - @MontoOrigen, 'N2'),
       CASE WHEN ABS(SUM(MontoTotal) - @MontoOrigen) <= 0.01 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva;

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Resenas migradas',
       FORMAT(@ResenasOrigen, 'N0'), FORMAT(COUNT_BIG(*), 'N0'),
       FORMAT(COUNT_BIG(*) - @ResenasOrigen, 'N0'),
       CASE WHEN COUNT_BIG(*) = @ResenasOrigen THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactResena;

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Interacciones migradas',
       FORMAT(@InteraccionesOrigen, 'N0'), FORMAT(COUNT_BIG(*), 'N0'),
       FORMAT(COUNT_BIG(*) - @InteraccionesOrigen, 'N0'),
       CASE WHEN COUNT_BIG(*) = @InteraccionesOrigen THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactInteraccionWeb;

/* --- Integridad referencial ----------------------------------------- */
INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Claves foraneas no confiables o deshabilitadas', '0',
       CONVERT(varchar(20), COUNT(*)), '',
       CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM sys.foreign_keys fk
JOIN sys.objects o  ON o.object_id = fk.parent_object_id
JOIN sys.schemas s  ON s.schema_id = o.schema_id
WHERE s.name = 'dw' AND (fk.is_not_trusted = 1 OR fk.is_disabled = 1);

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Hechos sin dimension resuelta (ClienteKey = -1)', '0',
       CONVERT(varchar(20), COUNT_BIG(*)), '',
       CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE ClienteKey = -1;

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Huerfanos FactReserva -> DimCliente', '0',
       CONVERT(varchar(20), COUNT_BIG(*)), '',
       CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva f
LEFT JOIN dw.DimCliente d ON d.ClienteKey = f.ClienteKey
WHERE d.ClienteKey IS NULL;

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'ReservaId duplicados', '0',
       CONVERT(varchar(20), COUNT_BIG(*)), '',
       CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM (SELECT ReservaId FROM dw.FactReserva
       GROUP BY ReservaId HAVING COUNT_BIG(*) > 1) d;

/* --- Estructura migrada ---------------------------------------------- */
INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Dimensiones presentes', '8', CONVERT(varchar(20), COUNT(*)), '',
       CASE WHEN COUNT(*) = 8 THEN 'OK' ELSE 'REVISAR' END
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'dw' AND t.name LIKE 'Dim%';

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Hechos presentes', '6', CONVERT(varchar(20), COUNT(*)), '',
       CASE WHEN COUNT(*) = 6 THEN 'OK' ELSE 'REVISAR' END
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'dw' AND t.name LIKE 'Fact%';

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Vistas presentes', '17', CONVERT(varchar(20), COUNT(*)), '',
       CASE WHEN COUNT(*) >= 17 THEN 'OK' ELSE 'REVISAR' END
FROM sys.views v JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE s.name IN ('dw', 'etl');

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Indices columnstore', '3', CONVERT(varchar(20), COUNT(*)), '',
       CASE WHEN COUNT(*) = 3 THEN 'OK' ELSE 'REVISAR' END
FROM sys.indexes i
JOIN sys.tables t  ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'dw' AND i.type IN (5, 6);

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Tablas particionadas', '4', CONVERT(varchar(20), COUNT(DISTINCT t.object_id)), '',
       CASE WHEN COUNT(DISTINCT t.object_id) = 4 THEN 'OK' ELSE 'REVISAR' END
FROM sys.tables t
JOIN sys.indexes i        ON i.object_id = t.object_id AND i.index_id = 1
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
JOIN sys.schemas s        ON s.schema_id = t.schema_id
WHERE s.name = 'dw';

INSERT INTO @res (Control, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'dw.vw_EstadoSistema responde', '1 fila',
       CONVERT(varchar(20), COUNT(*)) + ' fila', '',
       CASE WHEN COUNT(*) = 1 THEN 'OK' ELSE 'REVISAR' END
FROM dw.vw_EstadoSistema;

SELECT Num, Control, Esperado, Obtenido, Diferencia, Veredicto FROM @res ORDER BY Num;

/* =====================================================================
   BLOQUE 2. Metricas comparables entre entornos

   Este es el conjunto que 77-comparar-local-cloud.ps1 obtiene en los dos
   servidores y resta. Formato fijo: Tabla | Filas | SumaControl | Checksum
   ===================================================================== */
PRINT '';
PRINT '=== 2. Metricas comparables (Tabla | Filas | SumaControl | Checksum) ===';

SELECT [Tabla] = 'dw.DimCliente',
       [Filas] = COUNT_BIG(*),
       [SumaControl] = CONVERT(decimal(20,2), COUNT_BIG(*)),
       [Checksum] = CHECKSUM_AGG(BINARY_CHECKSUM(ClienteId, Identificacion, PaisOrigen))
FROM dw.DimCliente
UNION ALL
SELECT 'dw.DimHotel', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(HotelId, Nombre, Ciudad, Pais))
FROM dw.DimHotel
UNION ALL
SELECT 'dw.DimTour', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(TourId, Nombre, Destino))
FROM dw.DimTour
UNION ALL
SELECT 'dw.DimPaquete', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(PaqueteId, Nombre))
FROM dw.DimPaquete
UNION ALL
SELECT 'dw.DimTiempo', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(TiempoKey, Fecha))
FROM dw.DimTiempo
UNION ALL
SELECT 'dw.DimTipoHabitacion', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(TipoHabitacionId, Nombre))
FROM dw.DimTipoHabitacion
UNION ALL
SELECT 'dw.DimEstadoReserva', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(Estado))
FROM dw.DimEstadoReserva
UNION ALL
SELECT 'dw.DimCanal', COUNT_BIG(*), CONVERT(decimal(20,2), COUNT_BIG(*)),
       CHECKSUM_AGG(BINARY_CHECKSUM(Canal, Dispositivo))
FROM dw.DimCanal
UNION ALL
SELECT 'dw.FactReserva', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(MontoTotal)),
       CHECKSUM_AGG(BINARY_CHECKSUM(ReservaId, FechaInicioKey, MontoTotal, Noches, EsCancelada))
FROM dw.FactReserva
UNION ALL
SELECT 'dw.FactReservaHabitacion', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(IngresoAlojamiento)),
       CHECKSUM_AGG(BINARY_CHECKSUM(ReservaHabitacionId, ReservaId, CantidadHabitaciones, TarifaAplicada))
FROM dw.FactReservaHabitacion
UNION ALL
SELECT 'dw.FactReservaTour', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(IngresoTour)),
       CHECKSUM_AGG(BINARY_CHECKSUM(ReservaTourId, ReservaId, CantidadPersonas, PrecioAplicado))
FROM dw.FactReservaTour
UNION ALL
SELECT 'dw.FactOcupacionDiaria', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(IngresoDia)),
       CHECKSUM_AGG(BINARY_CHECKSUM(TiempoKey, HotelKey, HabitacionesOcupadas, PersonasAlojadas))
FROM dw.FactOcupacionDiaria
UNION ALL
SELECT 'dw.FactResena', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(CONVERT(int, Calificacion))),
       CHECKSUM_AGG(BINARY_CHECKSUM(ResenaId, Calificacion, TipoEntidad, EsVerificada))
FROM dw.FactResena
UNION ALL
SELECT 'dw.FactInteraccionWeb', COUNT_BIG(*), CONVERT(decimal(20,2), SUM(CONVERT(bigint, DuracionSegundos))),
       CHECKSUM_AGG(BINARY_CHECKSUM(InteraccionId, TipoEvento, DuracionSegundos, EsConversion))
FROM dw.FactInteraccionWeb
ORDER BY 1;

/* =====================================================================
   BLOQUE 3. Distribucion por particion

   Debe reproducir la del origen: P1 = 0, P2..P7 entre 331 702 y 334 499,
   P8 = 0. Si la particion se degrado a PRIMARY, los numeros por particion
   siguen siendo los mismos aunque el filegroup se llame distinto: eso es
   exactamente lo que demuestra que solo se perdio la separacion fisica.
   ===================================================================== */
PRINT '';
PRINT '=== 3. Distribucion de dw.FactReserva por particion ===';

SELECT [Particion] = p.partition_number,
       [Filegroup] = CONVERT(varchar(16), fg.name),
       [Filas]     = p.rows
FROM sys.partitions p
JOIN sys.indexes i           ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups fg       ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID('dw.FactReserva') AND i.index_id = 1
ORDER BY p.partition_number;

/* =====================================================================
   BLOQUE 4. Veredicto
   ===================================================================== */
PRINT '';
PRINT '=== 4. Veredicto ===';

SELECT [Pruebas]   = COUNT(*),
       [Correctas] = SUM(CASE WHEN Veredicto = 'OK' THEN 1 ELSE 0 END),
       [PorRevisar]= SUM(CASE WHEN Veredicto = 'REVISAR' THEN 1 ELSE 0 END),
       [Global]    = CASE WHEN SUM(CASE WHEN Veredicto = 'REVISAR' THEN 1 ELSE 0 END) = 0
                          THEN 'MIGRACION VERIFICADA'
                          ELSE 'HAY CONTROLES POR REVISAR' END
FROM @res;
GO

SET NOEXEC OFF;
GO
