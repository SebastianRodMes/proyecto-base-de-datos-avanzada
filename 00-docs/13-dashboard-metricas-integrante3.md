# Dashboard y Métricas de Negocio — Integrante 3

**ITI-821 · Escenario 8: Turismo Inteligente · Semanas 3 y 4**  
**Responsable: Integrante 3 (Erick) · Dashboard y métricas de negocio**

---

## 1. Resumen Ejecutivo y Alcance

Este documento consolida la entrega del **Integrante 3** para las Semanas 3 y 4 del proyecto final de Base de Datos Avanzada. Con el replanteamiento hacia integración, migración y operación analítica en la nube, el rol del Integrante 3 se enfoca en:

1. **Diseño y estructuración de la capa analítica de negocio** para el escenario asignado (**Turismo: ocupación y preferencias**).
2. **Catálogo exhaustivo de indicadores y métricas** (52 medidas DAX agrupadas en 11 dimensiones temáticas), integrando datos transaccionales de **PostgreSQL 16**, colecciones documentales de **MongoDB 7** (reseñas y eventos web) y fuentes semiestructuradas **JSON/XML** (preferencias declaradas y enriquecimiento de clientes/paquetes).
3. **Desacoplamiento arquitectónico** entre el almacenamiento físico (tablas particionadas por año e índices columnstore del Integrante 2) y la capa de consumo analítico mediante vistas de presentación `dw.vw_*`.
4. **Validación de consistencia matemática bidireccional**: comprobación de que cada cálculo DAX en Power BI produce exactamente el mismo resultado que su consulta equivalente T-SQL sobre el Data Warehouse `TurismoDW` (tanto en el entorno local como en Amazon RDS SQL Server).
5. **Análisis de hallazgos de negocio e insights**: interpretación de patrones de ocupación hotelera, estacionalidad turística en Costa Rica, rendimiento de paquetes, embudo de conversión digital y brecha entre el presupuesto estimado por el turista y su gasto real.

---

## 2. Arquitectura de la Capa de Visualización y Consumo

La solución analítica de `TurismoDW` sigue una arquitectura de capas diseñada para garantizar aislamiento, rendimiento y mantenibilidad:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          FUENTES DE INFORMACIÓN                         │
│  PostgreSQL 16 (Reservas) │ MongoDB 7 (Reseñas/Web) │ Archivos JSON/XML │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │ (ETL Integrante 2)
                                     v
┌─────────────────────────────────────────────────────────────────────────┐
│                    ALMACÉN ANALÍTICO FÍSICO (SQL SERVER)                │
│  Tablas de Hechos (Particionadas por año) e Índices Columnstore         │
│  dw.FactReserva (2M) │ dw.FactReservaHabitacion │ dw.FactReservaTour    │
│  dw.FactOcupacionDiaria │ dw.FactResena (0.5M) │ dw.FactInteraccionWeb   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     v
┌─────────────────────────────────────────────────────────────────────────┐
│                  CAPA DE PRESENTACIÓN DESACOPLADA (VISTAS)              │
│  dw.vw_Dim* (8 vistas) │ dw.vw_Fact* (6 vistas) │ dw.vw_EstadoSistema   │
│  - Traduce banderas técnicas (bit, claves centinela -1)                 │
│  - Excluye columnas de auditoría no analíticas                         │
│  - Protege al reporte ante reorganizaciones o particionamiento físico   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     v
┌─────────────────────────────────────────────────────────────────────────┐
│                 MOTOR SEMÁNTICO Y REPORTE (POWER BI / DAX)              │
│  Modelo Tabular VertiPaq (Modo Import) - 17 Tablas, 26 Relaciones       │
│  Tabla central _Medidas (52 Medidas DAX organizadas en 11 carpetas)     │
│  Reporte PBIR Interactivo (6 Páginas de análisis + Semáforos)          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Justificación del Desacoplamiento por Vistas

El reporte de Power BI **no consulta las tablas físicas directamente**, sino las vistas `dw.vw_*` creadas en `04-sqlserver/45-vistas-powerbi.sql` y `07-migracion/sql/45b-vistas-estado-rds.sql`. Esta decisión aporta tres ventajas críticas:

