# Inventario de objetos a migrar

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Inventario completo de los objetos de los tres motores de origen, con el veredicto de portabilidad de cada uno hacia AWS. Generado por `07-migracion/71-inventario-objetos.ps1` **consultando los catálogos vivos**, no transcribiendo los scripts DDL.

> **Por qué se lee del catálogo y no del código fuente.** Un inventario transcrito de los scripts describe lo que se pensó crear; para decidir qué migra y qué no, solo sirve lo que realmente existe. La diferencia no es teórica: los scripts declaran 26 claves foráneas en `dw` y el catálogo reporta 31 en total, porque `etl` aporta 2 más y `DimTipoHabitacion` una que no está en el bloque principal. Ese tipo de desfase es exactamente lo que rompe una migración a mitad de camino.

Evidencia cruda:

- `00-docs/05-evidencias/migracion/inventario-sqlserver.txt`
- `00-docs/05-evidencias/migracion/inventario-postgresql.txt`
- `00-docs/05-evidencias/migracion/inventario-mongodb.txt`

---

## 1. Leyenda de veredictos

| Veredicto | Significado |
|---|---|
| **Migra tal cual** | El objeto se recrea idéntico en el destino, sin cambios |
| **Requiere adaptación** | El objeto migra, pero su definición cambia para ser válida en el servicio gestionado |
| **Migra vacío** | La estructura se crea en el destino, pero los datos no se copian |
| **No migra** | El objeto se queda on-premise, con justificación |

---

## 2. SQL Server — `TurismoDW`

Instancia origen: SQL Server 2022 Developer sobre Linux, compatibilidad 160, `RECOVERY FULL`, RCSI activado.

### 2.1 Resumen contable

| Categoría | Cantidad | Veredicto |
|---|---:|---|
| Tablas `stg` (staging) | 15 | Migra vacío |
| Tablas `dw` (dimensiones) | 8 | Migra tal cual |
| Tablas `dw` (hechos) | 6 | Migra tal cual |
| Tablas `etl` (control) | 4 | Migra vacío |
| Vistas | 17 | 16 tal cual, 1 requiere adaptación |
| Procedimientos almacenados | 10 | Migra tal cual |
| Funciones | 1 | Migra tal cual |
| Índices agrupados | 18 | Requiere adaptación |
| Índices no agrupados | 22 | Requiere adaptación |
| Índices columnstore | 3 | Migra tal cual |
| Claves foráneas | 31 | Migra tal cual |
| Filegroups de usuario | 12 | **Requiere adaptación** |
| Archivos de datos | 14 | **No migra** |
| Funciones de partición | 1 | Migra tal cual |

> El conteo excluye las tablas internas de Query Store. Sin ese filtro el catálogo reporta 122 índices agrupados y 100 no agrupados que nadie escribió y que no se migran.

### 2.2 Tablas y volumen real

