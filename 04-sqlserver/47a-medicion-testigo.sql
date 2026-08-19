/* =====================================================================
   ITI-821 Escenario 8 - Integrante 2 (Sebastian)
   47a-medicion-testigo.sql
   ---------------------------------------------------------------------
   Las 5 consultas testigo del contrato (00-docs/03-contrato-integrante2.md)
   con captura de IO y tiempo. Se corre DOS VECES:
     1) ANTES de particionar/indexar  -> linea base
     2) DESPUES                        -> comparacion

   Guardar la salida de cada corrida en un archivo distinto, p.ej:
     antes.txt  y  despues.txt

   Uso (dentro del contenedor):
     /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Armagedon45*" -C \
        -d TurismoDW -i 47a-medicion-testigo.sql -o antes.txt
   ===================================================================== */
SET NOCOUNT ON;
USE TurismoDW;
GO
SET STATISTICS IO, TIME ON;
GO

PRINT '===== T1: eliminacion de particiones (un anio) =====';
SELECT COUNT_BIG(*) AS Reservas, SUM(MontoConfirmado) AS Ingreso
FROM dw.FactReserva
WHERE FechaInicioKey BETWEEN 20240101 AND 20241231;
GO

PRINT '===== T2: ocupacion hotelera por pais y mes =====';
SELECT h.Pais, t.Anio, t.Mes,
       100.0 * SUM(CAST(o.HabitacionesOcupadas AS bigint))
             / NULLIF(SUM(CAST(o.HabitacionesDisponibles AS bigint)), 0) AS PctOcupacion
FROM dw.FactOcupacionDiaria o
JOIN dw.DimHotel  h ON h.HotelKey  = o.HotelKey
JOIN dw.DimTiempo t ON t.TiempoKey = o.TiempoKey
WHERE t.Anio >= 2024
GROUP BY h.Pais, t.Anio, t.Mes;
GO

PRINT '===== T3: ranking de tours mas solicitados =====';
SELECT TOP (20) tr.Nombre, tr.Destino,
       COUNT_BIG(*) AS Veces, SUM(ft.IngresoTour) AS Ingreso
FROM dw.FactReservaTour ft
JOIN dw.DimTour tr ON tr.TourKey = ft.TourKey
JOIN dw.DimEstadoReserva e ON e.EstadoKey = ft.EstadoKey
WHERE e.EsConfirmada = 1
GROUP BY tr.Nombre, tr.Destino
ORDER BY Veces DESC;
GO

PRINT '===== T4: perfil del visitante vs satisfaccion =====';
SELECT c.PaisOrigen, c.RangoEdad,
       COUNT_BIG(DISTINCT f.ReservaId) AS Reservas,
       AVG(CAST(r.Calificacion AS decimal(10,4))) AS CalifPromedio
FROM dw.FactReserva f
JOIN dw.DimCliente c ON c.ClienteKey = f.ClienteKey
LEFT JOIN dw.FactResena r ON r.ClienteKey = f.ClienteKey
GROUP BY c.PaisOrigen, c.RangoEdad;
GO

PRINT '===== T5: tendencia mensual completa (la mas pesada) =====';
SELECT t.Anio, t.Mes,
       COUNT_BIG(*) AS Reservas,
       SUM(f.MontoConfirmado) AS Ingresos,
       AVG(CAST(f.Noches AS decimal(10,4))) AS EstadiaPromedio
FROM dw.FactReserva f
JOIN dw.DimTiempo t ON t.TiempoKey = f.FechaInicioKey
GROUP BY t.Anio, t.Mes
ORDER BY t.Anio, t.Mes;
GO

SET STATISTICS IO, TIME OFF;
GO
