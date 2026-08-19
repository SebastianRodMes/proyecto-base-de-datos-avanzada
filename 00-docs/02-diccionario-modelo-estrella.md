# Diccionario del modelo estrella `TurismoDW`

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Documenta el grano de cada tabla, el significado de cada columna y el linaje campo → fuente que exige RNF-05.

---

## Convenciones

| Convención | Razón |
|---|---|
| Claves subrogadas `INT IDENTITY` con sufijo `Key` | El DW no depende de que el origen mantenga sus identificadores. Si mañana PostgreSQL renumera clientes, el modelo sobrevive. |
| Claves de negocio conservadas (`ClienteId`, `ReservaId`…) | Sin ellas no se puede volver del hecho al registro original. Es la mitad de la trazabilidad de RNF-05. |
| Fila `-1` «No aplica» en cada dimensión | Todo hecho tiene una clave válida aunque el origen venga incompleto. Permite usar `INNER JOIN` en todas las consultas sin perder filas. |
| `TiempoKey` entero `yyyymmdd` | 4 bytes en lugar de 8 de `datetime`, legible al depurar, y sirve directo como límite de partición. |
| Columnas `Conteo*` con valor 1 | `SUM` sobre una columna `tinyint` es más rápido que `COUNTROWS` en VertiPaq con millones de filas. |
| `EjecucionIdCarga` + `FechaCarga` en cada tabla | Responde «¿de qué corrida vino esta fila?» sin auditoría externa. |

---

## Granularidad — la decisión más importante del modelo

El grano se fija antes que cualquier columna, porque es lo que determina si las medidas se pueden sumar sin doble conteo.

| Tabla | Una fila representa | Filas |
|---|---|---|
| `FactReserva` | una reserva | 2 000 005 |
| `FactReservaHabitacion` | una reserva × un tipo de habitación | 1 700 004 |
| `FactReservaTour` | una reserva × un tour | 2 680 006 |
| `FactOcupacionDiaria` | un hotel × un día | ~400 000 |
| `FactResena` | una reseña | 500 000 |
| `FactInteraccionWeb` | un evento de navegación | 1 500 000 |

**Consecuencia práctica:** contar filas de `FactReservaHabitacion` no da el número de reservas, porque una reserva con dos tipos de habitación aparece dos veces. Por eso la medida `Reservas alojamiento` usa `DISTINCTCOUNT(FactReservaHabitacion[ReservaId])` y no `COUNTROWS`.

---

## Dimensiones

### `dw.DimTiempo` — calendario

Generada, no extraída. Cubre 2020-01-01 a 2027-12-31 (2 923 filas + centinela `-1`).

| Columna | Tipo | Descripción | Origen |
|---|---|---|---|
| `TiempoKey` | `int` | Clave `yyyymmdd`. PK. | calculada |
| `Fecha` | `date` | Fecha real. Es la columna que marca la tabla como *tabla de fechas*. | calculada |
| `Anio`, `Trimestre`, `Mes`, `Semana` | `smallint`/`tinyint` | Componentes numéricos para agrupar y ordenar. | calculada |
| `NombreMes`, `NombreMesCorto`, `NombreTrimestre` | `varchar` | Etiquetas en español. | calculada |
| `AnioMes` | `int` | `yyyymm`. Columna de ordenación de `AnioMesEtiqueta`. | calculada |
| `DiaSemana`, `NombreDiaSemana` | | 1 = lunes, independiente de `@@DATEFIRST`. | calculada |
| `EsFinDeSemana` | `bit` | | calculada |
| `TemporadaTuristica` | `varchar(20)` | `Alta` (dic–abr y jul) / `Verde` (resto). Corresponde a la estacionalidad de Costa Rica y la región. | regla de negocio |
| `EsTemporadaAlta` | `bit` | | regla de negocio |

> La definición de temporada es una **regla de negocio explícita del modelo**, no un dato del origen. Está aquí y no en DAX para que todos los integrantes usen el mismo criterio.

### `dw.DimCliente` — visitante (SCD tipo 1)

Aplana `cliente` + `preferencia_cliente`. 50 006 filas.

