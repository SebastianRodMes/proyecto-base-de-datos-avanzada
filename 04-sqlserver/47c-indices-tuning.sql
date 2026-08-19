/* =====================================================================
   ITI-821 Escenario 8 - Integrante 2 (Sebastian)
   47c-indices-tuning.sql
   ---------------------------------------------------------------------
   Indices de tuning para las 5 consultas testigo. Se crean DESPUES de
   particionar (47b) y ANTES de la segunda medicion con 47a.

   Estrategia:
     - Columnstore no agrupado sobre los hechos grandes: es el indice
       optimo para las consultas analiticas de agregacion (T2, T3, T5).
       Alineado al esquema de particion -> combina eliminacion de
       particiones + compresion columnar.
     - Un par de indices rowstore de cobertura para los patrones de
       seek puntuales (T1, T4).

   Todos alineados a ps_TurismoAnio para conservar la eliminacion de
   particiones. Los indices columnstore van al mismo esquema.
   ===================================================================== */
SET NOCOUNT ON;
USE TurismoDW;
GO

/* ---------------------------------------------------------------------
   Columnstore no agrupado sobre los hechos de gran volumen.
   Se listan columnas de medida + claves usadas en agregacion/JOIN.
   --------------------------------------------------------------------- */
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactReserva
ON dw.FactReserva
    (FechaInicioKey, ClienteKey, EstadoKey, MontoConfirmado, MontoTotal,
     Noches, ConteoReserva, EsCancelada, ReservaId)
ON ps_TurismoAnio(FechaInicioKey);
GO

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactReservaTour
ON dw.FactReservaTour
    (FechaInicioKey, TourKey, EstadoKey, IngresoTour, ConteoTour)
ON ps_TurismoAnio(FechaInicioKey);
GO

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactOcupacionDiaria
ON dw.FactOcupacionDiaria
    (TiempoKey, HotelKey, HabitacionesOcupadas, HabitacionesDisponibles,
     PersonasAlojadas, IngresoDia)
ON ps_TurismoAnio(TiempoKey);
GO

/* ---------------------------------------------------------------------
   Indices rowstore de cobertura para los seek puntuales.
   --------------------------------------------------------------------- */

-- T1: filtro por rango de FechaInicioKey + suma de MontoConfirmado.
--     La PK agrupada arranca por ReservaKey, asi que este NC da el seek.
CREATE NONCLUSTERED INDEX IX_FactReserva_FechaInicio
ON dw.FactReserva (FechaInicioKey)
INCLUDE (MontoConfirmado, ConteoReserva)
ON ps_TurismoAnio(FechaInicioKey);
GO

-- T4: perfil por cliente (agrupa por atributos de DimCliente).
CREATE NONCLUSTERED INDEX IX_FactReserva_Cliente
ON dw.FactReserva (ClienteKey)
INCLUDE (ReservaId, FechaInicioKey)
ON ps_TurismoAnio(FechaInicioKey);
GO

-- Apoya el LEFT JOIN de T4 a FactResena por ClienteKey.
CREATE NONCLUSTERED INDEX IX_FactResena_Cliente
ON dw.FactResena (ClienteKey)
INCLUDE (Calificacion);
GO

/* ---------------------------------------------------------------------
   Actualizar estadisticas tras crear los indices.
   --------------------------------------------------------------------- */
UPDATE STATISTICS dw.FactReserva;
UPDATE STATISTICS dw.FactReservaTour;
UPDATE STATISTICS dw.FactOcupacionDiaria;
UPDATE STATISTICS dw.FactResena;
GO

PRINT '=== Indices sobre dw.FactReserva ===';
SELECT i.name AS Indice, i.type_desc AS Tipo,
       CASE WHEN ps.name IS NOT NULL THEN 'particionado: '+ps.name ELSE 'no particionado' END AS Esquema
FROM sys.indexes i
LEFT JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
WHERE i.object_id = OBJECT_ID('dw.FactReserva') AND i.type > 0
ORDER BY i.index_id;
GO