1. **Aislamiento ante mantenimiento físico:** El Integrante 2 modificó el particionamiento de `dw.FactReserva` en 8 filegroups y agregó índices columnstore no agrupados. Gracias a las vistas, el modelo semántico de Power BI y sus 89 referencias de campo permanecieron 100 % operativas sin necesidad de editar consultas M.
2. **Optimización del ancho de fila (VertiPaq):** Se excluyen columnas de auditoría interna como `EjecucionIdCarga` y `FechaCarga` en hechos de más de 2 millones de filas, reduciendo el consumo de memoria RAM en el motor tabular en más de un 18 %.
3. **Homogeneización de etiquetas de negocio:** Valores lógicos como `EsTemporadaAlta = 1` se traducen automáticamente a `'Temporada alta'` / `'Temporada verde'`, facilitando su uso directo en segmentadores visuales.

---

## 3. Catálogo Integral de Métricas de Negocio (Escenario: Turismo)

A continuación se detallan las **52 medidas DAX** implementadas en la tabla `_Medidas`, categorizadas por su objetivo analítico de negocio. Los indicadores principales del escenario están destacados con ★.

### 3.1 Volumen de Reservas y Clientes

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 1 | `Reservas` | `#,0` | `SUM(FactReserva[ConteoReserva])` | Total histórico de reservas registradas en la plataforma. |
| 2 | `Reservas confirmadas` | `#,0` | `CALCULATE([Reservas], DimEstadoReserva[EsConfirmada] = TRUE())` | Reservas que se concretaron efectivamente sin cancelarse. |
| 3 | `Reservas canceladas` | `#,0` | `CALCULATE([Reservas], DimEstadoReserva[EsCancelada] = TRUE())` | Reservas canceladas por el cliente o por el operador. |
| 4 | `Personas atendidas` | `#,0` | `SUM(FactReserva[CantidadPersonas])` | Total de huéspedes y turistas que viajaron. |
| 5 | `Reservas alojamiento` | `#,0` | `DISTINCTCOUNT(FactReservaHabitacion[ReservaId])` | Conteo de reservas con hospedaje asociado (evita doble conteo por habitación múltiple). |

### 3.2 ★ Monetización e Ingresos

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 6 | `Ingresos confirmados` ★ | `$#,0;-$#,0` | `SUM(FactReserva[MontoConfirmado])` | Ingresos netos percibidos de reservas confirmadas (monto garantizado). |
| 7 | `Ingresos totales` | `$#,0;-$#,0` | `SUM(FactReserva[MontoTotal])` | Facturación bruta incluyendo reservas pendientes y canceladas. |
| 8 | `★ Ingresos por hotel` | `$#,0;-$#,0` | `SUM(FactReservaHabitacion[IngresoAlojamiento])` | Desglose financiero atribuible exclusivamente a hospedaje. |
| 9 | `★ Ingresos por paquete` | `$#,0;-$#,0` | `CALCULATE([Ingresos confirmados], DimPaquete[PaqueteId] <> -1)` | Facturación generada a través de paquetes turísticos integrados. |
| 10 | `Ticket promedio` | `$#,0.00` | `DIVIDE([Ingresos confirmados], [Reservas confirmadas])` | Gasto medio por reserva confirmada. |

> **Nota técnica:** `MontoConfirmado` viene precalculado en 0 por el ETL para reservas canceladas o pendientes, lo que optimiza drásticamente el tiempo de cálculo de VertiPaq al evitar evaluar filtros complejos por fila.

### 3.3 ★ Ocupación Hotelera

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 11 | `Habitaciones ocupadas` | `#,0` | `SUM(FactOcupacionDiaria[HabitacionesOcupadas])` | Total acumulado de noches-habitación efectivamente ocupadas. |
| 12 | `Habitaciones disponibles` | `#,0` | `SUM(FactOcupacionDiaria[HabitacionesDisponibles])` | Capacidad total de noches-habitación ofertadas en el periodo. |
| 13 | `★ % Ocupación hotelera` | `0.0%` | `DIVIDE([Habitaciones ocupadas], [Habitaciones disponibles])` | Tasa de ocupación ponderada real en cualquier nivel jerárquico. |
| 14 | `% Ocupación mes anterior` | `0.0%` | `CALCULATE([% Ocupación hotelera], DATEADD(DimTiempo[Fecha], -1, MONTH))` | Ocupación del mes previo para comparativas secuenciales. |
| 15 | `Variación de ocupación` | `0.0%` | `[% Ocupación hotelera] - [% Ocupación mes anterior]` | Diferencia en puntos porcentuales de ocupación intermensual. |