| Columna | Descripción | Linaje |
|---|---|---|
| `ClienteKey` | Clave subrogada. PK. | IDENTITY |
| `ClienteId` | Clave de negocio. | `cliente.cliente_id` |
| `Identificacion` | Documento. Es la llave de cruce con los archivos JSON. | `cliente.identificacion` |
| `NombreCompleto` | `nombre` + `apellidos` concatenados. | `cliente.*` |
| `PaisOrigen` | Nulos y vacíos → `'Sin país'`. | `cliente.pais_origen` |
| `Edad` | `DATEDIFF` contra la fecha de la corrida. | derivada |
| `RangoEdad` | `18-24` / `25-34` / `35-44` / `45-54` / `55-64` / `65+` / `Sin dato` | derivada |
| `Estado` | `Activo` / `Inactivo`. | `cliente.activo` |
| `DestinosPreferidos`, `TipoAlojamiento`, `ActividadesFavoritas`, `TemporadaViaje` | Preferencias declaradas (RF-09). | `preferencia_cliente.*` |
| `PresupuestoEstimado` | | `preferencia_cliente.presupuesto_estimado` |
| `RangoPresupuesto` | `Bajo` / `Medio` / `Alto` / `Premium`. | derivada |
| `Idioma`, `Dieta`, `GrupoViaje`, `EsVip` | Extraídos del JSONB con `JSON_VALUE`, previa validación con `ISJSON`. | `preferencia_cliente.datos_adicionales` |
| `FuenteDatos` | `POSTGRESQL` o `POSTGRESQL+JSON` si un archivo lo enriqueció. | metadato |

> **SCD tipo 1** (sobrescribe, no versiona) porque el escenario no pide analizar cómo cambian las preferencias de un cliente en el tiempo. Si se necesitara, habría que añadir `FechaDesde` / `FechaHasta` / `EsVigente` y cambiar el `MERGE`.

### `dw.DimHotel` — 201 filas

| Columna | Descripción | Linaje |
|---|---|---|
| `HotelKey` / `HotelId` | Subrogada / negocio. | IDENTITY / `hotel.hotel_id` |
| `Nombre`, `Categoria`, `Ciudad`, `Pais`, `Direccion`, `Servicios` | | `hotel.*` |
| `NumeroEstrellas` | Primer carácter de `categoria` (`'5 estrellas'` → 5). `NULL` para `Boutique`. | derivada |
| `PaisCiudad` | Concatenación para la jerarquía geográfica del mapa. | derivada |
| `CapacidadTotal`, `RangoCapacidad` | `Pequeño` / `Mediano` / `Grande` / `Muy grande`. | `hotel.capacidad_total` |
| `Estado` | `Operativo` / `Fuera de servicio`. | `hotel.activo` |

### `dw.DimTipoHabitacion` — 792 filas

Única dimensión con relación a otra (`HotelKey` → `DimHotel`). Es un *outrigger* consciente: mantener el tipo de habitación separado del hotel evita repetir los datos del hotel 4 veces por cada uno.

| Columna | Descripción | Linaje |
|---|---|---|
| `TipoHabitacionKey` / `TipoHabitacionId` | | IDENTITY / `tipo_habitacion.tipo_habitacion_id` |
| `HotelKey` | FK a `DimHotel`. | resuelta en el ETL |
| `Nombre`, `CapacidadPersonas`, `TarifaBase`, `CantidadDisponible` | | `tipo_habitacion.*` |
| `RangoTarifa` | `Económica` / `Media` / `Alta` / `Premium`. | derivada |

> `CantidadDisponible` es la **capacidad instalada**, y es el denominador de `FactOcupacionDiaria`.

### `dw.DimTour` — 401 filas

| Columna | Descripción | Linaje |
|---|---|---|
| `TourKey` / `TourId` | | IDENTITY / `tour.tour_id` |
| `Nombre`, `Destino`, `Proveedor`, `DuracionHoras`, `CupoMaximo`, `Precio` | | `tour.*` |
| `TipoActividad` | Clasificación contra el catálogo cerrado del escenario: `Canopy`, `Rafting`, `Buceo`, `City Tour`, `Avistamiento de Aves`, `Tour de Café`, `Kayak`, `Snorkel`, `Trekking`, `Safari Fotográfico`, `Cabalgata`, `Gastronómico`, `Otro`. | derivada del nombre |
| `RangoDuracion` | `Corto (≤3h)` / `Medio (4-6h)` / `Largo (7h+)`. | derivada |

### `dw.DimPaquete` — 151 filas

| Columna | Descripción | Linaje |
|---|---|---|
| `PaqueteKey` / `PaqueteId` | La fila `-1` es `'Sin paquete'`: ~15 % de las reservas son sólo de tour. | IDENTITY / `paquete_turistico.paquete_id` |
| `Nombre`, `DuracionDias`, `PrecioTotal`, `ServiciosAdicionales` | | `paquete_turistico.*` |
| `TipoPaquete` | `Aventura` / `Descanso` / `Cultural` / `Ecoturismo` / `Familiar` / `Luna de Miel` / `Premium` / `Express` / `General`. | derivada del nombre |
| `RangoDuracion`, `RangoPrecio` | | derivadas |
| `FuenteDatos` | `POSTGRESQL` o `POSTGRESQL+XML` si el documento XML lo enriqueció (RF-11). | metadato |

### `dw.DimEstadoReserva` — 4 filas

