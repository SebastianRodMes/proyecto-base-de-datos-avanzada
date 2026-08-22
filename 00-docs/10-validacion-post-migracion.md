# Validación post-migración

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 4 · Integrante 1: Alex Herrera**

Resultados de la migración a AWS, incidentes encontrados durante la ejecución y comparación entre el entorno local y el migrado.

---

## 1. Metodología

La migración se juzga por **integridad**, no por velocidad. Tres niveles de verificación, de menos a más estricto:

| Nivel | Qué detecta | Qué NO detecta |
|---|---|---|
| Conteo de filas | Filas perdidas o duplicadas | Filas alteradas |
| Suma de control | Alteraciones en la columna sumada | Alteraciones en el resto |
| `CHECKSUM_AGG(BINARY_CHECKSUM(...))` | Cualquier cambio en las columnas incluidas | — |

El checksum se calcula sobre las columnas de **negocio** y excluye a propósito las claves subrogadas y las de auditoría (`EjecucionIdCarga`, `FechaCarga`), que por diseño cambian en cada carga y harían que nunca coincidiera.

`07-migracion/76-validacion-post-migracion.sql` es **el mismo script** en los dos entornos: produce un conjunto normalizado que `77-comparar-local-cloud.ps1` obtiene de ambos y resta. No hay una versión "de la nube" y otra "local" que puedan divergir.

---

## 2. Infraestructura desplegada

| Recurso | Identificador | Detalle |
|---|---|---|
| RDS for PostgreSQL 16.14 | `turismodw-pg` | `db.t4g.micro`, 20 GB gp3, `us-east-1` |
| RDS for SQL Server 2022 Express | `turismodw-sql` | `db.t3.small`, 20 GB gp3, `us-east-1` |
| Bucket S3 | `turismodw-migracion-063876841411` | Acceso público bloqueado |
| MongoDB Atlas M0 | `moviles-ii.muywssn.mongodb.net` | Base `turismo_nosql`, región `CENTRAL_US` |
| Grupo de seguridad | `turismodw-sg` | Entrada solo desde una IP `/32`, puertos 1433 y 5432 |
| Rol IAM + option group | `turismodw-s3-role`, `turismodw-backup-restore` | Habilitan `SQLSERVER_BACKUP_RESTORE` |

> **Dos desviaciones respecto del plan.** La clase de SQL Server subió de `db.t3.micro` a `db.t3.small` por la razón que explica la sección 6.1. Y el cluster de Atlas quedó en `CENTRAL_US` y no en `us-east-1`: se reutilizó un cluster existente en vez de crear uno nuevo, porque el service account de Atlas no tiene el rol de creador de proyectos en la organización y la capa gratuita admite un solo cluster por proyecto. La consecuencia es latencia adicional entre Atlas y RDS, que no afecta al ETL —lee de ambos por separado— pero sí quedaría registrada si alguna vez se cruzaran en una misma consulta.

---

## 3. PostgreSQL → RDS for PostgreSQL

Herramienta: `pg_dump -Fc` más `pg_restore -j 4`, ejecutados dentro del contenedor de origen. Volcado de **85,2 MB en 13,6 s**; restauración en **167,0 s**.

| Tabla | Origen | Destino | Veredicto |
|---|---:|---:|---|
| `reserva` | 2 000 010 | 2 000 010 | OK |
| `reserva_tour` | 2 577 212 | 2 577 212 | OK |
| `reserva_habitacion` | 1 632 458 | 1 632 458 | OK |
| `cliente` | 50 008 | 50 008 | OK |
| `preferencia_cliente` | 50 005 | 50 005 | OK |
| `tipo_habitacion` | 791 | 791 | OK |
| `tour` | 400 | 400 | OK |
| `paquete_hotel` | 282 | 282 | OK |
| `paquete_tour` | 227 | 227 | OK |
| `hotel` | 200 | 200 | OK |
| `paquete_turistico` | 150 | 150 | OK |

`SUM(monto_total)`: **16 709 503 160,28** en ambos lados, sin diferencia.

