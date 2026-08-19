# Contrato de entrega — Integrante 1 → Integrante 2

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3**
De: **Alex Herrera** (ingreso de datos al modelo analítico)
Para: **Integrante 2** (filegroups, particionamiento e índices)

---

## Qué te entrego

La base `TurismoDW` creada, poblada y con estadísticas al día, en la instancia **`MSSQLSERVER`** (Enterprise Evaluation 2022), accesible por el alias **`TURISMODW`**.

```
sqlcmd -S TURISMODW -E -C -d TurismoDW
```

### Filegroups ya creados

Creé la estructura física base para que las tablas no cayeran todas en `PRIMARY`. **No creé los filegroups por rango de año**: eso es tuyo, porque depende de cómo decidas particionar.

| Filegroup | Archivos | Contenido | Tamaño inicial |
|---|---|---|---|
| `PRIMARY` | `TurismoDW_sys.mdf` | Sólo metadatos del sistema | 128 MB |
| `FG_DIM` | `TurismoDW_dim01.ndf` | Las 8 dimensiones + tablas de `etl` | 256 MB |
| `FG_FACT` | `TurismoDW_fact01.ndf`, `fact02.ndf` | Las 6 tablas de hechos. **Es el filegroup por defecto.** | 2 GB × 2 |
| `FG_STG` | `TurismoDW_stg01.ndf` | Staging del ETL (volátil, se trunca en cada corrida) | 2 GB |
| `FG_IDX` | `TurismoDW_idx01.ndf` | Índices no agrupados | 1 GB |

Ruta: `D:\DB\mssql\TurismoDW\data\` — fuera de `C:\Program Files`, que es donde SQL Server los pondría por defecto.

---

## La frontera entre tu trabajo y el mío

| Es mío | Es tuyo |
|---|---|
| `CREATE DATABASE` y filegroups por propósito | Filegroups por rango de año (`FG_FACT_2021`…) |
| Definición de las tablas del modelo estrella | `CREATE PARTITION FUNCTION` / `SCHEME` |
| Índice agrupado sobre la clave subrogada | Todos los índices no agrupados y columnstore |
| Índices únicos sobre claves de negocio (son restricciones de calidad, no tuning) | Índices de cobertura, filtrados, incluidos |
| Poblar los datos y mantener estadísticas | Comparación de rendimiento antes/después |

**Importante: entregué las tablas de hechos SIN índices no agrupados, a propósito.** Así tu comparación «antes y después» parte de una línea base limpia. Si hubiera dejado índices de tuning, tus mediciones ya vendrían contaminadas.

Los únicos índices que verás sobre los hechos son `UQ_*_Negocio`. **No los borres**: no son tuning, son lo que impide que una segunda corrida del ETL duplique filas.

---

## Clave de partición acordada

```
dw.FactReserva.FechaInicioKey   INT   -- formato yyyymmdd
```

### Por qué esta columna y no otra

1. **Es por la que se consulta.** Todo el dashboard filtra por fecha de inicio de la estadía: KPIs por temporada, tendencias anuales, ocupación. Particionar por una columna que nadie filtra no elimina particiones en el plan.
2. **Reparte parejo.** Las 2 000 000 de reservas están distribuidas entre 2021-01-01 y 2026-12-31 con estacionalidad realista (picos en diciembre-enero y julio), así que ninguna partición queda vacía ni desbalanceada de forma patológica.
3. **Es `INT`, no `DATE`.** El formato `yyyymmdd` ordena igual que la fecha, ocupa 4 bytes y los límites de partición se escriben como enteros legibles.
4. **Permite archivar por año** con `SWITCH PARTITION`, que es el caso de uso real de «las tablas de gran volumen crecen sin una estrategia de particionamiento».

### Límites sugeridos

```sql
CREATE PARTITION FUNCTION pf_TurismoAnio (int)
AS RANGE RIGHT FOR VALUES
    (20210101, 20220101, 20230101, 20240101, 20250101, 20260101, 20270101);
```

`RANGE RIGHT` deja cada límite como primer valor de su partición, que es lo que se quiere con fechas: la partición de 2023 contiene `[20230101, 20240101)`.

Eso da 8 particiones: una previa a 2021 (vacía, es el colchón para datos históricos), seis con un año cada una, y una posterior a 2027 (vacía, es donde crece).

### Distribución real de las filas

Ejecutá esto para ver el reparto exacto antes de decidir los límites:

```sql
SELECT t.Anio, COUNT_BIG(*) AS Filas
FROM dw.FactReserva f
JOIN dw.DimTiempo t ON t.TiempoKey = f.FechaInicioKey
GROUP BY t.Anio
ORDER BY t.Anio;
```

### Otras tablas candidatas

`dw.FactReservaHabitacion` (1.7 M) y `dw.FactReservaTour` (2.7 M) también tienen `FechaInicioKey` y siguen el mismo criterio. Si las alineás con el mismo esquema de partición, los `JOIN` entre hechos pueden usar **colocación de particiones**, que evita repartición en el plan.

`dw.FactOcupacionDiaria` (~400 K) usa `TiempoKey` con el mismo formato.

---

## Consultas testigo para tu comparación antes/después

Estas cinco consultas son las que el dashboard ejecuta de verdad. Capturá el plan y el `SET STATISTICS IO, TIME ON` de cada una antes de tocar nada, y repetí después.

```sql
SET STATISTICS IO, TIME ON;

-- T1. Eliminación de particiones: un año concreto.
--     Sin partición: scan completo. Con partición: toca 1 de 8.
SELECT COUNT_BIG(*), SUM(MontoConfirmado)
FROM dw.FactReserva
WHERE FechaInicioKey BETWEEN 20240101 AND 20241231;