Catálogo cerrado, cargado por script y no por ETL: los estados son dominio de la aplicación.

| `EstadoKey` | `Estado` | `EsConfirmada` | `EsCancelada` | `CuentaParaIngreso` |
|---|---|---|---|---|
| -1 | `DESCONOCIDO` | 0 | 0 | 0 |
| 1 | `CONFIRMADA` | 1 | 0 | 1 |
| 2 | `PENDIENTE` | 0 | 0 | 0 |
| 3 | `CANCELADA` | 0 | 1 | 0 |

> Las banderas viven en la dimensión, no en DAX. Si mañana se decide que `PENDIENTE` también cuenta para ingresos, se cambia una fila y todo el reporte se ajusta.

### `dw.DimCanal`

Se construye por descubrimiento sobre `interacciones_web` de MongoDB: el ETL hace `MERGE` con los pares canal/dispositivo distintos que aparezcan. Un canal nuevo entra solo, sin tocar el modelo.

---

## Tablas de hechos

### `dw.FactReserva` — grano: 1 reserva

| Columna | Tipo | Descripción |
|---|---|---|
| `ReservaKey` | `bigint` | PK subrogada. |
| `ReservaId` | `bigint` | Clave de negocio. Índice único: garantiza idempotencia del ETL. |
| `FechaInicioKey` | `int` | **Clave de partición** acordada con el Integrante 2. |
| `FechaReservaKey`, `FechaFinKey` | `int` | Relaciones *role-playing* inactivas con `DimTiempo`. |
| `ClienteKey`, `PaqueteKey`, `EstadoKey` | `int` | FK dimensionales. |
| `CantidadPersonas` | `int` | Aditiva. |
| `MontoTotal` | `decimal(12,2)` | Aditiva. Incluye reservas canceladas. |
| `MontoConfirmado` | `decimal(12,2)` | Aditiva. `0` si no está confirmada. |
| `Noches` | `int` | `fecha_fin − fecha_inicio`. |
| `DiasAnticipacion` | `int` | `fecha_inicio − fecha_reserva`. |
| `EsCancelada` | `bit` | Sumable para la tasa de cancelación. |
| `ConteoReserva` | `tinyint` | Siempre 1. |

> **`MontoConfirmado` se precalcula en el ETL** en lugar de resolverse con `CALCULATE` en cada visual. Es el patrón de «filtro materializado»: cuesta una columna comprimible y ahorra un cambio de contexto en cada una de las decenas de medidas que lo usan.

### `dw.FactReservaHabitacion` — grano: reserva × tipo de habitación

Medidas: `CantidadHabitaciones`, `TarifaAplicada`, `Noches`, `NochesHabitacion` (= habitaciones × noches, la unidad correcta para comparar consumo entre estadías de distinta duración), `IngresoAlojamiento`.

### `dw.FactReservaTour` — grano: reserva × tour

Medidas: `CantidadPersonas`, `PrecioAplicado`, `IngresoTour`, `ConteoTour`.

### `dw.FactOcupacionDiaria` — grano: hotel × día

Tabla **derivada**, no extraída. El ETL explota cada estadía confirmada en sus noches y agrega por hotel y día.

| Columna | Descripción |
|---|---|
| `TiempoKey`, `HotelKey` | Claves. Índice único sobre el par: impide duplicados. |
| `HabitacionesOcupadas` | **Numerador** del KPI de ocupación. |
| `HabitacionesDisponibles` | **Denominador**: suma de `CantidadDisponible` de los tipos activos del hotel. |
| `PersonasAlojadas`, `IngresoDia`, `ReservasActivas` | Medidas de apoyo. |

**Por qué no se almacena el porcentaje.** Un porcentaje no es aditivo. Si cada fila guardara `PctOcupacion` y el reporte lo promediara para obtener el mes, el resultado sería incorrecto: un día con 3 habitaciones disponibles pesaría igual que uno con 300. Guardando numerador y denominador, `DIVIDE(SUM(ocupadas), SUM(disponibles))` da el valor correcto en cualquier nivel de agregación.

**Sólo cuentan las reservas `CONFIRMADA`.** Una reserva pendiente o cancelada no ocupa una habitación.

**La noche de salida no se cuenta.** Una estadía del 1 al 5 ocupa las noches del 1, 2, 3 y 4. Es el criterio hotelero estándar.

### `dw.FactResena` — grano: 1 reseña (MongoDB, RF-12)

