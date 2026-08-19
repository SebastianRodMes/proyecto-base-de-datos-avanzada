/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   46-validacion-consistencia.sql

   Reconciliacion del modelo analitico contra las fuentes.

   Es la evidencia que pide el enunciado ("Validacion de datos antes y
   despues del reemplazo del nodo") y el insumo del Integrante 4 para su
   prueba de consistencia del modelo analitico con Power BI.

   Cada prueba emite una fila con veredicto OK / REVISAR, de modo que se
   pueda pegar la salida completa en el documento de evidencias.

   Los valores esperados del lado de PostgreSQL y MongoDB se obtienen con
   11-verificacion-origen.sql y 21-verificacion-mongo.js. Este script se
   ejecuta con esos numeros como parametros; si se omiten, las pruebas que
   dependen del origen se marcan como omitidas.

   Uso:
     sqlcmd -S TURISMODW -E -C -d TurismoDW -i 46-validacion-consistencia.sql
     sqlcmd -S TURISMODW -E -C -d TurismoDW -i 46-validacion-consistencia.sql ^
            -v ReservasOrigen=2000005 MontoOrigen=0 ResenasOrigen=500000
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

/* Los cuatro valores esperados del origen llegan por parametro de sqlcmd.

   NO se declaran aqui con :setvar. Una version anterior lo hacia "para que el
   script corriera igual sin parametros", y el efecto era el contrario: :setvar
   se ejecuta despues de que sqlcmd procesa -v, asi que pisaba los valores que
   uno pasaba y las cuatro pruebas de completitud salian siempre OMITIDA sin
   avisar. Un script de validacion que silenciosamente no valida es peor que
   uno que falla.

   Los valores salen de:
       01-postgres/11-verificacion-origen.sql   -> ReservasOrigen, MontoOrigen
       02-mongodb/21-verificacion-mongo.js      -> ResenasOrigen, InteraccionesOrigen

   Si falta alguno, sqlcmd aborta con "variable no definida", que es
   exactamente lo que debe pasar.
*/
GO

DECLARE @ReservasOrigen     bigint        = $(ReservasOrigen);
DECLARE @MontoOrigen        decimal(20,2) = $(MontoOrigen);
DECLARE @ResenasOrigen      bigint        = $(ResenasOrigen);
DECLARE @InteraccionesOrigen bigint       = $(InteraccionesOrigen);

DECLARE @Resultados TABLE (
    Orden      int IDENTITY(1,1),
    Prueba     varchar(70),
    Esperado   varchar(40),
    Obtenido   varchar(40),
    Diferencia varchar(40),
    Veredicto  varchar(12)
);

/* =====================================================================
   BLOQUE 1 - Completitud: el DW tiene todas las filas del origen
   ===================================================================== */

DECLARE @FactReservas bigint = (SELECT COUNT_BIG(*) FROM dw.FactReserva);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT
    'Conteo de reservas: PostgreSQL vs dw.FactReserva',
    CASE WHEN @ReservasOrigen < 0 THEN 'no informado' ELSE FORMAT(@ReservasOrigen, 'N0') END,
    FORMAT(@FactReservas, 'N0'),
    CASE WHEN @ReservasOrigen < 0 THEN 'n/d'
         ELSE FORMAT(@FactReservas - @ReservasOrigen, 'N0') END,
    CASE WHEN @ReservasOrigen < 0 THEN 'OMITIDA'
         WHEN @FactReservas = @ReservasOrigen THEN 'OK'
         ELSE 'REVISAR' END;

DECLARE @MontoDW decimal(20,2) = (SELECT SUM(MontoTotal) FROM dw.FactReserva);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT
    'Suma de monto_total: PostgreSQL vs dw.FactReserva',
    CASE WHEN @MontoOrigen < 0 THEN 'no informado' ELSE FORMAT(@MontoOrigen, 'N2') END,
    FORMAT(@MontoDW, 'N2'),
    CASE WHEN @MontoOrigen < 0 THEN 'n/d'
         ELSE FORMAT(@MontoDW - @MontoOrigen, 'N2') END,
    CASE WHEN @MontoOrigen < 0 THEN 'OMITIDA'
         WHEN ABS(@MontoDW - @MontoOrigen) <= 0.01 THEN 'OK'
         ELSE 'REVISAR' END;

DECLARE @FactResenas bigint = (SELECT COUNT_BIG(*) FROM dw.FactResena);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT
    'Conteo de resenas: MongoDB vs dw.FactResena',
    CASE WHEN @ResenasOrigen < 0 THEN 'no informado' ELSE FORMAT(@ResenasOrigen, 'N0') END,
    FORMAT(@FactResenas, 'N0'),
    CASE WHEN @ResenasOrigen < 0 THEN 'n/d'
         ELSE FORMAT(@FactResenas - @ResenasOrigen, 'N0') END,
    -- La diferencia esperada es exactamente el numero de resenas rechazadas
    -- por la validacion de rango 1..5.
    CASE WHEN @ResenasOrigen < 0 THEN 'OMITIDA'
         WHEN @FactResenas = @ResenasOrigen -
              (SELECT COUNT_BIG(*) FROM etl.Error
                WHERE ObjetoOrigen = 'resenas' AND Severidad = 'RECHAZO'
                  AND EjecucionId = (SELECT MAX(EjecucionId) FROM etl.Ejecucion))
              THEN 'OK'
         ELSE 'REVISAR' END;

DECLARE @FactInteracciones bigint = (SELECT COUNT_BIG(*) FROM dw.FactInteraccionWeb);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT
    'Conteo de interacciones: MongoDB vs dw.FactInteraccionWeb',
    CASE WHEN @InteraccionesOrigen < 0 THEN 'no informado' ELSE FORMAT(@InteraccionesOrigen, 'N0') END,
    FORMAT(@FactInteracciones, 'N0'),
    CASE WHEN @InteraccionesOrigen < 0 THEN 'n/d'
         ELSE FORMAT(@FactInteracciones - @InteraccionesOrigen, 'N0') END,
    CASE WHEN @InteraccionesOrigen < 0 THEN 'OMITIDA'
         WHEN @FactInteracciones = @InteraccionesOrigen THEN 'OK'
         ELSE 'REVISAR' END;

/* =====================================================================
   BLOQUE 2 - Integridad: ningun hecho apunta a la fila "No aplica"
                          por un fallo de resolucion de claves
   ===================================================================== */

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'FactReserva sin ClienteKey resuelta', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE ClienteKey = -1;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'FactReserva sin EstadoKey resuelta', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE EstadoKey = -1;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'FactReserva con FechaInicioKey invalida', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE FechaInicioKey = -1;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'FactReservaHabitacion sin HotelKey resuelta', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReservaHabitacion WHERE HotelKey = -1;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'FactReservaTour sin TourKey resuelta', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReservaTour WHERE TourKey = -1;

/* Huerfanos reales: claves de hechos que no existen en la dimension. */
INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Huerfanos FactReserva -> DimCliente', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva f
LEFT JOIN dw.DimCliente d ON d.ClienteKey = f.ClienteKey
WHERE d.ClienteKey IS NULL;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Huerfanos FactReserva -> DimTiempo', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva f
LEFT JOIN dw.DimTiempo d ON d.TiempoKey = f.FechaInicioKey
WHERE d.TiempoKey IS NULL;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Huerfanos FactOcupacionDiaria -> DimHotel', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactOcupacionDiaria f
LEFT JOIN dw.DimHotel d ON d.HotelKey = f.HotelKey
WHERE d.HotelKey IS NULL;

/* Restricciones que quedaron sin validar tras la carga masiva. */
INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Claves foraneas no confiables o deshabilitadas', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM sys.foreign_keys
WHERE OBJECT_SCHEMA_NAME(parent_object_id) = 'dw'
  AND (is_not_trusted = 1 OR is_disabled = 1);

/* =====================================================================
   BLOQUE 3 - Unicidad: la recarga no duplico hechos
   ===================================================================== */

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'ReservaId duplicados en dw.FactReserva', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM (SELECT ReservaId FROM dw.FactReserva GROUP BY ReservaId HAVING COUNT(*) > 1) d;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'ClienteId duplicados en dw.DimCliente', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM (SELECT ClienteId FROM dw.DimCliente GROUP BY ClienteId HAVING COUNT(*) > 1) d;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Pares (dia, hotel) duplicados en FactOcupacionDiaria', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM (SELECT TiempoKey, HotelKey FROM dw.FactOcupacionDiaria
       GROUP BY TiempoKey, HotelKey HAVING COUNT(*) > 1) d;