| Esquema | Tabla | Columnas | Filas | Part. | Espacio | Veredicto |
|---|---|---:|---:|---:|---:|---|
| `dw` | `FactReserva` | 17 | 2 000 005 | 8 | 375 MB | Migra tal cual |
| `dw` | `FactReservaTour` | 13 | 2 577 212 | 8 | 293 MB | Migra tal cual |
| `dw` | `FactReservaHabitacion` | 16 | 1 632 453 | 8 | 199 MB | Migra tal cual |
| `dw` | `FactInteraccionWeb` | 14 | 1 500 000 | 1 | 321 MB | Migra tal cual |
| `dw` | `FactResena` | 17 | 500 000 | 1 | 115 MB | Migra tal cual |
| `dw` | `FactOcupacionDiaria` | 10 | 431 313 | 8 | 42 MB | Migra tal cual |
| `dw` | `DimCliente` | 26 | 50 006 | 1 | 23 MB | Migra tal cual |
| `dw` | `DimTiempo` | 18 | 2 923 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimTipoHabitacion` | 12 | 792 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimTour` | 13 | 401 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimHotel` | 14 | 201 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimPaquete` | 13 | 151 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimCanal` | 4 | 16 | 1 | < 1 MB | Migra tal cual |
| `dw` | `DimEstadoReserva` | 6 | 4 | 1 | < 1 MB | Migra tal cual |
| `etl` | `Numeros` | 1 | 4 000 | 1 | < 1 MB | Migra tal cual |
| `etl` | `Error` | 13 | 84 | 1 | < 1 MB | Migra vacío |
| `etl` | `Etapa` | 12 | 24 | 1 | < 1 MB | Migra vacío |
| `etl` | `Ejecucion` | 12 | 1 | 1 | < 1 MB | Migra vacío |
| `stg` | `Reserva` | 12 | 2 000 005 | 1 | 740 MB | Migra vacío |
| `stg` | `ReservaTour` | 6 | 2 577 212 | 1 | 387 MB | Migra vacío |
| `stg` | `InteraccionWeb` | 14 | 1 500 000 | 1 | 408 MB | Migra vacío |
| `stg` | `ReservaHabitacion` | 6 | 1 632 453 | 1 | 256 MB | Migra vacío |
| `stg` | `Resena` | 13 | 500 000 | 1 | 191 MB | Migra vacío |
| `stg` | *(otras 10 tablas)* | — | 108 055 | 1 | 41 MB | Migra vacío |

> **Staging migra vacío, y eso ahorra el 42 % del volumen.** Las 15 tablas de `stg` ocupan **1 447 MB de los 3 409 MB usados**. Son datos de trabajo transitorios: el ETL las trunca al inicio de cada corrida (`load_sqlserver.py:63`). Copiarlas sería mover casi la mitad del peso de la migración para tener basura que la primera corrida del ETL borra. Las estructuras sí se crean, porque el ETL las necesita; los datos no.
>
> `etl.Ejecucion`, `Etapa` y `Error` también migran vacías: la bitácora de la nube debe empezar limpia para que las corridas cloud sean distinguibles de las locales. `etl.Numeros` sí migra con datos porque es una tabla auxiliar fija de 4 000 filas que `usp_CargarOcupacionDiaria` usa para explotar estadías.

### 2.3 Filegroups y archivos — el punto crítico

| Filegroup | Archivos | Asignado | Usado | Veredicto |
|---|---:|---:|---:|---|
| `PRIMARY` | 1 | 128 MB | 9 MB | Migra tal cual |
| `FG_DIM` | 1 | 256 MB | 25 MB | Requiere adaptación |
| `FG_FACT` | 2 | 4 096 MB | 278 MB | Requiere adaptación |
| `FG_STG` | 1 | 2 048 MB | 1 447 MB | Requiere adaptación |
| `FG_IDX` | 1 | 1 280 MB | 907 MB | Requiere adaptación |
| `FG_PRE2021` … `FG_2027PLUS` | 8 | 1 024 MB | 614 MB | Requiere adaptación |
| *log* | 1 | 3 072 MB | 1 192 MB | No migra |
| **Total** | **15** | **8 832 MB datos + 3 072 log** | **3 409 MB datos** | |

Las 14 rutas físicas son `/var/opt/mssql/data/*.ndf`. **RDS no permite elegir dónde viven los archivos**, así que ninguna ruta migra. Qué pasa con los filegroups lo decide `40-crear-basedatos.rds.sql` en tiempo de ejecución, y el resultado queda en `dbo.MigracionModo`.

> **Este inventario descalifica una de las dos rutas de migración, con números.** La ruta de restauración nativa desde S3 (`rds_restore_database`) reconstruye los archivos con su **tamaño asignado**, no con el usado: 8 832 MB de datos más 3 072 MB de log son **11,9 GB**, por encima del tope de 10 GB por base de SQL Server Express. La ruta de DDL portable más `bcp` copia solo datos reales y sin staging: alrededor de **2,3 GB**. No es una preferencia de estilo — una ruta cabe en Express y la otra no. Se probarán ambas en el piloto para dejar el rechazo documentado en vez de supuesto.

### 2.4 Vistas

Las 17 vistas migran, 16 sin tocar. La excepción está aislada y ya resuelta:

| Vista | Veredicto | Razón |
|---|---|---|
| `dw.vw_Dim*` (8), `dw.vw_Fact*` (6), `dw.vw_CalidadDatos`, `etl.vw_UltimaEjecucion` | Migra tal cual | Solo leen tablas del propio esquema |
| **`dw.vw_EstadoSistema`** | **Requiere adaptación** | Lee `sys.database_mirroring`, `sys.availability_replicas`, `sys.dm_hadr_*` y `sys.dm_os_sys_info`. En RDS no hay mirroring ni AG propio, y `dm_os_sys_info` exige `VIEW SERVER STATE` |

`07-migracion/sql/45b-vistas-estado-rds.sql` la reemplaza conservando **las 21 columnas con nombre y tipo idénticos**, que es lo que exige `EstadoSistema.tmdl` del modelo de Power BI. La hora de arranque de la instancia pasa a obtenerse de `create_date` de `tempdb`, que SQL Server recrea en cada arranque: mismo dato, sin permisos elevados.

### 2.5 Procedimientos, funciones e índices

| Objeto | Cantidad | Veredicto |
|---|---:|---|
| `etl.usp_IniciarEjecucion`, `usp_IniciarEtapa`, `usp_FinalizarEtapa`, `usp_FinalizarEjecucion`, `usp_RegistrarError` | 5 | Migra tal cual |
| `etl.usp_ValidarStaging`, `usp_CargarDimensiones`, `usp_CargarHechos`, `usp_CargarOcupacionDiaria`, `usp_VerificarIntegridad` | 5 | Migra tal cual |
| `etl.fn_TiempoKey` | 1 | Migra tal cual |
| `NCCI_FactReserva`, `NCCI_FactReservaTour`, `NCCI_FactOcupacionDiaria` | 3 | Migra tal cual |
| `UQ_*_Negocio` (no alineados, en `FG_IDX`) | 6 | Requiere adaptación |
| `PK_*` de las 4 tablas particionadas | 4 | Requiere adaptación |

> Los columnstore **no** son un problema: están disponibles en todas las ediciones desde SQL Server 2016 SP1, Express incluida. Los índices marcados como *requiere adaptación* lo están solo por su cláusula de ubicación (`ON FG_IDX`, `ON ps_TurismoAnio`), no por su definición.

### 2.6 Particionamiento

| Objeto | Definición | Veredicto |
|---|---|---|
| `pf_TurismoAnio` | `RANGE RIGHT`, 7 límites, 8 particiones | Migra tal cual |
| `ps_TurismoAnio` | Mapeado a 8 filegroups anuales | **Requiere adaptación** |

Distribución medida de `dw.FactReserva`, que debe reproducirse idéntica en el destino:

| Partición | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Filas | 0 | 333 424 | 334 078 | 333 542 | 334 499 | 331 702 | 332 760 | 0 |

> **La partición lógica no se pierde nunca.** Si el destino queda en modo `PRIMARY`, el esquema se crea con `ALL TO ([PRIMARY])`: la función, los límites, la eliminación de particiones en las consultas y la alineación de los columnstore siguen funcionando igual. Lo único que desaparece es la separación **física** en archivos distintos, que en RDS no aportaba nada porque todo vive sobre un único volumen EBS gestionado por AWS.

---

## 3. PostgreSQL — `turismo`

Origen: PostgreSQL 16.15, 768 MB, sin extensiones más allá de `plpgsql`.

| Categoría | Cantidad | Veredicto |
|---|---:|---|
| Tablas | 13 | Migra tal cual |
| Índices | 20 | Migra tal cual |
| Secuencias | 13 | Migra tal cual |
| Claves foráneas | 13 | Migra tal cual |
| Vistas | 0 | — |
| Funciones y procedimientos | 0 | — |
| Extensiones | 1 (`plpgsql`) | Integrada en el motor |

Tablas por peso:

| Tabla | Filas | Tamaño |
|---|---:|---:|
| `reserva` | 2 000 005 | 283 MB |
| `reserva_tour` | 2 577 212 | 274 MB |
| `reserva_habitacion` | 1 632 453 | 176 MB |
| `cliente` | 50 005 | 13 MB |
| `preferencia_cliente` | 50 005 | 12 MB |
| *(otras 8 tablas)* | 1 723 | < 1 MB |

**Todo PostgreSQL migra sin adaptación.** Es el componente más limpio de los tres: no hay vistas, ni funciones, ni procedimientos, ni extensiones de terceros, ni tipos exóticos.

> **El único objeto delicado es un índice.** `preferencia_cliente.datos_adicionales` es una columna `JSONB` con un índice **GIN** encima. Es lo que más fácilmente se pierde en una migración descuidada, porque muchas herramientas copian filas y no índices. `pg_restore` lo recrea desde el volcado, y `73-migrar-postgres.ps1` lo verifica explícitamente contra `pg_indexes` después de restaurar en vez de darlo por hecho.

---

## 4. MongoDB — `turismo_nosql`

| Colección | Documentos | Datos | Índices | Total | Veredicto |
|---|---:|---:|---:|---:|---|
| `interacciones_web` | 1 500 000 | 396 MB | 49 MB | 445 MB | Migra tal cual |
| `resenas` | 500 000 | 162 MB | 17 MB | 178 MB | Migra tal cual |
| **Total lógico** | **2 000 000** | **557 MB** | **66 MB** | **623 MB** | |
| **Total en disco (comprimido)** | | **139 MB** | 66 MB | **205 MB** | |

Índices, 8 en total (2 implícitos `_id_` más 6 explícitos), todos migran:

| Colección | Índices |
|---|---|
| `resenas` | `_id_`, `fecha_1`, `cliente_id_1`, `entidad_id_1_tipo_entidad_1` |
| `interacciones_web` | `_id_`, `fecha_evento_1`, `cliente_id_1`, `tipo_evento_1` |

> **El inventario corrigió una decisión de la estrategia.** Al planificar se asumió, a partir del tamaño lógico, que 2 000 000 de documentos no cabrían en los 512 MB de Atlas M0, y se previó migrar `resenas` completa y muestrear `interacciones_web`. La medición real dice otra cosa: WiredTiger comprime con snappy y el almacenamiento efectivo es de **139 MB de datos más 66 MB de índices, unos 205 MB**, holgadamente por debajo del tope.
>
> Se migra entonces **el conjunto completo**, y el muestreo determinista queda como plan de contingencia si Atlas contabilizara el cupo de otra forma. Es la razón por la que el inventario se genera antes de migrar y no después: 557 MB lógicos y 205 MB reales llevan a dos migraciones distintas.

---

## 5. Archivos planos

| Archivo | Tamaño | Registros | Destino | Veredicto |
|---|---:|---:|---|---|
| `preferencias_lote1.json` | 1 007 KB | 2 000 | `s3://…/raw/` | Migra tal cual |
| `preferencias_lote2.json` | 1 007 KB | 2 000 | `s3://…/raw/` | Migra tal cual |
| `preferencias_lote3.json` | 1 006 KB | 2 000 | `s3://…/raw/` | Migra tal cual |
| `paquetes_2025.xml` | 41 KB | 75 | `s3://…/raw/` | Migra tal cual |
| `paquetes_2026.xml` | 41 KB | 75 | `s3://…/raw/` | Migra tal cual |

Van a S3 como *landing zone* cruda, sin transformar. Convertirlos en tablas destruiría la evidencia de que la solución integra cuatro tipos de fuente distintos.

---

## 6. Qué se queda on-premise, y por qué

| Objeto | Razón |
|---|---|
| Los 14 archivos de datos y el log | RDS administra el almacenamiento; las rutas no son elegibles |
| Datos de las 15 tablas `stg` | Transitorios: el ETL las trunca al inicio de cada corrida |
| Historial de `etl.Ejecucion`, `Etapa`, `Error` | La bitácora cloud empieza limpia para poder distinguir corridas locales de corridas en la nube |
| Scripts `48a`–`48d`, `49` (Database Mirroring) | Función deprecada, no soportada en ningún servicio gestionado |
| Scripts `50`, `51` (Always On con `CLUSTER_TYPE=NONE`) | RDS provee redundancia con Multi-AZ; no se administra desde T-SQL |
| Query Store con `MAX_STORAGE_SIZE_MB = 2048` | Se reduce a 256 MB: en Express consume del mismo tope de 10 GB que los datos |

---

## 7. Volumen esperado en el destino

| Componente | Origen | Estimado en destino |
|---|---:|---:|
| RDS SQL Server (`dw` + `etl` + estructura `stg`) | 3 409 MB usados | **~2 300 MB** |
| RDS PostgreSQL | 768 MB | ~768 MB |
| MongoDB Atlas M0 | 205 MB en disco | ~205 MB |
| S3 | 3,0 MB | 3,0 MB |

El DW migrado queda en torno a **2,3 GB frente al tope de 10 GB** de SQL Server Express, con margen suficiente para las corridas incrementales y el Query Store. La decisión de empezar por Express en vez de Standard queda respaldada por la medición y no por la esperanza.

---

## 8. Documentos relacionados

- `00-docs/07-estrategia-migracion.md` — estrategia, arquitectura destino, riesgos y reversión
- `00-docs/08-matriz-herramientas.md` — herramientas evaluadas y justificación
- `00-docs/02-diccionario-modelo-estrella.md` — semántica de cada columna del modelo
- `07-migracion/71-inventario-objetos.ps1` — generador de este inventario
