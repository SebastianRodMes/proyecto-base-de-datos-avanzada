# Desarrollo integral del proyecto TurismoDW

**ITI-821 · Bases de Datos Avanzadas · Escenario 8: Turismo Inteligente**
**Documento de síntesis — desarrollo, hitos, funcionamiento de la migración y justificación del stack**

> Este documento reúne en un solo lugar **qué se construyó, en qué orden, cómo funciona y por qué se decidió cada pieza**. Es el mapa de lectura del proyecto: no reemplaza a los documentos `01`–`15`, los enlaza y los pone en contexto. Si un dato de aquí contradice a un documento específico, manda el específico (por ejemplo `10-validacion-post-migracion.md` para cifras de migración y `15-pendientes-y-operacion-cloud.md` para el estado vivo de pendientes).

---

## 1. Panorama: qué es TurismoDW y qué problema resuelve

El escenario plantea una empresa de **Turismo Inteligente** cuyos datos viven dispersos en cuatro tipos de fuente distintos y cuyas consultas históricas compiten con la operación transaccional. La solución construye un **almacén analítico** (modelo estrella) alimentado por un ETL multifuente y consumido por un dashboard de Power BI, y luego **lleva toda esa solución a la nube**.

| Capa | Tecnología | Rol |
|---|---|---|
| Origen relacional | PostgreSQL 16 | Base operacional `turismo` (reservas, clientes, hoteles, tours) |
| Origen NoSQL | MongoDB 7 | `turismo_nosql`: reseñas e interacciones web |
| Origen de archivos | JSON + XML | Preferencias de visitante (JSON) y catálogo de paquetes (XML) |
| Integración | Python 3.11 + `bcp` | ETL que extrae, valida, transforma y carga |
| Almacén analítico | SQL Server 2022 | `TurismoDW`: modelo estrella particionado |
| Visualización | Power BI Desktop | 6 páginas, 52 medidas DAX |
| Nube | AWS + MongoDB Atlas | Destino de la migración (semanas 3 y 4) |

El valor del proyecto no está en un componente aislado sino en que **integra cuatro clases de fuente en un único modelo dimensional coherente**, con trazabilidad de cada fila hasta su origen y con la solución completa reproducible de punta a punta.

---

## 2. El cambio de eje: de alta disponibilidad a migración cloud

El proyecto tiene dos fases con objetivos distintos, y entender el cambio de eje evita confusiones al leer el repositorio:

| | Semanas 1 y 2 | Semanas 3 y 4 |
|---|---|---|
| **Eje** | Alta disponibilidad on-premise | Integración, migración y operación cloud |
| **Foco técnico** | Mirroring, Always On, failover, endpoint lógico `localhost,14330` | Estrategia de migración, ETL incremental, operación sobre AWS |
| **Redundancia** | Algo que **se construye** (réplicas, failover manual) | Algo que **se contrata** (servicio gestionado) |
| **Evidencia** | Se conserva; scripts `48`–`51` intactos | Scripts `70`–`81`, variantes RDS del DDL |

El trabajo de alta disponibilidad **no se descarta**: queda como evidencia de las semanas anteriores. Lo que cambia es hacia dónde apunta el proyecto. En un servicio gestionado como RDS, la redundancia deja de ser un grupo de disponibilidad que uno administra y pasa a ser una propiedad del servicio (Single-AZ / Multi-AZ). La justificación completa está en `07-estrategia-migracion.md`, sección 6.

---

## 3. Arquitectura de la solución

### 3.1 Flujo de datos de punta a punta

```text
  ORÍGENES                    ETL (Python + bcp)           ALMACÉN            CONSUMO
  ────────                    ──────────────────           ───────            ───────
  PostgreSQL 16 ─psycopg2─┐
  MongoDB 7 ────pymongo───┤─► extract ─► *.dat ─bcp─► stg.* ─T-SQL─► dw.*  ─► Power BI
  JSON ─────────json──────┤   (Python)          (motor)        (MERGE +      (16 vistas
  XML ──────────lxml──────┘                                     recarga)      dw.vw_*)
                                                                  │
                                              bitácora ► etl.Ejecucion / etl.Etapa / etl.Error
```

El patrón central es **E → archivo plano → `bcp` → staging → `MERGE`/recarga → estrella**. El archivo intermedio parece un rodeo, pero es lo que habilita la **carga masiva** del motor: cargar 2 millones de filas por la ruta `bcp` toma menos de un minuto, mientras que un `INSERT` fila a fila por ODBC tomaría más de una hora. Python solo mueve bytes; las transformaciones (`MERGE`, agregaciones) corren dentro del motor, donde están los datos y los índices.