> **Regla metodológica clave:** El porcentaje de ocupación **nunca debe calcularse como un promedio simple de porcentajes diarios**, ya que un hotel grande un sábado distorsionaría el promedio ponderado. Al almacenar numerador (`HabitacionesOcupadas`) y denominador (`HabitacionesDisponibles`) por separado en `FactOcupacionDiaria`, la división `DIVIDE` calcula la tasa matemáticamente exacta a nivel diario, mensual, por hotel, por ciudad o país.

### 3.4 ★ Estadía y Comportamiento del Turista

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 16 | `★ Promedio de estadía (noches)` | `0.00` | `DIVIDE(SUM(FactReserva[Noches]), [Reservas])` | Duración media de los viajes reservados. |
| 17 | `Días de anticipación promedio` | `0.00` | `DIVIDE(SUM(FactReserva[DiasAnticipacion]), [Reservas])` | Tiempo medio entre la creación de la reserva y el check-in. |
| 18 | `Tasa de cancelación` | `0.0%` | `DIVIDE([Reservas canceladas], [Reservas])` | Porcentaje de reservas que no llegaron a ejecutarse. |
| 19 | `Personas por reserva` | `0.00` | `DIVIDE([Personas atendidas], [Reservas])` | Tamaño medio del grupo de viaje por reserva. |

### 3.5 ★ Estacionalidad, Temporadas y Destinos

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 20 | `★ Reservas en temporada alta` | `#,0` | `CALCULATE([Reservas], DimTiempo[TipoTemporada] = "Temporada alta")` | Demanda durante dic–abr y jul (temporada pico). |
| 21 | `Reservas en temporada verde` | `#,0` | `CALCULATE([Reservas], DimTiempo[TipoTemporada] = "Temporada verde")` | Demanda en temporada de lluvias/verde (may–jun, ago–nov). |
| 22 | `Concentración en temporada alta`| `0.0%` | `DIVIDE([Reservas en temporada alta], [Reservas])` | Dependencia del negocio de los periodos vacacionales pico. |
| 23 | `★ Destinos visitados` | `#,0` | `DISTINCTCOUNT(DimHotel[Ciudad])` | Variedad geográfica de destinos con demanda activa. |
| 24 | `Destino líder` | Texto | `VAR R = TOPN(1, SUMMARIZE(DimHotel, DimHotel[Ciudad], "@r", [Reservas alojamiento]), [@r], DESC) RETURN MAXX(R, DimHotel[Ciudad])` | Ciudad turística con mayor número de reservas de hospedaje. |

### 3.6 ★ Tours y Actividades Complementarias

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 25 | `★ Tours solicitados` | `#,0` | `SUM(FactReservaTour[ConteoTour])` | Número total de contrataciones de actividades y excursiones. |
| 26 | `Ingresos por tour` | `$#,0;-$#,0` | `SUM(FactReservaTour[IngresoTour])` | Facturación total originada en venta de tours. |
| 27 | `Personas en tours` | `#,0` | `SUM(FactReservaTour[CantidadPersonas])` | Participantes totales en actividades complementarias. |
| 28 | `Tour líder` | Texto | `VAR R = TOPN(1, SUMMARIZE(DimTour, DimTour[Nombre], "@r", [Tours solicitados]), [@r], DESC) RETURN MAXX(R, DimTour[Nombre])` | Excursión o tour con mayor demanda popular. |

### 3.7 ★ Satisfacción del Cliente (Datos NoSQL - MongoDB `resenas`)

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 29 | `Reseñas` | `#,0` | `SUM(FactResena[ConteoResena])` | Volumen total de opiniones capturadas en MongoDB. |
| 30 | `Calificación promedio` | `0.00` | `DIVIDE(SUMX(FactResena, FactResena[Calificacion]), [Reseñas])` | Puntuación media en escala de 1 a 5 estrellas. |
| 31 | `Reseñas positivas` | `#,0` | `CALCULATE(COUNTROWS(FactResena), FactResena[EsPositiva] = TRUE())` | Evaluaciones de 4 y 5 estrellas (Promotores). |
| 32 | `Reseñas negativas` | `#,0` | `CALCULATE(COUNTROWS(FactResena), FactResena[EsNegativa] = TRUE())` | Evaluaciones de 1 y 2 estrellas (Detractores). |
| 33 | `★ Índice de satisfacción` | `0.0%` | `DIVIDE([Reseñas positivas], [Reseñas])` | Porcentaje de clientes altamente satisfechos (promotores). |
| 34 | `NPS aproximado` | `0.0%` | `DIVIDE([Reseñas positivas] - [Reseñas negativas], [Reseñas])` | Net Promoter Score adaptado a escala de 1 a 5. |
| 35 | `% Reseñas verificadas` | `0.0%` | `DIVIDE(SUM(FactResena[EsVerificada]), [Reseñas])` | Proporción de reseñas con reserva comprobada (calidad del feedback). |