**El índice GIN sobrevivió.** `idx_pref_gin ON public.preferencia_cliente USING gin (datos_adicionales)` está presente en el destino, junto con los otros 19 índices. Era el objeto con más riesgo de perderse, porque muchas herramientas de copia mueven filas y no estructura; `73-migrar-postgres.ps1` lo verifica contra `pg_indexes` en vez de darlo por hecho.

Evidencia: `00-docs/05-evidencias/migracion/migracion-postgres-completa.txt`

---

## 4. Archivos JSON y XML → S3

Herramienta: `aws s3 sync`. Los cinco archivos llegaron con el tamaño exacto.

| Archivo | Bytes locales | Bytes en S3 |
|---|---:|---:|
| `preferencias_lote1.json` | 1 031 610 | 1 031 610 |
| `preferencias_lote2.json` | 1 030 727 | 1 030 727 |
| `preferencias_lote3.json` | 1 030 515 | 1 030 515 |
| `paquetes_2026.xml` | 41 952 | 41 952 |
| `paquetes_2025.xml` | 41 520 | 41 520 |

Una segunda corrida no volvió a subir nada, lo que confirma que `sync` es idempotente y que el script se puede repetir sin costo.

Evidencia: `00-docs/05-evidencias/migracion/migracion-archivos-s3.txt`

---

## 5. Almacén analítico → RDS for SQL Server

Ruta primaria: DDL portable más `bcp` en formato nativo (`-n`) con preservación de identidades (`-E`). **8 699 504 filas en 509,9 s**, unas 17 000 filas por segundo sobre internet.

| Tabla | Origen | Destino | MB | Segundos |
|---|---:|---:|---:|---:|
| `dw.FactReservaTour` | 2 577 212 | 2 577 212 | 238,4 | 147,4 |
| `dw.FactReserva` | 2 000 010 | 2 000 010 | 204,1 | 124,7 |
| `dw.FactReservaHabitacion` | 1 632 458 | 1 632 458 | 174,4 | 91,4 |
| `dw.FactInteraccionWeb` | 1 500 002 | 1 500 002 | 167,2 | 73,3 |
| `dw.FactResena` | 500 002 | 500 002 | 53,8 | 24,8 |
| `dw.FactOcupacionDiaria` | 431 321 | 431 321 | 26,3 | 18,2 |
| `dw.DimCliente` | 50 009 | 50 009 | 19,6 | 16,6 |
| `etl.Numeros` | 4 000 | 4 000 | 0,0 | 1,9 |
| `dw.DimTiempo` | 2 923 | 2 923 | 0,2 | 1,7 |
| *(6 dimensiones menores)* | 1 567 | 1 567 | 0,2 | 9,8 |
| **TOTAL** | **8 699 504** | **8 699 504** | **884,2** | **509,9** |

Índices y columnstore creados después de la carga en 48,5 s. **Las 32 claves foráneas quedaron validadas y confiables: cero `is_not_trusted`, cero `is_disabled`.**

> **Por qué `-E` no es opcional.** Todas las claves subrogadas del modelo son `IDENTITY`, y las foráneas de los hechos apuntan a ellas. Sin `-E`, SQL Server habría generado números nuevos al insertar las dimensiones y el modelo estrella habría quedado desarmado: los conteos habrían cuadrado y las relaciones no.

### 5.1 El esquema migró literal

El hallazgo más importante del piloto. **RDS aceptó los filegroups por propósito**, así que los scripts `41` a `45` y `47b` se ejecutaron **sin una sola modificación**:

| Objeto | Local | RDS |
|---|---:|---:|
| Tablas `stg` | 15 | 15 |
| Dimensiones | 8 | 8 |
| Hechos | 6 | 6 |
| Tablas `etl` | 5 | 5 |
| Vistas | 18 | 18 |
| Procedimientos | 15 | 15 |
| Funciones | 1 | 1 |
| Claves foráneas | 32 | 32 |
| **Filegroups de usuario** | **12** | **12** |
| **Archivos de datos** | **14** | **14** |
| Funciones de partición | 1 | 1 |