/* =====================================================================
   BLOQUE 4 - Coherencia de negocio: los KPI caen en rangos posibles
   ===================================================================== */

DECLARE @OcupMax decimal(8,2) = (
    SELECT MAX(100.0 * HabitacionesOcupadas / NULLIF(HabitacionesDisponibles, 0))
    FROM dw.FactOcupacionDiaria);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Ocupacion diaria maxima por hotel (%)', '<= 100',
       FORMAT(ISNULL(@OcupMax, 0), 'N2'), '',
       -- Un valor por encima de 100 % significaria doble conteo al explotar
       -- las estadias, o una capacidad instalada mal calculada.
       CASE WHEN ISNULL(@OcupMax, 0) <= 100.0 THEN 'OK' ELSE 'REVISAR' END;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Reservas con noches negativas', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE Noches < 0;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Reservas con monto negativo', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva WHERE MontoTotal < 0;

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Resenas fuera del rango 1..5', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactResena WHERE Calificacion NOT BETWEEN 1 AND 5;

/* MontoConfirmado solo puede acumular reservas CONFIRMADAS. */
INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'MontoConfirmado en reservas no confirmadas', '0',
       FORMAT(COUNT_BIG(*), 'N0'), '', CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'REVISAR' END
FROM dw.FactReserva f
JOIN dw.DimEstadoReserva e ON e.EstadoKey = f.EstadoKey
WHERE e.EsConfirmada = 0 AND f.MontoConfirmado <> 0;