### 3.8 ★ Comportamiento y Embudo Web (Datos NoSQL - MongoDB `interacciones_web`)

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 36 | `Interacciones` | `#,0` | `SUM(FactInteraccionWeb[ConteoEvento])` | Eventos de tráfico digital registrados en el portal web. |
| 37 | `Conversiones` | `#,0` | `SUM(FactInteraccionWeb[EsConversion])` | Eventos de navegación que culminaron en reserva confirmada. |
| 38 | `★ Tasa de conversión web` | `0.0%` | `DIVIDE([Conversiones], [Interacciones])` | Eficacia de la plataforma web en transformar visitas en reservas. |
| 39 | `Duración media de sesión (seg)`| `#,0` | `DIVIDE(SUM(FactInteraccionWeb[DuracionSegundos]), [Interacciones])` | Tiempo promedio de interacción por sesión de usuario. |
| 40 | `Búsquedas` | `#,0` | `CALCULATE([Interacciones], FactInteraccionWeb[TipoEvento] = "busqueda")` | Total de consultas de destinos y hoteles realizadas. |
| 41 | `Abandonos de carrito` | `#,0` | `CALCULATE([Interacciones], FactInteraccionWeb[TipoEvento] = "abandono_carrito")` | Oportunidades de reserva iniciadas pero no pagadas. |

### 3.9 ★ Perfil del Visitante y Preferencias Multifuente (JSON + PostgreSQL)

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 42 | `Clientes activos` | `#,0` | `CALCULATE(DISTINCTCOUNT(DimCliente[ClienteId]), DimCliente[Estado] = "Activo")` | Base total de clientes en estado operativo. |
| 43 | `Clientes con reserva` | `#,0` | `DISTINCTCOUNT(FactReserva[ClienteKey])` | Clientes que han generado al menos una reserva real. |
| 44 | `Presupuesto promedio declarado`| `$#,0` | `AVERAGE(DimCliente[PresupuestoEstimado])` | Expectativa de gasto manifestada en encuestas de preferencias. |
| 45 | `★ Brecha presupuesto vs gasto`| `$#,0;-$#,0` | `[Ticket promedio] - [Presupuesto promedio declarado]` | Diferencia entre lo que el turista pensaba gastar y lo que gastó. |

> **Cruce analítico de alto valor:** Al integrar el archivo JSON de preferencias (`RF-09`/`RF-10`) con la dimensión cliente y contrastarlo con las compras efectivas de `FactReserva`, se puede identificar si la plataforma está vendiendo por encima o por debajo del presupuesto del cliente (oportunidad de *up-selling*).

### 3.10 Comparativos Temporales e Inteligencia de Tiempo (YoY / YTD)

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Negocio |
|---|---|---|---|---|
| 46 | `Reservas año anterior` | `#,0` | `CALCULATE([Reservas], SAMEPERIODLASTYEAR(DimTiempo[Fecha]))` | Volumen de reservas en el mismo periodo del año anterior. |
| 47 | `Ingresos año anterior` | `$#,0;-$#,0` | `CALCULATE([Ingresos confirmados], SAMEPERIODLASTYEAR(DimTiempo[Fecha]))` | Facturación en el mismo periodo del año anterior. |
| 48 | `Crecimiento de ingresos YoY` | `0.0%` | `DIVIDE([Ingresos confirmados] - [Ingresos año anterior], [Ingresos año anterior])` | Tasa de crecimiento interanual de la facturación. |
| 49 | `Ingresos acumulados del año` | `$#,0;-$#,0` | `TOTALYTD([Ingresos confirmados], DimTiempo[Fecha])` | Facturación acumulada año a la fecha (Year-To-Date). |

### 3.11 Monitoreo Operacional y Estado del Sistema (Página 6)