| Columna | Descripción |
|---|---|
| `ResenaId` | `ObjectId` de MongoDB como texto. Índice único. |
| `TipoEntidad` | `HOTEL` / `TOUR` / `PAQUETE`. |
| `HotelKey`, `TourKey`, `PaqueteKey` | Sólo una está resuelta; las otras dos quedan en `-1`. Por eso sus relaciones en el modelo son **inactivas**. |
| `Calificacion` | 1–5. Fuera de rango → rechazada a `etl.Error`. |
| `EsPositiva` / `EsNegativa` | ≥ 4 / ≤ 2. Base del índice de satisfacción. |
| `EsVerificada` | La reseña proviene de una reserva comprobada. |
| `LongitudTexto` | Insumo para el tema de investigación (clasificación de reseñas con ML). |

### `dw.FactInteraccionWeb` — grano: 1 evento (MongoDB, RF-13)

| Columna | Descripción |
|---|---|
| `InteraccionId` | `ObjectId`. Índice único. |
| `ClienteKey` | `-1` en sesiones anónimas (~35 % del tráfico). |
| `TipoEvento` | `busqueda`, `vista_hotel`, `vista_tour`, `vista_paquete`, `agregar_carrito`, `abandono_carrito`, `inicio_reserva`, `reserva_completada`. |
| `EsConversion` | Verdadero sólo en `reserva_completada`. |
| `DuracionSegundos` | |

---

## Esquema `etl` — control y trazabilidad (RNF-05)

| Tabla | Grano | Para qué |
|---|---|---|
| `etl.Ejecucion` | una corrida | Modo, estado, tiempos, nodo, usuario, totales. |
| `etl.Etapa` | una etapa de una corrida | Duración y filas por etapa. Insumo de rendimiento para el Integrante 4. |
| `etl.Error` | un registro rechazado | Fuente, archivo, número de registro, campo, regla, severidad y **payload original completo**. |

### Reglas de validación implementadas (RF-15)

| Regla | Aplica a | Severidad |
|---|---|---|
| `no_nulo` | `cliente.identificacion`, `preferencias.identificacion` | Rechazo |
| `formato_email` | `cliente.correo` | Advertencia |
| `duplicado` | `cliente.identificacion` | Advertencia |
| `numerico_positivo` | `reserva.monto_total`, `preferencias.presupuesto`, `paquetes.precio_total` | Rechazo |
| `rango_fechas` | `reserva.fecha_fin ≥ fecha_inicio` | Rechazo |
| `valor_permitido` | `reserva.estado` | Advertencia (se asigna `DESCONOCIDO`) |
| `rango_1_5` | `resenas.calificacion` | Rechazo |

> **Rechazo** = la fila no entra al modelo estrella. **Advertencia** = entra, pero queda registrada. La distinción importa: un correo mal escrito no invalida una reserva de USD 3 000.

---

## Cómo volver de un hecho a su origen

```sql
-- Del hecho al registro original en PostgreSQL
SELECT f.ReservaId, f.MontoTotal, e.FechaInicio AS CargadoEn, e.Servidor
FROM dw.FactReserva f
JOIN etl.Ejecucion e ON e.EjecucionId = f.EjecucionIdCarga
WHERE f.ReservaKey = 12345;
-- -> luego, en PostgreSQL:  SELECT * FROM reserva WHERE reserva_id = <ReservaId>;

-- De un registro rechazado a su dato original
SELECT Fuente, ArchivoOrigen, NumeroRegistro, Campo, ReglaValidacion,
       Descripcion, DatosOriginales
FROM etl.Error
WHERE EjecucionId = (SELECT MAX(EjecucionId) FROM etl.Ejecucion)
  AND Severidad = 'RECHAZO';
```

---

## Cobertura de los requerimientos funcionales

| RF | Dónde queda cubierto |
|---|---|
| RF-01 Gestión de clientes | `DimCliente` |
| RF-02 Gestión de hoteles | `DimHotel` |
| RF-03 Gestión de habitaciones | `DimTipoHabitacion` |
| RF-04 Gestión de tours | `DimTour` |
| RF-05 Paquetes turísticos | `DimPaquete` |
| RF-06 Registro de reservas | `FactReserva` |
| RF-07 Validación de disponibilidad | `FactOcupacionDiaria` (analítica de sobreventa) |
| RF-08 Modificación y cancelación | `DimEstadoReserva` + `EsCancelada` |
| RF-09 Preferencias del visitante | `DimCliente` (atributos aplanados) |
| RF-10 Importación JSON | `stg.PreferenciaArchivo` → enriquece `DimCliente` |
| RF-11 Importación XML | `stg.PaqueteArchivo` → enriquece `DimPaquete` |
| RF-12 Reseñas y calificaciones | `FactResena` |
| RF-13 Interacciones web | `FactInteraccionWeb` |
| RF-14 Ejecución del ETL | `run_etl.py` + `etl.Ejecucion` |
| RF-15 Limpieza y validación | `etl.usp_ValidarStaging` → `etl.Error` |
| RNF-05 Trazabilidad | `EjecucionIdCarga` + claves de negocio + `etl.Error` |