/* Cobertura temporal: el modelo debe cubrir todo el periodo del escenario. */
DECLARE @AniosCubiertos int = (
    SELECT COUNT(DISTINCT t.Anio)
    FROM dw.FactReserva f JOIN dw.DimTiempo t ON t.TiempoKey = f.FechaInicioKey);

INSERT INTO @Resultados (Prueba, Esperado, Obtenido, Diferencia, Veredicto)
SELECT 'Anios cubiertos por FactReserva', '6 (2021-2026)',
       CAST(@AniosCubiertos AS varchar(10)), '',
       CASE WHEN @AniosCubiertos >= 6 THEN 'OK' ELSE 'REVISAR' END;

/* =====================================================================
   SALIDA
   ===================================================================== */
PRINT '';
PRINT '=====================================================================';
PRINT ' VALIDACION DE CONSISTENCIA - TurismoDW';
PRINT '=====================================================================';

SELECT Orden, Prueba, Esperado, Obtenido, Diferencia, Veredicto
FROM @Resultados
ORDER BY Orden;

DECLARE @fallidas int = (SELECT COUNT(*) FROM @Resultados WHERE Veredicto = 'REVISAR');
DECLARE @omitidas int = (SELECT COUNT(*) FROM @Resultados WHERE Veredicto = 'OMITIDA');
DECLARE @total    int = (SELECT COUNT(*) FROM @Resultados);

SELECT [Pruebas] = @total,
       [Correctas] = @total - @fallidas - @omitidas,
       [Por revisar] = @fallidas,
       [Omitidas] = @omitidas,
       [Veredicto global] = CASE WHEN @fallidas = 0
                                 THEN 'MODELO CONSISTENTE'
                                 ELSE 'HAY PRUEBAS QUE REQUIEREN REVISION' END;
GO

/* =====================================================================
   Contraste de KPI: los mismos numeros que debe mostrar Power BI.
   Sirve para comparar tarjeta por tarjeta contra el dashboard.
   ===================================================================== */
PRINT '';
PRINT '=== KPI de referencia para contrastar contra Power BI ===';