-- T2. KPI de ocupación hotelera por país y mes (la página 2 del reporte).
SELECT h.Pais, t.Anio, t.Mes,
       100.0 * SUM(CAST(o.HabitacionesOcupadas AS bigint))
             / NULLIF(SUM(CAST(o.HabitacionesDisponibles AS bigint)), 0) AS PctOcupacion
FROM dw.FactOcupacionDiaria o
JOIN dw.DimHotel  h ON h.HotelKey  = o.HotelKey
JOIN dw.DimTiempo t ON t.TiempoKey = o.TiempoKey
WHERE t.Anio >= 2024
GROUP BY h.Pais, t.Anio, t.Mes;

-- T3. Ranking de tours más solicitados (página 4).
SELECT TOP (20) tr.Nombre, tr.Destino,
       COUNT_BIG(*) AS Veces, SUM(ft.IngresoTour) AS Ingreso
FROM dw.FactReservaTour ft
JOIN dw.DimTour tr ON tr.TourKey = ft.TourKey
JOIN dw.DimEstadoReserva e ON e.EstadoKey = ft.EstadoKey
WHERE e.EsConfirmada = 1
GROUP BY tr.Nombre, tr.Destino
ORDER BY Veces DESC;

-- T4. Perfil del visitante cruzado con satisfacción (página 5).
SELECT c.PaisOrigen, c.RangoEdad,
       COUNT_BIG(DISTINCT f.ReservaId) AS Reservas,
       AVG(CAST(r.Calificacion AS decimal(10,4))) AS CalifPromedio
FROM dw.FactReserva f
JOIN dw.DimCliente c ON c.ClienteKey = f.ClienteKey
LEFT JOIN dw.FactResena r ON r.ClienteKey = f.ClienteKey
GROUP BY c.PaisOrigen, c.RangoEdad;

-- T5. Tendencia mensual completa (página 1: la más pesada, recorre todo).
SELECT t.Anio, t.Mes,
       COUNT_BIG(*) AS Reservas,
       SUM(f.MontoConfirmado) AS Ingresos,
       AVG(CAST(f.Noches AS decimal(10,4))) AS EstadiaPromedio
FROM dw.FactReserva f
JOIN dw.DimTiempo t ON t.TiempoKey = f.FechaInicioKey
GROUP BY t.Anio, t.Mes
ORDER BY t.Anio, t.Mes;
```

El **Query Store ya está activado** en la base (modo `READ_WRITE`, intervalos de 15 minutos, hasta 2 GB), así que tenés el histórico de planes y duraciones sin tener que capturarlo a mano:

```sql
SELECT TOP (20)
    qt.query_sql_text,
    rs.avg_duration / 1000.0        AS ms_promedio,
    rs.avg_logical_io_reads         AS lecturas_logicas,
    rs.count_executions
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p        ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
ORDER BY rs.avg_duration DESC;
```

---

## Lo que NO debés cambiar

Estas tres cosas romperían el ETL o el reporte:

1. **Los nombres de las tablas y columnas de `dw`.** El ETL y el modelo de Power BI se enlazan por nombre.
2. **Los índices `UQ_*_Negocio`.** Son la garantía de idempotencia del ETL.
3. **El modelo de recuperación `FULL`.** Lo necesita el Integrante 3 para Mirroring.

Todo lo demás —índices, particiones, compresión, columnstore— es territorio libre.

### Sobre las vistas

Power BI consume `dw.vw_*`, no las tablas. Eso es deliberado: podés reparticionar y reconstruir índices sin que el `.pbix` se entere. Si necesitás cambiar la definición de una vista, avisame primero, porque el modelo semántico depende de sus nombres de columna.

---

## Después de que particiones: reejecutar el ETL

`etl.usp_CargarHechos` hace `TRUNCATE TABLE` sobre los hechos. **`TRUNCATE` funciona sobre tablas particionadas**, así que el ETL sigue corriendo sin cambios.

Si preferís cargar partición por partición (`SWITCH PARTITION` desde una tabla de trabajo, que es el patrón óptimo para cargas incrementales), decime y ajusto el procedimiento.

---

## Estado actual del volumen

| Tabla | Filas aproximadas | Filegroup |
|---|---|---|
| `dw.FactReserva` | 2 000 005 | `FG_FACT` |
| `dw.FactReservaTour` | 2 680 006 | `FG_FACT` |
| `dw.FactReservaHabitacion` | 1 700 004 | `FG_FACT` |
| `dw.FactInteraccionWeb` | 1 500 000 | `FG_FACT` |
| `dw.FactResena` | 500 000 | `FG_FACT` |
| `dw.FactOcupacionDiaria` | ~400 000 | `FG_FACT` |
| `dw.DimCliente` | 50 006 | `FG_DIM` |
| `dw.DimTiempo` | 2 923 | `FG_DIM` |
| `dw.DimTipoHabitacion` | 792 | `FG_DIM` |
| `dw.DimTour` | 401 | `FG_DIM` |
| `dw.DimHotel` | 201 | `FG_DIM` |
| `dw.DimPaquete` | 151 | `FG_DIM` |

Rango temporal: **2021-01-01 a 2026-12-31**, seis años completos.

---

## Tu espacio en el dashboard

La **página 6 (Estado del sistema)** del reporte de Power BI tiene un bloque reservado para tus resultados de particionamiento e índices, como pide el enunciado («despliegue de datos en reporte PBI» para ambos integrantes). Pasame los números en una tabla y los conecto, o si preferís armás la sección vos mismo sobre el mismo `.pbix`.