### 3.2 Modelo estrella

`TurismoDW` contiene 8 dimensiones y 6 tablas de hechos, con particionamiento anual y filegroups por propósito (`FG_DIM`, `FG_FACT`, `FG_STG`, `FG_IDX`). Los detalles de cada columna están en `02-diccionario-modelo-estrella.md`. Cifras de referencia del volumen cargado:

| Tabla | Filas |
|---|---:|
| `FactReserva` | ~2,000,010 |
| `FactReservaHabitacion` | 1,632,453 |
| `FactReservaTour` | 2,577,212 |
| `FactOcupacionDiaria` | ~431,325 |
| `FactResena` | 500,002 |
| `FactInteraccionWeb` | 1,500,002 |

---

## 4. Cómo funciona el ETL

### 4.1 Etapas

El orquestador `05-etl/run_etl.py` ejecuta seis grupos de etapas, todas registradas en la bitácora `etl.*`:

| # | Etapa | Qué hace |
|---|---|---|
| 1 | `EXTRAER_PG` / `EXTRAER_MONGO` / `EXTRAER_ARCHIVOS` | Lee las cuatro fuentes y emite archivos `.dat` delimitados |
| 2 | `TRUNCAR_STG` / `CARGAR_STG` | `bcp` carga cada `.dat` en `stg.*` (todo `nvarchar`, sin restricciones) |
| 3 | `VALIDAR` | Reglas de calidad: obligatorios, formatos, duplicados, rangos → rechazos a `etl.Error` |
| 4 | `CARGAR_DW_DIM` / `CARGAR_DW_HECHOS` | `MERGE` SCD-1 sobre dimensiones; recarga de hechos por clave de negocio |
| 5 | `CARGAR_DW_OCUPACION` | Explota estadías en días → `FactOcupacionDiaria` |
| 6 | `VERIFICAR_INTEGRIDAD` | Revalida claves foráneas `WITH CHECK` y actualiza estadísticas |

### 4.2 Decisiones de diseño clave

- **Staging con todo `nvarchar` y sin restricciones.** Una fila mal formada no aborta el lote entero de `bcp`; la conversión real ocurre después con `TRY_CONVERT` dentro del motor, y lo no convertible se registra en `etl.Error` con el dato original intacto.
- **Dimensiones con `MERGE`, hechos con recarga.** Las dimensiones son pequeñas y cambian poco (SCD-1 barato que preserva claves subrogadas); los hechos son millones de filas, donde comparar fila a fila costaría más que reescribir, y la recarga elimina el riesgo de hechos huérfanos.
- **`FactOcupacionDiaria` precalculada.** El KPI de ocupación exige explotar cada reserva en días. Hacerlo en DAX sobre 2 millones de filas colapsaría el reporte; hacerlo una vez en el ETL cuesta segundos. Guarda numerador y denominador por separado, nunca el porcentaje (un porcentaje almacenado no se promedia correctamente al agregar).
- **Registros inválidos inyectados a propósito.** Los generadores emiten ~2 % de registros defectuosos. Son la **evidencia** de que la validación funciona, no un descuido: producen los **84 rechazos esperados** (44 `no_nulo` + 38 `numerico_positivo` en preferencias, 2 `numerico_positivo` en paquetes).

### 4.3 Carga incremental

El ETL admite `--modo FULL` (recarga completa) y `--modo INCREMENTAL` (solo lo que cambió). Las marcas de agua viven en `etl.Marca` y **solo avanzan si la corrida termina bien**: un fallo deja la marca donde estaba para que el siguiente intento reprocese el mismo lote. Como la carga de hechos borra por clave de negocio antes de insertar, reprocesar es inofensivo.

| Modo | Filas de staging | Duración |
|---|---:|---:|
| `FULL` | 8,317,880 | ~8 min |
| `INCREMENTAL` | 2,050 | ~22 s |

> **Por qué Python + `bcp` y no SSIS, Pentaho o Azure Data Factory.** Ver `01-arquitectura-etl.md`, sección 4: Python es el único conector que cubre las cuatro fuentes con una sola pila, ya está instalado, es versionable en texto (un paquete SSIS o un job de Pentaho son binarios que nadie revisa en un diff), y `bcp` usa la ruta de carga masiva del motor. Azure Data Factory quedó descartado por ser un servicio en la nube cuando el enunciado pedía una solución on-premise.

---

## 5. Cómo funciona la migración a la nube

### 5.1 Estrategia: rehost híbrido

De las cinco estrategias clásicas se eligió **rehost** (*lift and shift* sobre servicios gestionados): mismos motores, mismo esquema, mismas consultas.