SELECT [KPI] = 'Reservas totales',
       [Valor] = FORMAT(COUNT_BIG(*), 'N0')
FROM dw.FactReserva
UNION ALL
SELECT 'Reservas confirmadas',
       FORMAT(COUNT_BIG(*), 'N0')
FROM dw.FactReserva f JOIN dw.DimEstadoReserva e ON e.EstadoKey = f.EstadoKey
WHERE e.EsConfirmada = 1
UNION ALL
SELECT 'Ingresos confirmados (USD)',
       FORMAT(SUM(MontoConfirmado), 'N2')
FROM dw.FactReserva
UNION ALL
SELECT 'Ticket promedio confirmado (USD)',
       FORMAT(SUM(MontoConfirmado) / NULLIF(SUM(CAST(EsCancelada AS int) * 0
              + CASE WHEN MontoConfirmado > 0 THEN 1 ELSE 0 END), 0), 'N2')
FROM dw.FactReserva
UNION ALL
SELECT 'Promedio de estadia (noches)',
       FORMAT(AVG(CAST(Noches AS decimal(10,4))), 'N2')
FROM dw.FactReserva
UNION ALL
SELECT 'Dias de anticipacion promedio',
       FORMAT(AVG(CAST(DiasAnticipacion AS decimal(10,4))), 'N2')
FROM dw.FactReserva
UNION ALL
SELECT 'Tasa de cancelacion (%)',
       FORMAT(100.0 * SUM(CAST(EsCancelada AS bigint)) / NULLIF(COUNT_BIG(*), 0), 'N2')
FROM dw.FactReserva
UNION ALL
SELECT 'Ocupacion hotelera promedio (%)',
       FORMAT(100.0 * SUM(CAST(HabitacionesOcupadas AS bigint))
              / NULLIF(SUM(CAST(HabitacionesDisponibles AS bigint)), 0), 'N2')
FROM dw.FactOcupacionDiaria
UNION ALL
SELECT 'Calificacion promedio de resenas',
       FORMAT(AVG(CAST(Calificacion AS decimal(10,4))), 'N2')
FROM dw.FactResena
UNION ALL
SELECT 'Indice de satisfaccion (% promotores)',
       FORMAT(100.0 * SUM(CAST(EsPositiva AS bigint)) / NULLIF(COUNT_BIG(*), 0), 'N2')
FROM dw.FactResena
UNION ALL
SELECT 'Tasa de conversion web (%)',
       FORMAT(100.0 * SUM(CAST(EsConversion AS bigint)) / NULLIF(COUNT_BIG(*), 0), 'N2')
FROM dw.FactInteraccionWeb;
GO

PRINT '';
PRINT '=== Top 10 destinos mas visitados (contraste con la pagina 4 del reporte) ===';
SELECT TOP (10)
    [Destino]  = h.Ciudad + ', ' + h.Pais,
    [Reservas] = FORMAT(COUNT_BIG(DISTINCT f.ReservaId), 'N0'),
    [Ingresos] = FORMAT(SUM(f.IngresoAlojamiento), 'N2')
FROM dw.FactReservaHabitacion f
JOIN dw.DimHotel h ON h.HotelKey = f.HotelKey
JOIN dw.DimEstadoReserva e ON e.EstadoKey = f.EstadoKey
WHERE e.EsConfirmada = 1
GROUP BY h.Ciudad, h.Pais
ORDER BY COUNT_BIG(DISTINCT f.ReservaId) DESC;
GO

PRINT '';
PRINT '=== Reservas por temporada y anio ===';
SELECT
    t.Anio,
    t.TemporadaTuristica,
    [Reservas] = FORMAT(COUNT_BIG(*), 'N0'),
    [Ingresos] = FORMAT(SUM(f.MontoConfirmado), 'N2')
FROM dw.FactReserva f
JOIN dw.DimTiempo t ON t.TiempoKey = f.FechaInicioKey
GROUP BY t.Anio, t.TemporadaTuristica
ORDER BY t.Anio, t.TemporadaTuristica;
GO