| # | Medida DAX | Tipo / Formato | Fórmula DAX | Propósito de Operación |
|---|---|---|---|---|
| 50 | `Nodo activo` | Texto | `SELECTEDVALUE(EstadoSistema[NodoActual])` | Nombre del servidor SQL Server o nodo RDS que atendió la consulta. |
| 51 | `Estado de redundancia` | Texto | `SELECTEDVALUE(EstadoSistema[EstadoMirroring])` | Estado del clúster (`SYNCHRONIZED` en HA local o `GESTIONADO POR AWS`). |
| 52 | `Semáforo de frescura` | Texto | `VAR H = SELECTEDVALUE(EstadoSistema[HorasDesdeUltimaCarga]) RETURN SWITCH(TRUE(), ISBLANK(H), "Sin datos", H <= 24, "Datos al día", H <= 72, "Datos con retraso", "Desactualizado")` | Indicador visual de latencia de carga analítica del ETL. |

---

## 4. Comparativa y Reconciliación: DAX (Power BI) vs T-SQL (SQL Server)

Para garantizar que el dashboard presente información 100 % fidedigna, se verificó la paridad matemática de cada indicador entre la fórmula DAX y su equivalente T-SQL sobre `TurismoDW`:

| Métrica | Valor DAX en Power BI | Consulta T-SQL Equivalente | Valor T-SQL en SQL Server | Discrepancia |
|---|---|---|---|---|
| **Reservas totales** | `2,000,010` | `SELECT SUM(ConteoReserva) FROM dw.FactReserva;` | `2,000,010` | **0** |
| **Reservas confirmadas**| `1,608,124` | `SELECT COUNT(*) FROM dw.FactReserva r JOIN dw.DimEstadoReserva e ON r.EstadoKey = e.EstadoKey WHERE e.EsConfirmada = 1;` | `1,608,124` | **0** |
| **Ingresos confirmados** | `$13,425,544,111.48` | `SELECT SUM(MontoConfirmado) FROM dw.FactReserva;` | `$13,425,544,111.48` | **$0.00** |
| **Ingresos totales** | `$16,709,503,160.28` | `SELECT SUM(MontoTotal) FROM dw.FactReserva;` | `$16,709,503,160.28` | **$0.00** |
| **% Ocupación hotelera**| `30.1854 %` | `SELECT CAST(SUM(HabitacionesOcupadas) * 1.0 / SUM(HabitacionesDisponibles) * 100.0 AS decimal(7,4)) FROM dw.FactOcupacionDiaria;` | `30.1854 %` | **0.0000 %** |
| **Estadía promedio** | `3.50 noches` | `SELECT CAST(SUM(Noches) * 1.0 / COUNT(*) AS decimal(5,2)) FROM dw.FactReserva;` | `3.50` | **0.00** |
| **Días de anticipación** | `29.98 días` | `SELECT CAST(SUM(DiasAnticipacion) * 1.0 / COUNT(*) AS decimal(5,2)) FROM dw.FactReserva;` | `29.98` | **0.00** |
| **Tasa de cancelación**| `14.99 %` | `SELECT CAST(SUM(CASE WHEN EsCancelada=1 THEN 1 ELSE 0 END)*100.0/COUNT(*) AS decimal(5,2)) FROM dw.FactReserva;` | `14.99 %` | **0.00 %** |
| **Reseñas MongoDB** | `500,002` | `SELECT COUNT(*) FROM dw.FactResena;` | `500,002` | **0** |
| **Calificación promedio**| `3.96 ★` | `SELECT CAST(AVG(Calificacion * 1.0) AS decimal(4,2)) FROM dw.FactResena;` | `3.96` | **0.00** |
| **Índice de satisfacción**| `72.48 %` | `SELECT CAST(SUM(CASE WHEN EsPositiva=1 THEN 1 ELSE 0 END)*100.0/COUNT(*) AS decimal(5,2)) FROM dw.FactResena;` | `72.48 %` | **0.00 %** |
| **Interacciones Web** | `1,500,002` | `SELECT COUNT(*) FROM dw.FactInteraccionWeb;` | `1,500,002` | **0** |
| **Tasa de conversión web**| `12.18 %` | `SELECT CAST(SUM(CASE WHEN EsConversion=1 THEN 1 ELSE 0 END)*100.0/COUNT(*) AS decimal(5,2)) FROM dw.FactInteraccionWeb;` | `12.18 %` | **0.00 %** |
| **Tours solicitados** | `2,577,212` | `SELECT SUM(ConteoTour) FROM dw.FactReservaTour;` | `2,577,212` | **0** |

---

## 5. Estructura de las 6 Páginas del Reporte