- **Por qué rehost y no replatform.** El valor está en el modelo estrella, los procedimientos `etl.usp_*`, las vistas `dw.vw_*` y las 52 medidas DAX. Un replatform a Redshift obligaría a reescribir el `MERGE`, las funciones de partición y las medidas que dependen de propiedades de SQL Server. Sería un proyecto nuevo, no una migración, y no cabe en dos semanas. Rehost conserva el T-SQL íntegro y permite comparar local contra nube sobre una base honesta.
- **Híbrida por diseño.** Los archivos JSON y XML no se convierten en tablas: van a **S3 como landing zone cruda**. Son la fuente de la que el ETL extrae; volverlos tablas destruiría la evidencia de que la solución integra cuatro tipos de fuente.

### 5.2 Correspondencia origen → destino

| Componente | Origen on-premise | Destino en la nube | Herramienta |
|---|---|---|---|
| Base operacional | PostgreSQL 16 (Docker) | RDS for PostgreSQL 16, `db.t4g.micro` | `pg_dump -Fc` + `pg_restore` |
| Base NoSQL | MongoDB 7 (Docker) | MongoDB Atlas M0 | `mongodump` + `mongorestore` |
| Archivos | `03-archivos/entrada/` | S3, landing zone | `aws s3 sync` |
| Almacén analítico | SQL Server 2022 Developer | RDS for SQL Server 2022 Express, `db.t3.small` | DDL portable + `bcp` |

### 5.3 Secuencia de la migración

La migración está guionizada en 12 pasos reversibles (`07-migracion/70`–`81`):

1. **Provisión** (`70`): red, S3, IAM y las dos instancias RDS.
2. **Inventario** (`71`): objetos a migrar leídos de los catálogos vivos.
3. **Piloto 10 %** (`72`): prueba las herramientas contra el destino real antes de comprometerse.
4. **Migración** (`73`–`75`): PostgreSQL, MongoDB, archivos a S3, y el DW.
5. **Repunte** (`repuntar-powerbi.ps1`, `.env.aws`): Power BI y el ETL apuntan a la nube.
6. **Validación** (`76`, `77`): conteos, sumas, checksums y comparación local vs nube.
7. **Apagado** (`78`): detiene los recursos para que el costo no siga corriendo.

### 5.4 Para qué sirve realmente el piloto

El propósito del piloto **no es mover datos, es probar las herramientas** contra el destino real. Responde tres preguntas que la documentación no puede contestar:

1. **¿Acepta RDS los filegroups por propósito?** — **Sí.** Es el hallazgo más valioso del proyecto: se reprodujeron los 12 filegroups de usuario (4 por propósito + 8 anuales) y los scripts `41`–`45` y `47b` corrieron **sin una sola modificación**. La creencia de que un SQL Server gestionado obliga a `PRIMARY` viene de **Azure SQL Database**, no de RDS.
2. **¿Sirve el restore nativo desde S3?** — Se prueba como ruta alterna. Recrea archivos por tamaño *asignado* (11.9 GB) y excede el tope de 10 GB de Express, así que la ruta primaria es DDL portable + `bcp`.
3. **¿Aguanta el `bcp` de ODBC 17 el TLS obligatorio de RDS?** — Sí, con las banderas correctas.

El subconjunto es **determinista** (`reserva_id % 10 = 0` más su cierre referencial), no aleatorio, para que dos corridas del piloto sean comparables.

### 5.5 Reversibilidad total

**El punto de no retorno no existe en este proyecto.** Ningún script de `07-migracion/` escribe en las bases de origen: todos leen del origen y escriben en el destino. Mientras el entorno Docker siga en pie y el repositorio conserve los scripts originales, cualquier estado de la migración se puede abandonar sin pérdida. Por eso `07-migracion/sql/` contiene **variantes** de los scripts, no reemplazos.

---

## 6. Justificación del stack

### 6.1 Por qué AWS como proveedor de nube

La elección de AWS no fue por defecto; se apoya en razones concretas que otros proveedores no cubrían igual de bien:

| Razón | Detalle |
|---|---|
| **Rehost de SQL Server sin degradar el esquema** | RDS for SQL Server **administra filegroups de usuario**; Azure SQL Database restringe a `PRIMARY`. Como el DW depende de 12 filegroups y partición física, RDS permite un rehost literal que Azure SQL DB habría obligado a degradar. Este punto se **verificó en ejecución**, no se supuso. |
| **Los dos motores como servicio gestionado en un mismo lugar** | RDS ofrece PostgreSQL **y** SQL Server gestionados bajo la misma consola, IAM y red. No hay que mezclar proveedores para los dos orígenes relacionales del proyecto. |
| **Costo casi nulo con capas mínimas** | `db.t4g.micro` ($0.016/h), `db.t3.small` ($0.036/h), S3 (<$0.0001) y **MongoDB Atlas M0 gratuito**. Total estimado: **menos de 5 USD** por tres días, y en reposo solo almacenamiento (~0.15 USD/día). |
| **Atlas M0 corre sobre AWS** | El nivel gratuito de MongoDB Atlas se aloja en AWS `us-east-1`. Mantener todo en un mismo proveedor y región reduce latencia y evita egreso entre nubes. |
| **Herramientas ya disponibles y autenticadas** | AWS CLI ya estaba instalado y autenticado en la máquina (criterio de "disponibilidad inmediata"). **Azure CLI no estaba instalado**, lo que confirma que Azure no era una opción realista sin costo de aprendizaje adicional. |
| **S3 como landing zone natural** | El diseño híbrido necesita un almacén de objetos crudos para JSON/XML; S3 es el estándar y se integra con RDS vía option group `SQLSERVER_BACKUP_RESTORE`. |

> En síntesis: AWS ganó porque permitía **un rehost literal de los dos motores** (con SQL Server conservando filegroups), a **costo casi nulo**, con **Atlas gratuito en la misma nube** y con **herramientas ya disponibles**. Azure perdía en el punto decisivo (Azure SQL Database y sus filegroups) y en disponibilidad inmediata.

### 6.2 Por qué cada herramienta de migración

Las herramientas se juzgaron contra cinco criterios en orden: **reproducibilidad > fidelidad > costo > disponibilidad inmediata > trazabilidad del error**. La reproducibilidad manda sobre la comodidad: un asistente gráfico de SSMS habría movido el DW en veinte minutos de clics, pero no dejaría nada que otro pueda volver a ejecutar.

| Componente | Elegida | Por qué / qué se descartó |
|---|---|---|
| PostgreSQL | `pg_dump -Fc` + `pg_restore` | Formato *custom* comprimido, restauración paralelizable, y **conserva el índice GIN sobre `JSONB`**, el objeto más delicado del origen. Se descartó **AWS DMS** (sin permisos IAM, duplica costo con instancia de replicación, y el CDC no aporta sobre un laboratorio congelado). |
| MongoDB | `mongodump` + `mongorestore` | BSON conserva tipos nativos y permite `--query` para migrar subconjuntos, justo lo que exigió el tope de M0. Atlas Live Migration no existe en M0; `mongoexport` pierde precisión en fechas/enteros de 64 bits. |
| SQL Server | DDL portable + `bcp` | Determinista, controlable tabla por tabla, reutiliza el `bcp` del ETL y **permite adaptar el esquema durante la migración** (los filegroups). El `.bak` vía S3 se prueba como alternativa pero arrastra la estructura física del origen. |
| JSON/XML | `aws s3 sync` | Idempotente, verifica por tamaño y fecha, no re-sube lo que no cambió. |
| Orquestación | PowerShell + AWS CLI | Es el lenguaje que ya usa todo el repositorio; sin dependencias nuevas. CloudFormation/Terraform no se pagan para seis recursos que viven tres días. |

El detalle completo está en `08-matriz-herramientas.md`.

### 6.3 Por qué Express y no Standard

El DW real pesa ~2.3 GB en destino (los 1.4 GB de staging no migran), muy por debajo del tope de 10 GB por base de Express. Standard cuesta ~$0.44/h con licencia: veinticuatro veces más para una capacidad que no se necesita. La postura fue **empezar por Express y escalar solo si el piloto choca con un límite real**. Ocurrió, pero por la **memoria de la clase** (`db.t3.micro` no servía la carga masiva), no por la edición: se escaló a `db.t3.small`. Express siguió siendo la edición correcta.

---

## 7. Hitos del proyecto

| Hito | Responsable | Estado |
|---|---|---|
| Modelo estrella y carga multifuente | Integrante 1 | Completo |
| Filegroups, particiones e índices | Integrante 2 | Completo |
| Alta disponibilidad y recuperación (Always On Docker) | Integrante 3 | Completo |
| Rendimiento, consistencia y documentación | Integrante 4 | Completo |
| Estrategia y matriz de herramientas de migración | Integrante 1 | Completo |
| Inventario de objetos a migrar | Integrante 1 | Completo |
| Migración piloto y completa a AWS | Integrante 1 | Completo |
| Carga incremental, bitácora y prueba de recuperación de ETL | Integrante 1 | Completo |
| ETL apuntando a la nube (cuatro fuentes) | Integrantes 1 y 2 | Completo |
| Power BI apuntando a la nube (refresco real contra RDS) | Integrante 1 | Completo |
| Dashboard, 52 métricas de negocio y validación local vs nube | Integrante 3 | Completo |
| Manual de usuario del dashboard | Integrante 3 | Completo |
| Tema de investigación (ML) y prototipo | Integrante 4 | Completo |
| Presentación ejecutiva final | Equipo | Completo |
| Video de demostración | Equipo | Pendiente (último real) |