`40-crear-basedatos.rds.sql` creó los 4 filegroups por propósito (`FG_DIM`, `FG_FACT` con dos archivos, `FG_STG`, `FG_IDX`) y `47b-particionamiento.rds.sql` los 8 anuales, con `ps_TurismoAnio` mapeado a ellos igual que on-premise.

> **Esto invalida una creencia extendida.** La restricción de "solo `PRIMARY`" es de **Azure SQL Database**, no de los servicios gestionados en general. RDS for SQL Server sí permite administrar filegroups mientras no se elijan rutas físicas: basta con apuntar los archivos a `D:\rdsdbdata\DATA\`, que es el directorio que el servicio expone. El adaptador que quita las cláusulas `ON FG_*` quedó escrito y probado en `75-migrar-dw.ps1`, pero no hizo falta usarlo.

### 5.2 La única vista que necesitó adaptación

`dw.vw_EstadoSistema` leía `sys.database_mirroring`, `sys.availability_replicas`, `sys.dm_hadr_*` y `sys.dm_os_sys_info`. En RDS no hay mirroring ni grupo de disponibilidad propio, y `dm_os_sys_info` exige `VIEW SERVER STATE`.

`07-migracion/sql/45b-vistas-estado-rds.sql` la reemplaza conservando **las 21 columnas con nombre y tipo idénticos**, que es lo que exige `EstadoSistema.tmdl` del modelo de Power BI. Verificado en el destino:

```text
NodoActual       EC2AMAZ-4AR53DH
Edicion          Express Edition (64-bit)
RolMirroring     RDS Single-AZ
EstadoMirroring  GESTIONADO POR AWS
Testigo          Cluster: RDS gestionado por AWS
```

La hora de arranque de la instancia pasa a obtenerse de `create_date` de `tempdb`, que SQL Server recrea en cada arranque: mismo dato, sin permisos elevados.

> **`NodoActual` no es estable en RDS.** Al escalar la clase de `db.t3.micro` a `db.t3.small`, AWS reemplazó la máquina y `@@SERVERNAME` pasó de `EC2AMAZ-CEG5E1B` a `EC2AMAZ-4AR53DH`. Conviene saberlo antes de la demostración: la página 6 del reporte va a mostrar un nombre distinto después de cualquier cambio de clase o de un mantenimiento de AWS. No es un error, es cómo funciona el servicio gestionado, y es justamente lo que la columna debe reflejar.

### 5.3 Verificación de integridad

`76-validacion-post-migracion.sql` contra RDS: **14 de 14 controles OK — `MIGRACION VERIFICADA`**. Reservas 2 000 010, `SUM(MontoTotal)` 16 709 503 160,28 sin diferencia, cero huérfanos, cero duplicados.

El contraste de métricas entre los dos entornos, tabla por tabla:

| Tabla | Filas | Suma de control | Checksum |
|---|---|---|---|
| Las 14 tablas de `dw` | Coinciden | Coinciden | **Idénticos** |

> **El checksum es lo que convierte esto en una verificación de verdad.** Comparar conteos detecta filas perdidas; comparar sumas detecta alteraciones en la columna sumada. `CHECKSUM_AGG(BINARY_CHECKSUM(...))` sobre las columnas de negocio detecta **cualquier** cambio. Que los 14 coincidan significa que no se alteró ni una fila en el camino.

La distribución por partición se reprodujo exacta, con los mismos nombres de filegroup:

| Partición | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Filegroup | `FG_PRE2021` | `FG_2021` | `FG_2022` | `FG_2023` | `FG_2024` | `FG_2025` | `FG_2026` | `FG_2027PLUS` |
| Filas | 0 | 333 424 | 334 078 | 333 542 | 334 499 | 331 702 | 332 760 | **5** |

Las 5 filas de P8 son las reservas de 2027 que introdujo la prueba de carga incremental: viajaron a la nube y siguen enrutadas a la partición correcta.

### 5.4 El modelo de Power BI, repuntado y verificado

Las **16 particiones** del modelo semántico se repuntaron de `localhost,14330` al endpoint de RDS con `07-migracion/repuntar-powerbi.ps1`. `_Medidas.tmdl` no se toca porque su partición es una tabla literal sin origen SQL.

Las 16 vistas que consume el modelo responden en la nube con los conteos correctos:

| Vista | Filas |
|---|---:|
| `dw.vw_FactReservaTour` | 2 577 212 |
| `dw.vw_FactReserva` | 2 000 010 |
| `dw.vw_FactReservaHabitacion` | 1 632 458 |
| `dw.vw_FactInteraccionWeb` | 1 500 002 |
| `dw.vw_FactResena` | 500 002 |
| `dw.vw_FactOcupacionDiaria` | 431 321 |
| `dw.vw_DimCliente` | 50 009 |
| `dw.vw_DimTiempo` | 2 922 |
| *(6 dimensiones menores)* | 1 567 |
| `dw.vw_EstadoSistema` | 1 |
| `dw.vw_CalidadDatos` | **0** |

> `dw.vw_CalidadDatos` devuelve cero filas **por diseño**: resume `etl.Error`, y la bitácora de la nube arranca limpia para que las corridas cloud sean distinguibles de las locales. Se poblará en la primera corrida del ETL contra la nube.

**Lo que falta y no se puede guionizar:** abrir el `.pbip` en Power BI Desktop, autenticar y refrescar es un paso interactivo. La validación de arriba es **estática** —comprueba que el modelo apunta a RDS y que las 16 vistas responden— pero no reemplaza el refresco real ni las capturas de las páginas 1 y 6. Ver `00-docs/11-traspaso-cloud.md`.

Evidencia: `00-docs/05-evidencias/migracion/migracion-dw-completa.txt`, `metricas-cloud.txt`, `powerbi-validacion-cloud.txt`

---

## 6. Incidentes durante la migración

Los seis se resolvieron. Se documentan porque cada uno cambió una decisión o corrigió un supuesto, y porque varios habrían pasado inadvertidos.

### 6.1 La memoria, no el tamaño, fue el límite de Express

El inventario descartó el riesgo de **tamaño** —2,3 GB contra un tope de 10 GB— pero el cuello de botella resultó ser la **memoria**, que ningún inventario de objetos reporta.

Medido en `db.t3.micro`:

| Métrica | Valor |
|---|---:|
| Memoria física | 995 MB |
| `max server memory` | 725 MB |
| **Target Server Memory** | **125 MB** |
| Concesiones otorgadas / en espera | **0 / 3** |

Con eso, hasta un `insert bulk` de 2 923 filas en `dw.DimTiempo` se quedó suspendido en `RESOURCE_SEMAPHORE` sin conseguir concesión de memoria. No era lentitud: era imposibilidad.

Tras escalar a `db.t3.small`: 2 009 MB físicos, `max server memory` 1 576 MB, **cero concesiones en espera**, y la misma carga corrió a unas 16 000 filas por segundo.

> La palanca fue la **clase de instancia**, no la edición. Express seguía siendo la edición correcta; lo mal dimensionado era la máquina. El costo pasó de 0,018 a 0,036 USD/hora. La lección: al dimensionar un destino gestionado, el tope de almacenamiento de la edición es el límite **visible**, y la memoria de la clase es el que de verdad decide si la carga corre.

### 6.2 Servicios nativos secuestrando los puertos de Docker

La máquina de trabajo tenía PostgreSQL 15/17 y MongoDB **nativos de Windows** escuchando en 5432, 5433 y 27017 sobre IPv4, mientras Docker publicaba sobre IPv6. Una cadena de conexión con `127.0.0.1` resuelve a IPv4 y termina hablando con el servicio **nativo**, sin error y sin aviso.

Se detectó porque una corrida del ETL reportó 2 000 005 reservas cuando el contenedor tenía 2 000 010. **Si no se hubiera detectado, la migración habría copiado datos de un origen equivocado y la validación habría cuadrado igual**, porque ambas copias son casi idénticas.

Solución: `docker/docker-compose.override.yml` publica PostgreSQL en `15432` y MongoDB en `27018`, puertos que no colisionan.

### 6.3 Un comentario T-SQL que se comió el resto del script

`47b-particionamiento.rds.sql` falló con `Missing end comment mark '*/'`. La causa: el comentario de cabecera mencionaba la ruta `/var/opt/mssql/data/` seguida de un asterisco, y esa secuencia **abre un comentario anidado** —T-SQL los admite—, dejando el bloque sin cerrar.

### 6.4 Un filtro de muestreo que no seleccionaba nada

El piloto de MongoDB filtraba `calificacion % 10 = 0`. La calificación va de 1 a 5, así que el resto nunca da cero y el subconjunto salía vacío. Se cambió a `cliente_id % 10 = 0`, el mismo criterio que usa el piloto relacional. La lección: el campo de una marca de muestreo tiene que tener **rango suficiente**, no solo ser numérico.

### 6.5 Credenciales en la bitácora

Cuando `mongorestore` falla, incluye la **URI completa, con contraseña**, en el mensaje de error. El script escribía esas líneas en la bitácora de `00-docs/05-evidencias/`, que sí se versiona.

Se verificó que no llegó a filtrarse nada —las únicas coincidencias en el repositorio son plantillas con `<clave>`— y se añadió una función de redacción que enmascara la contraseña por dos vías antes de escribir cualquier línea.

### 6.6 Una sesión huérfana bloqueando la base

Al interrumpir una carga, la sesión `insert bulk` del lado del servidor sobrevivió al proceso local y quedó suspendida reteniendo un bloqueo de esquema, con lo que toda la instancia parecía colgada. Se identificó con `sys.dm_exec_requests` —`blocking_session_id` apuntando a la huérfana— y se resolvió con `KILL`. Conviene saberlo: `rdsadmin.dbo.rds_kill` no existe en esta versión de RDS, pero `KILL` directo sí funciona para el usuario maestro.

---

## 7. Carga incremental y recuperación ante error

Ambas pruebas corrieron **antes** de migrar, sobre el entorno local, y sus objetos (`etl.Marca`, `usp_CargarHechosIncremental`, `usp_CargarOcupacionIncremental`) viajaron a la nube con el resto del esquema.

### 7.1 Carga incremental

| Modo | Filas de staging | Duración |
|---|---:|---:|
| `FULL` | 8 317 880 | 8 min 29 s |
| `INCREMENTAL` | 2 050 | 22 s |

Reducción de volumen del **99,975 %** y **23 veces** más rápida. Las novedades inyectadas —3 clientes, 5 reservas de 2027, 5 líneas de habitación, 2 reseñas y 2 interacciones— se detectaron todas, y `dw.FactReserva` pasó de 2 000 005 a 2 000 010 filas conservando el histórico.

Las 5 reservas de 2027 aterrizaron en la partición **P8 (`FG_2027PLUS`), que estaba vacía**: comprueba que el enrutado por partición sigue funcionando tras una carga incremental, sin haber reconstruido ningún índice.

Tras la incremental, `46-validacion-consistencia.sql` devolvió **22/22 MODELO CONSISTENTE**.

> **Un detalle del conjunto de datos, no del mecanismo.** El generador produce `fecha_actualizacion` hasta 2026-12-31, o sea en el futuro respecto del reloj del sistema. Una fila insertada con `now()` queda **por debajo** de la marca de agua y no se detecta. Por eso las novedades de prueba se fecharon en 2027. Es un rasgo del conjunto sintético que conviene tener presente al repetir la prueba.

### 7.2 Recuperación ante error de ETL

Se corrompió el archivo intermedio `reserva.dat` con 50 filas bien formadas pero inválidas —`reserva_id` de 200 caracteres en una `nvarchar(50)` y texto en la columna `int` `EjecucionId`— y se relanzó el ETL. Los cinco criterios pasaron:

| Criterio | Resultado |
|---|---|
| El fallo devuelve código 1 y queda como `FALLIDO` | Sí |
| La etapa culpable está identificada en `etl.Etapa` | `CARGAR_STG` / `stg.Reserva` |
| Los hechos del DW no se alteran durante el fallo | Conteos idénticos |
| Las marcas de agua no avanzan | Idénticas |
| El relanzamiento converge al mismo estado | Código 0, conteos idénticos |

> **Por qué esa forma de corromper y no otra.** Un primer intento agregó filas con pocas columnas y **no falló**: el terminador de fila es un salto de línea y el de campo es `|~|`, así que `bcp` siguió consumiendo líneas hasta juntar doce campos, y como todas las columnas de staging son `nvarchar` por diseño, cualquier texto entra. Staging es deliberadamente permisivo —la validación ocurre después, en `etl.usp_ValidarStaging`—, así que para provocar un fallo real hay que violar el **esquema**, no los datos.

Evidencia: `00-docs/05-evidencias/migracion/carga-incremental.txt` y `prueba-recuperacion-etl.txt`

---

## 8. MongoDB → Atlas M0

Herramienta: `mongodump` / `mongorestore` en formato BSON, ejecutados dentro del contenedor de origen. BSON conserva los tipos nativos; `mongoexport` habría degradado fechas y enteros de 64 bits, y con 2 000 000 de documentos esa conversión introduciría diferencias que la validación leería como errores reales.

| Colección | Origen | Atlas | Cobertura | Veredicto |
|---|---:|---:|---:|---|
| `resenas` | 500 002 | 500 002 | 100,0 % | **Completa** |
| `interacciones_web` | 1 500 002 | 749 872 | 50,0 % | **Muestreo determinista** |

Los **8 índices** (2 implícitos `_id_` y 6 explícitos) se recrearon en el destino: `mongorestore` los reconstruye al terminar de cargar cada colección, leyéndolos de los metadatos del volcado. Ocupación final: 99 MB de almacenamiento más 63 MB de índices.

### 8.1 El riesgo R2 sí se materializó, por una razón distinta

Al planificar se temió que 2 000 000 de documentos no cupieran en los 512 MB de M0. El inventario lo desmintió midiendo `turismo_nosql` en **205 MB** comprimidos, y se decidió migrar el conjunto completo.

**La medición era correcta y la conclusión equivocada**, porque faltaba un dato que el inventario no podía ver: *el cupo de M0 se cuenta por **cluster**, no por base de datos*. Se reutilizó un cluster que ya alojaba los datos de otro proyecto, y el usuario de base creado para esta migración tiene permisos acotados a `turismo_nosql`, de modo que `listDatabases` no devolvía nada y el espacio ya ocupado era invisible.

El primer intento se detuvo solo, a 1 128 000 documentos, con el mensaje del servidor:

```text
(AtlasError) you are over your space quota, using 518 MB of 512 MB.
Writes are blocked on your cluster.
```

> **Ese resultado se descartó a propósito.** 1 128 000 documentos no es una decisión: es el punto donde se acabó el espacio, y depende de en qué documento ocurrió. Dos corridas darían números distintos y la evidencia no sería verificable. Se reemplazó por un muestreo **determinista** con `--query '{"duracion_seg": {"$mod": [2, 0]}}'`, que selecciona 749 872 documentos —el 50,0 % exacto— y produce el mismo conjunto en cada corrida.
>
> Se eligió `duracion_seg` y no `cliente_id` porque el 35 % de las interacciones son anónimas y llevan `cliente_id` nulo: `$mod` no las alcanza y el muestreo habría quedado sesgado hacia los visitantes identificados. Es la misma lección de la sección 7.4, aplicada al revés: el campo de una marca de muestreo necesita rango suficiente **y** cobertura completa.

`resenas` se migró **completa** a propósito: alimenta `FactResena` y todos los KPI de satisfacción, que son los que el dashboard consume.

### 8.2 Cómo se levantaría la limitación

| Opción | Costo | Efecto |
|---|---|---|
| Atlas M10 dedicado | ~57 USD/mes | 10 GB, cabría todo con holgura |
| Cluster M0 propio en otro proyecto | 0 USD | Requiere el rol de creador de proyectos en la organización, que el service account no tiene |
| Amazon DocumentDB | ~0,09 USD/h + bastión EC2 | Sin capa gratuita y solo accesible dentro de la VPC |

Evidencia: `00-docs/05-evidencias/migracion/migracion-mongo-completa.txt`

---

## 9. El ETL operando contra la nube

Requisito de Semana 4: *"Actualizar ETL para conectarse a las bases migradas"* y *"Ejecutar carga incremental utilizando la infraestructura cloud"*. Ambos verificados en una sola corrida.

El ETL no necesitó cambios de código para hablar con la nube, solo de configuración: `05-etl/.env.aws` apunta `PG_HOST` al endpoint de RDS PostgreSQL y `SQL_SERVIDOR` al de RDS SQL Server, con `SQL_PUERTO=1433` y `SQL_CIFRADO=yes`. Lo único que sí hizo falta tocar fue `config.py`, que armaba `SERVER={SQL_SERVIDOR}` sin puerto: un endpoint de RDS necesita `host,puerto` y ni la cadena ODBC ni `bcp` aceptan `host:puerto`.

Corrida `INCREMENTAL --solo-pg` contra la infraestructura migrada, **COMPLETADO en 118 s**:

| Aspecto | Resultado |
|---|---|
| Servidor destino | `EC2AMAZ-4AR53DH`, Express Edition |
| Origen leído | RDS for PostgreSQL, 2 000 011 reservas |
| Marcas de agua | Leídas de `etl.Marca` **en la nube** |
| Filas extraídas | 2 053 (solo el delta) |
| Etapas registradas | 19, todas `COMPLETADO` |
| Rechazos | 0 |
| Dimensiones | `dw.DimCliente` 50 009 → 50 010 |
| Hechos | `dw.FactReserva` 2 000 010 → 2 000 011 |
| Ocupación | Recalculada por ámbito: 431 321 → 431 325 |
| Marcas avanzadas | 3 |

> **La bitácora distingue el entorno sola.** `etl.Ejecucion` tiene `Servidor sysname DEFAULT @@SERVERNAME`, así que cada corrida queda marcada con el nodo donde ocurrió. En la nube esa columna dice `EC2AMAZ-4AR53DH` y en local `873e20f577e4`. Fue el motivo de migrar la bitácora vacía: mezcladas, las corridas locales y las cloud serían indistinguibles en el reporte.

La etapa más cara fue `VERIFICAR_INTEGRIDAD` con **76 s**: revalidar 32 claves foráneas sobre 8,7 millones de filas cuesta bastante en una `db.t3.small` con 2 vCPU.

> **Lo que esta corrida NO probó.** Se usó `--solo-pg`, así que ejercitó PostgreSQL en RDS y el DW en RDS, pero **no** leyó de Atlas ni de los archivos. Se eligió así porque la migración de MongoDB estaba en curso en ese momento y una lectura concurrente habría medido el restore, no el ETL.
>
> El camino de Mongo y archivos está probado contra el laboratorio local —la prueba de carga incremental de la sección 7.1 los ejercita completos— pero **falta una corrida cloud sin `--solo-pg`** para cerrar el entregable del todo. El procedimiento está en `00-docs/11-traspaso-cloud.md`, sección 3.4.

Evidencia: `00-docs/05-evidencias/migracion/etl-cloud.txt`

---

## 10. Comparación entre el entorno local y la nube

Los dos entornos no son comparables en hardware, y conviene decirlo antes de los números:

| | Local | Nube |
|---|---|---|
| Servidor | `873e20f577e4` | `EC2AMAZ-4AR53DH` |
| Edición | Developer | **Express** |
| vCPU | 16 | **2** |
| Memoria | 4 096 MB | **2 009 MB** |
| Almacenamiento | NVMe local | EBS gp3 por red |
| Distancia | localhost | `us-east-1` |

### 10.1 Integridad: idéntica

Las 14 tablas coinciden en filas, suma de control y **checksum**. Sin diferencias.

### 10.2 Rendimiento: hay que separar la conexión de la consulta

Cada medición lanza un proceso `sqlcmd` nuevo, así que incluye arranque, TCP, TLS, autenticación y recién después la consulta. Medido con `SELECT 1`:

| Entorno | Costo fijo por invocación |
|---|---:|
| Local | 52,7 ms |
| Nube | 783,9 ms |
| **Sobrecosto de la nube** | **731,2 ms** |

Ese costo fijo **domina** cualquier consulta que dure poco. Por eso se reportan las dos medidas: la bruta, que es lo que sentirá Power BI, y la neta, que es lo que hace el motor.

| Consulta | Local | Nube | Factor | Local neto | Nube neto | Factor neto |
|---|---:|---:|---:|---:|---:|---:|
| T1 Eliminación de partición (2024) | 55,9 | 781,3 | 14,0x | 3,2 | 0,1 | *(bajo ruido)* |
| T2 Ocupación por país y mes | 70,7 | 888,7 | 12,6x | 18,0 | 104,9 | **5,8x** |
| T3 Ranking de tours | 65,9 | 817,7 | 12,4x | 13,2 | 33,8 | **2,6x** |
| T4 Perfil del visitante vs satisfacción | 542,5 | 9 386,4 | 17,3x | 489,8 | 8 602,5 | **17,6x** |
| T5 Tendencia mensual | 69,6 | 855,2 | 12,3x | 16,9 | 71,3 | **4,2x** |

*Mediana de 5 corridas más una de calentamiento que se descarta, la misma metodología que usó el Integrante 4.*

> **La columna bruta miente por omisión y la neta también.** Mirando solo el factor bruto, las cinco consultas parecen degradarse por igual —entre 12x y 17x—, lo que sugeriría que el motor de la nube es uniformemente peor. Es falso: descontado el costo de conexión, la degradación real va de 2,6x a 17,6x, es decir, **depende muchísimo de la consulta**. Mirando solo la neta, en cambio, se escondería que cada ida y vuelta a `us-east-1` cuesta tres cuartos de segundo, que es tiempo real que el usuario del reporte sí espera.

**T1 quedó por debajo del ruido.** Su tiempo neto local es de 3,2 ms: con un costo fijo que varía decenas de milisegundos entre corridas, restarlo deja un número sin significado. Es una limitación honesta del método: la resta solo sirve cuando la consulta dura bastante más que la variabilidad de la medición. Que T1 sea tan rápida es, de hecho, la prueba de que la eliminación de particiones funciona igual en la nube.

**T4 es la única regresión seria: 17,6x incluso descontando la red.** Es la consulta de perfil del visitante contra satisfacción, con `COUNT(DISTINCT)` y un `LEFT JOIN` entre `FactReserva` (2 M) y `FactResena` (500 k) agrupado por país. Es la más hambrienta de memoria de las cinco, y el destino tiene la mitad de RAM y un octavo de los núcleos.

> **Y no es una sorpresa: T4 ya era la excepción on-premise.** El Integrante 4 la documentó como la única de las cinco que **empeoró** tras el particionamiento y los índices (707 ms → 873 ms). Es la consulta que no se beneficia del diseño, y es coherente que también sea la que peor tolera un destino más pequeño. La continuidad del hallazgo entre las dos semanas refuerza que es una propiedad de la consulta, no del entorno.

### 10.3 Qué concluir

La migración se juzga por **integridad**, y ahí el resultado es perfecto. El rendimiento es peor, y era esperable: nadie debería esperar que `db.t3.small` con Express iguale a Developer con 16 núcleos y disco local.

Lo importante es que **la palanca para cerrar esa brecha es la clase de instancia, no el diseño**. Subir a `db.t3.medium` o `db.m5.large` es un cambio de configuración de minutos, no una migración nueva: el esquema, las particiones, los columnstore y el ETL ya están donde tienen que estar.

Evidencia: `00-docs/05-evidencias/migracion/comparacion-local-cloud.txt`

---

## 11. Documentos relacionados

- `00-docs/07-estrategia-migracion.md` — estrategia, arquitectura, riesgos y plan de reversión
- `00-docs/08-matriz-herramientas.md` — herramientas evaluadas y justificación
- `00-docs/09-inventario-migracion.md` — inventario de objetos con veredicto de portabilidad