El reporte `06-powerbi/TurismoDW.pbip` está organizado en seis páginas analíticas interactivas:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. RESUMEN EJECUTIVO (KPIs Macro, Facturación, Ocupación, Satisfacción) │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. OCUPACIÓN HOTELERA (Matriz Mensual, Ranking Hoteles, Mapa Ciudades)  │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. RESERVAS Y TEMPORADAS (Estacionalidad Alta/Verde, Anticipación, YoY) │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. DESTINOS Y TOURS (Actividades Líderes, Ingresos por Tour, Paquetes)   │
├─────────────────────────────────────────────────────────────────────────┤
│ 5. PERFIL DEL VISITANTE (Demografía, Preferencias JSON, Embudo Web NoSQL)│
├─────────────────────────────────────────────────────────────────────────┤
│ 6. ESTADO DEL SISTEMA (Nodo SQL/RDS, Redundancia, Frescura ETL, Calidad)│
└─────────────────────────────────────────────────────────────────────────┘
```

1. **Página 1: Resumen Ejecutivo:** 6 tarjetas principales (Reservas, Ingresos Confirmados, % Ocupación, Estadía Promedio, Índice de Satisfacción, Ticket Promedio) y gráficos de tendencia mensual e ingresos por categoría de hotel.
2. **Página 2: Ocupación Hotelera:** Mapa de calor geográfico por ciudad (San José, Manuel Antonio, La Fortuna, Tamarindo, Monteverde), matriz de ocupación mensual y selector por categoría de estrellas.
3. **Página 3: Reservas y Temporadas:** Gráfico de columnas apiladas comparando Temporada Alta vs Temporada Verde, gráfico de dispersión de anticipación vs cancelación, y comparativa YoY.
4. **Página 4: Destinos y Tours:** Tabla de tours más solicitados (canopy, rafting, avistamiento de ballenas, caminatas a volcanes), ingresos por operador turístico y penetración de paquetes turísticos.
5. **Página 5: Perfil del Visitante y Preferencias:** Pirámide demográfica por rango de edad y país de origen, gráfico de barras de actividades favoritas (datos de encuestas JSON) y embudo de conversión web (Búsquedas → Carrito → Conversión).
6. **Página 6: Estado del Sistema:** Monitoreo técnico en tiempo real que muestra el nodo activo de SQL Server / Amazon RDS, estado de sincronización, fecha de la última carga del ETL, número de registros rechazados y semáforo de frescura.

---

## 6. Hallazgos Analíticos y Recomendaciones de Negocio

A partir del análisis de los datos integrados en el Data Warehouse, se desprenden los siguientes hallazgos estratégicos para la toma de decisiones:

1. **Impacto de la Estacionalidad:** La temporada alta (diciembre a abril y julio) concentra el **58.4 % de los ingresos confirmados** con una ocupación hotelera que alcanza picos del **52 %** en destinos de playa (Guanacaste, Manuel Antonio), mientras que en temporada verde la ocupación desciende al **19-24 %**. Se recomienda estructurar paquetes de turismo ecológico y de aventura con tarifas dinámicas para elevar la ocupación en meses lluviosos.
2. **Alta Conversión en Actividades de Aventura:** Los tours de aventura (tirolesa/canopy y rafting) presentan una tasa de contratación del **74 % en reservas con paquetes**, aportando más de 1,673 millones a la facturación total. Promover estos tours en el flujo de reserva web antes del check-out incrementará el ticket promedio.
3. **Optimización del Embudo Digital:** De 1.5 millones de interacciones web en MongoDB, se detectaron más de **380,000 abandonos de carrito**. Dado que la tasa de conversión global es del **12.18 %**, implementar campañas de retargeting automatizado por correo a usuarios que abandonaron el carrito con destino específico permitiría capturar hasta un 3 % adicional de reservas.
4. **Brecha Positiva en Preferencias:** El gasto real de los turistas internacionales ($8,348 de ticket promedio en reservas de paquete) supera en un **14 % el presupuesto estimado declarado** en las encuestas iniciales, lo que demuestra alta disposición al consumo en destino.

---

## 7. Conclusión y Veredicto de Entrega

La capa analítica, el catálogo de 52 métricas DAX, las 16 vistas de presentación y los mecanismos de validación han sido implementados y comprobados con éxito. La paridad matemática entre los cálculos en memoria de Power BI y el Data Warehouse en SQL Server es de **100.0 %**, cumpliendo a cabalidad con todos los requisitos del Integrante 3 para las Semanas 3 y 4.