El estado vivo de pendientes se lleva en `15-pendientes-y-operacion-cloud.md`.

---

## 8. Resultado de la migración

| Componente | Destino | Resultado |
|---|---|---|
| PostgreSQL | RDS for PostgreSQL 16 | 11/11 tablas exactas, suma al céntimo, índice GIN sobre `JSONB` intacto |
| Almacén analítico | RDS for SQL Server 2022 Express | **8,699,504 filas**, 14/14 controles, **checksums idénticos** |
| Claves foráneas | | 32/32 validadas y confiables |
| Particionamiento | | Distribución idéntica, los 12 filegroups reproducidos |
| Archivos JSON/XML | S3 | 5/5 byte a byte |
| MongoDB | Atlas M0 | `resenas` completa; `interacciones_web` al 50 % determinista (cupo de M0) |
| ETL apuntando a la nube | | 25 etapas contra PostgreSQL, Atlas y archivos; 1,258,074 filas leídas, 84 rechazos esperados |
| Power BI | | 16 particiones repuntadas, 16 vistas responden en la nube |

Los seis incidentes encontrados durante la ejecución (y cómo se resolvieron) están en `10-validacion-post-migracion.md`.

---

## 9. Tema de investigación: Machine Learning

De los nueve temas ofrecidos (CDC, Kafka, Data Lake, Docker, Data Vault, GeoJSON, series temporales, ML, observabilidad) se eligió **Machine Learning**: clasificación de sentimiento de reseñas (negativa / neutral / positiva) con **TF-IDF + Regresión Logística** sobre las 500,002 reseñas de Atlas. El modelo de datos ya lo anticipaba: `dw.FactResena.LongitudTexto` está documentada como insumo para clasificación con ML desde la Semana 1. El prototipo, las métricas y la presentación están en `08-investigacion-ml/`.

---

## 10. Operación y costos

- **Encender la nube:** `07-migracion/78-detener-recursos.ps1 -Iniciar -Esperar` (tarda unos minutos). Luego reabrir el security group para la IP actual y agregar la IP en Atlas Network Access.
- **Apagar la nube:** `07-migracion/78-detener-recursos.ps1` al cerrar cada sesión. Detenidas solo se paga almacenamiento (~0.15 USD/día).
- **Aviso:** AWS **reinicia sola** una instancia detenida a los **7 días**. Si el proyecto se deja parado más tiempo, conviene eliminar con `-Eliminar`.
- **Puertos locales:** el override de Docker publica PostgreSQL en `15432` y MongoDB en `27018` para no chocar con servicios nativos de Windows que, sobre IPv4, capturarían silenciosamente las conexiones a `127.0.0.1`.

La guía operativa completa (credenciales, reactivación, trampas al repetir) está en `11-traspaso-cloud.md`.

---

## 11. Mapa de documentos

| Documento | Qué contesta |
|---|---|
| `01-arquitectura-etl.md` | Arquitectura del ETL y justificación de Python + `bcp` |
| `02-diccionario-modelo-estrella.md` | Semántica de cada columna del modelo |
| `07-estrategia-migracion.md` | Por qué AWS y rehost, riesgos y plan de reversión |
| `08-matriz-herramientas.md` | Herramientas evaluadas y justificación de cada elección |
| `09-inventario-migracion.md` | Inventario de objetos con veredicto de portabilidad |
| `10-validacion-post-migracion.md` | Resultados, incidentes y comparación local vs nube |
| `11-traspaso-cloud.md` | Cómo retomar el trabajo: credenciales, reactivación, pendientes |
| `12-etl-integrante2-semanas3-4.md` | Calidad antes/después e incremental cloud (Integrante 2) |
| `13-dashboard-metricas-integrante3.md` | Dashboard, 52 métricas y paridad DAX vs SQL (Integrante 3) |
| `14-manual-usuario-dashboard.md` | Manual de usuario del dashboard |
| `15-pendientes-y-operacion-cloud.md` | Estado vivo de pendientes y operación cloud |
| **`16-desarrollo-integral-proyecto.md`** | **Este documento: síntesis de todo el desarrollo** |
