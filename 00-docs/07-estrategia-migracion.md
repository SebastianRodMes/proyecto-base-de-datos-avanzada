# Estrategia de migración a la nube

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Documento de estrategia, arquitectura destino, plan de ejecución, riesgos y plan de reversión para llevar la solución TurismoDW desde el laboratorio on-premise hacia AWS.

> **Cambio de eje respecto de las semanas 1 y 2.** El proyecto nació orientado a alta disponibilidad: mirroring, Always On, failover y un endpoint lógico `localhost,14330`. El replanteamiento de las semanas 3 y 4 mueve el objetivo hacia integración, migración y operación cloud. Este documento no descarta el trabajo anterior —queda como evidencia de las semanas 1 y 2— pero sí lo reencuadra: en un servicio gestionado la redundancia deja de ser algo que uno construye y pasa a ser algo que uno contrata. La sección 6 explica qué se pierde y qué se gana con ese cambio.

---

## 1. Punto de partida

Lo que existe hoy, medido y reconciliado, no estimado:

| Componente | Estado on-premise | Volumen |
|---|---|---:|
| PostgreSQL 16 | Origen operacional `turismo`, 13 tablas | 2 000 005 reservas / 768 MB |
| MongoDB 7 | Origen NoSQL `turismo_nosql`, 2 colecciones | 2 000 000 documentos |
| Archivos | 3 JSON + 2 XML en `03-archivos/entrada/` | 6 150 registros |
| SQL Server 2022 | `TurismoDW`: 8 dimensiones, 6 hechos, 17 vistas, 10 procedimientos | 8 640 983 filas de hechos |
| ETL Python | `05-etl/`, bitácora en `etl.Ejecucion` | 8 317 880 filas de staging |
| Power BI | `06-powerbi/TurismoDW.pbip` | 17 tablas, 26 relaciones, 52 medidas |

Todo corre sobre Docker Desktop en una sola máquina. El inventario objeto por objeto, con el veredicto de portabilidad de cada uno, está en `00-docs/09-inventario-migracion.md`.

---

## 2. Estrategia elegida: rehost híbrido

De las cinco estrategias clásicas de migración se evaluaron tres:

| Estrategia | Qué implicaría aquí | Veredicto |
|---|---|---|
| **Rehost** (*lift and shift*) | Mismos motores, mismo esquema, mismas consultas, sobre servicios gestionados | **Elegida** |
| Replatform | Cambiar el DW a Redshift o BigQuery, el origen a Aurora | Descartada |
| Refactor | Rediseñar el modelo para un almacén columnar nativo de la nube | Descartada |

> **Por qué rehost y no replatform.** El valor del proyecto está en el modelo estrella, en los diez procedimientos `etl.usp_*`, en las 17 vistas `dw.vw_*` y en las 52 medidas DAX. Un replatform a Redshift obligaría a reescribir el `MERGE` de dimensiones (Redshift no lo soporta igual), la explosión de estadías de `usp_CargarOcupacionDiaria`, las tres funciones de partición y las medidas que dependen de `DATABASEPROPERTYEX`. Sería un proyecto nuevo, no una migración, y no cabe en dos semanas. Rehost conserva el T-SQL íntegro y permite comparar local contra nube sobre una base honesta: mismo motor, mismo esquema, misma consulta.

**Híbrida por diseño, no por concesión.** Los archivos JSON y XML no se migran a una base de datos: van a S3 como *landing zone* cruda. Son la fuente de la que el ETL extrae; convertirlos en tablas destruiría la evidencia de que la solución integra cuatro tipos de fuente distintos. El enunciado admite migración "completa o híbrida", y aquí la parte híbrida es una decisión de diseño, no una limitación.

---

## 3. Arquitectura cloud destino

```text
 ON-PREMISE (Docker Desktop)                      AWS  us-east-1
 ---------------------------                      ------------------------------

 postgres:16                                      RDS for PostgreSQL 16.14
   turismo                 pg_dump -Fc              turismodw-pg
   2 000 005 reservas   ------------------->        db.t4g.micro / 20 GB gp3
   768 MB                  pg_restore                publicamente accesible
                                                     SG abierto a una sola IP

 mongo:7                                          MongoDB Atlas M0
   turismo_nosql           mongodump                 AWS CENTRAL_US
   500 000 resenas      ------------------->         512 MB por CLUSTER, no
   1 500 000 interac.      mongorestore               por base (ver R2)

 03-archivos/entrada/                             S3  turismodw-migracion-<cuenta>
   preferencias_*.json     aws s3 cp                 /raw/     landing zone
   paquetes_*.xml       ------------------->         /bak/     respaldos .bak
   6 150 registros                                   acceso publico bloqueado

 SQL Server 2022 Developer                        RDS for SQL Server 2022 Express
   TurismoDW               DDL portable + bcp        turismodw-sql
   8 640 983 filas      ------------------->         db.t3.small / 20 GB gp3
   14 archivos de datos    (.bak+S3 como              option group con
   particion anual          ruta alterna)             SQLSERVER_BACKUP_RESTORE
                                                              ^
 ETL Python (host Windows)  ---------------------------------|
   .env.aws con endpoints cloud                              |
                                                             |
 Power BI Desktop  -------------------------------------------
   16 particiones TMDL repuntadas al endpoint RDS
```

**Dimensionamiento y por qué.**

| Recurso | Elección | Costo/hora | Razón |
|---|---|---:|---|
| RDS PostgreSQL | `db.t4g.micro`, 20 GB gp3 | $0.016 | Solo sirve lecturas al ETL; 768 MB entran de sobra |
| RDS SQL Server | `sqlserver-ex`, `db.t3.small`, 20 GB gp3 | $0.036 | Se provisiono `db.t3.micro` y hubo que escalar: ver R3c |
| MongoDB Atlas | M0 | $0.000 | Capa gratuita permanente |
| S3 | Estándar, < 1 GB | ~$0.00003 | Landing zone y respaldos |

> **Por qué Express y no Standard.** El DW real pesa alrededor de 2 GB de datos más índices, muy por debajo del tope de 10 GB por base de Express. Standard cuesta ~$0.44/hora con licencia incluida: veinticuatro veces más, para una capacidad que este proyecto no necesita. La postura es empezar por Express y escalar **solo si el piloto choca con un límite real**; si eso ocurre, el límite encontrado es un hallazgo del entregable y no un fracaso. Lo que no se hace es pagar Standard preventivamente.

Costo total estimado: **menos de 5 USD** por tres días de operación continua. `07-migracion/78-detener-recursos.ps1` detiene ambas instancias al cerrar cada sesión, con lo que el gasto en reposo baja a solo almacenamiento.

---

## 4. Plan de migración

### 4.1 Secuencia

| # | Fase | Script | Reversible |
|---:|---|---|---|
| 1 | Provisión de infraestructura | `70-provisionar-aws.ps1` | Sí, borrando recursos |
| 2 | Inventario de objetos | `71-inventario-objetos.ps1` | No aplica, solo lectura |
| 3 | **Piloto 10 %** | `72-piloto-migracion.ps1` | Sí, base desechable |
| 4 | Migración de PostgreSQL | `73-migrar-postgres.ps1` | Sí, origen intacto |
| 5 | Migración de MongoDB | `74-migrar-mongo.ps1` | Sí, origen intacto |
| 6 | Archivos JSON y XML a S3 | `74b-archivos-a-s3.ps1` | Sí, origen intacto |
| 7 | Migración del DW | `75-migrar-dw.ps1` | Sí, origen intacto |
| 8 | Repunte de Power BI | `repuntar-powerbi.ps1` | Sí, `-Local` revierte |
| 9 | Repunte del ETL | `05-etl/.env.aws` | Sí, restaurar `.env` |
| 10 | Validación post-migración | `76-validacion-post-migracion.sql` | No aplica, solo lectura |
| 11 | Comparación local vs nube | `77-comparar-local-cloud.ps1` | No aplica, solo lectura |
| 12 | Prueba de recuperación ante error | `79-prueba-recuperacion-etl.ps1` | Sí, converge sola |
| 13 | Apagado de los recursos | `78-detener-recursos.ps1` | Sí, `-Iniciar` los vuelve |

### 4.2 La migración piloto, y para qué sirve realmente

El enunciado pide migrar un subconjunto de 5 % a 10 % antes de la migración definitiva. **El propósito no es mover datos: es probar las herramientas contra el destino real antes de comprometerse.** Un piloto que solo copia filas y dice "funcionó" no aporta nada.

El piloto de este proyecto responde tres preguntas concretas que no se pueden contestar desde la documentación:

1. **¿Acepta RDS los filegroups por propósito?** Los scripts `41` a `45` y `47b` llevan cláusulas `ON FG_DIM`, `ON FG_FACT`, `ON FG_STG` y `ON FG_IDX` incrustadas en casi cada `CREATE TABLE` y `CREATE INDEX`. Si RDS acepta `ADD FILEGROUP` apuntando a `D:\rdsdbdata\DATA\`, esos scripts migran **sin una sola modificación**. Si los rechaza, hay que degradar todo a `PRIMARY` y adaptar cinco scripts al vuelo. `40-crear-basedatos.rds.sql` prueba la ruta buena, cae a la degradada si falla y deja el veredicto en `dbo.MigracionModo`.

   > **Respondida: RDS los acepta.** `dbo.MigracionModo` quedó en `FILEGROUPS` con los 4 filegroups por propósito, y `47b-particionamiento.rds.sql` creó después los 8 anuales y mapeó `ps_TurismoAnio` a ellos. **12 filegroups de usuario en RDS, exactamente los mismos que on-premise.** Los scripts `41`–`45` y `47b` corrieron sin una sola modificación: el adaptador que quita las cláusulas `ON FG_*` quedó escrito y probado, pero no hizo falta usarlo.
   >
   > Es el hallazgo más valioso del piloto, porque invalida una creencia extendida: la restricción de "solo PRIMARY" es de **Azure SQL Database**, no de los servicios gestionados en general. RDS for SQL Server sí deja administrar filegroups mientras no se elijan rutas físicas.

2. **¿Sirve el restore nativo desde S3?** Se comparan dos rutas para el DW: *(a)* DDL portable más `bcp`, que es determinista y se controla paso a paso; *(b)* `BACKUP DATABASE` local, subida a S3 y `rdsadmin.dbo.rds_restore_database`, que es mucho más rápida pero arrastra la estructura de archivos del origen. La ruta (a) es la primaria justamente porque no depende de que (b) funcione.

3. **¿Aguanta el `bcp` de ODBC 17 el TLS obligatorio de RDS?** El proyecto usa las herramientas de ODBC 17, que no aceptan la opción `-u`. Si RDS exigiera validación de certificado del lado del cliente, habría que migrar a ODBC 18.

El subconjunto es **determinista, no aleatorio**: `reserva_id % 10 = 0` más su cierre referencial. Elegir al azar haría que dos corridas del piloto no fueran comparables entre sí.

### 4.3 Ventana y orden de corte

El origen es un laboratorio, no un sistema en producción, así que no hay ventana de indisponibilidad que negociar. Aun así el orden importa, porque la validación depende de que el origen no se mueva mientras se copia:

1. Congelar el origen: no ejecutar `run_etl.py` ni los generadores durante la copia.
2. Capturar los conteos de referencia con `01-postgres/11-verificacion-origen.sql`.
3. Migrar orígenes (PostgreSQL, MongoDB, archivos a S3).
4. Migrar el DW.
5. Validar con `76-validacion-post-migracion.sql` contra los conteos del paso 2.
6. Recién entonces repuntar ETL y Power BI.

---

## 5. Riesgos y mitigaciones

| # | Riesgo | Prob. | Impacto | Mitigación |
|---:|---|---|---|---|
| R1 | RDS rechaza los filegroups de usuario y hay que degradar a `PRIMARY` | Media | Medio | `40-crear-basedatos.rds.sql` detecta y cae al modo `PRIMARY`; `75-migrar-dw.ps1` adapta `41`–`45` quitando `ON FG_*`. La partición **lógica** se conserva completa |
| R2 | Atlas M0 (512 MB) no admite los 2 000 000 de documentos | Alta | Medio | **Se materializó.** No por el tamaño de la base —205 MB, medidos— sino porque el cupo se cuenta **por cluster** y este ya alojaba otro proyecto. Se migró `resenas` completa y un 50 % determinista de `interacciones_web` |
| R3 | El DW supera el tope de 10 GB de Express | ~~Baja~~ **Descartado** | — | **Cerrado por medición.** 3 409 MB usados, de los cuales 1 447 MB son staging que no migra: el destino queda en ~2,3 GB |
| R3b | La ruta de restauración desde S3 recrea archivos por tamaño **asignado** (11,9 GB) y excede Express | **Alta** | Bajo | Es la ruta alterna, no la primaria. Se prueba en el piloto para documentar el rechazo con números |
| R3c | `db.t3.micro` (1 GB) no tiene memoria para servir la carga masiva | — | — | **Materializado.** Se escaló a `db.t3.small`. Ver el recuadro de abajo |
| R4 | El `bcp` de ODBC 17 falla contra el TLS de RDS | Media | Alto | Detección temprana en el piloto; alternativas: herramientas de ODBC 18, o `BULK INSERT` desde S3 |
| R5 | La subida de ~2 GB por enlace doméstico tarda horas | Media | Medio | El piloto mide la tasa real; la carga completa se hace por tabla, reanudable, sin transacción única |
| R6 | `dw.vw_EstadoSistema` revienta en RDS por leer DMV de Always On | **Alta** | Alto | Ya resuelto: `45b-vistas-estado-rds.sql` la reemplaza conservando las 21 columnas exactas que espera Power BI |
| R7 | Se filtran credenciales al repositorio | Baja | **Crítico** | `.secrets/`, `05-etl/.env.aws`, `*_accessKeys.csv` y `*.pem` en `.gitignore`, verificado con `git check-ignore` |
| R8 | Costo descontrolado por dejar instancias encendidas | Media | Medio | Clases mínimas, `backup-retention-period 0`, y `78-detener-recursos.ps1` al cerrar |
| R9 | El usuario IAM no tiene permisos suficientes | — | — | **Materializado y resuelto.** `ddos-lab` solo leía EC2; se creó `turismodw-migracion` con RDS, S3, EC2 e IAM |

> **Sobre R3c, que ninguna medición previa anticipó.** El inventario descartó el riesgo de *tamaño* —2,3 GB contra un tope de 10 GB— pero el cuello de botella resultó ser la *memoria*, que no aparece en ningún inventario de objetos. Una `db.t3.micro` tiene 995 MB de RAM física; SQL Server se configuró solo con `max server memory` en 725 MB y, en la práctica, su *Target Server Memory* se desplomó a **125 MB**. Con eso, hasta un `insert bulk` de 2 923 filas en `dw.DimTiempo` se quedó suspendido en `RESOURCE_SEMAPHORE` sin conseguir concesión de memoria: 0 concesiones otorgadas y 3 en espera. No era lentitud, era imposibilidad.
>
> Se escaló a `db.t3.small` (2 GB). Es el escalado previsto en el plan, aunque no por donde se esperaba: la palanca fue la **clase de instancia**, no la edición. Express sigue siendo la edición correcta; lo que estaba mal dimensionado era la máquina. El costo pasa de 0,018 a 0,036 USD/hora, unos 0,43 USD más por día.
>
> La lección para el informe: al dimensionar un destino gestionado, el tope de almacenamiento de la edición es el límite **visible**, y la memoria de la clase es el límite que de verdad decide si la carga corre.

> **Sobre R3, que el inventario cerró.** Se planificó a partir de estimaciones del DDL y **la medición lo desactivó**: el DW parecía rozar el tope de 10 GB de Express con 3 409 MB usados, pero al no migrar los 1 447 MB de staging transitorio el destino queda en unos 2,3 GB. Es la justificación de por qué el inventario se genera **antes** de migrar y leyendo catálogos vivos.
>
> **Sobre R2, que enseña lo contrario.** El inventario midió `turismo_nosql` en 205 MB comprimidos y de ahí se concluyó que cabría entero en los 512 MB de M0. La medición era correcta y la conclusión equivocada, porque faltaba un dato que ningún inventario de la base puede ver: **el cupo de M0 se cuenta por cluster, no por base de datos**, y el cluster reutilizado ya alojaba otro proyecto. La migración se detuvo sola en `using 518 MB of 512 MB`. Se resolvió migrando `resenas` completa y un 50 % determinista de `interacciones_web`; el detalle está en `10-validacion-post-migracion.md`, sección 8.
>
> Juntos, R2 y R3 dicen algo más útil que cualquiera por separado: **medir el objeto que se migra no basta si el límite vive en el contenedor que lo aloja.**
>
> A esos se sumó **R3b**, que ninguna estimación anticipaba: la restauración nativa desde S3 recrea los archivos por su tamaño *asignado* (8 832 MB de datos más 3 072 MB de log = 11,9 GB) y no por el usado, con lo que excede el tope de 10 GB de Express. Por eso la ruta primaria es DDL portable más `bcp`, y la de `.bak` se prueba para documentar el rechazo, no para depender de ella.

---

## 6. Plan de reversión

La reversión de esta migración es barata porque **el origen nunca se modifica**. Ningún script de `07-migracion/` escribe en PostgreSQL, MongoDB ni en el SQL Server local: todos leen del origen y escriben en el destino.

| Escenario | Acción de reversión | Tiempo |
|---|---|---:|
| Falla el piloto | Ninguna: la base de destino se recrea desde cero con `40-crear-basedatos.rds.sql` | < 5 min |
| Falla la migración del DW a medias | Volver a correr `75-migrar-dw.ps1`; empieza por recrear la base | < 60 min |
| El ETL cloud produce datos incorrectos | Restaurar `05-etl/.env` local y volver a correr `run_etl.py` contra Docker | < 30 min |
| Power BI no refresca contra RDS | `git checkout 06-powerbi/` devuelve las 16 particiones a `localhost,14330` | < 2 min |
| Abandono total de la migración | `78-detener-recursos.ps1 -Eliminar` y `git revert` de la rama; el laboratorio local queda idéntico | < 20 min |

> **El punto de no retorno no existe en este proyecto.** Es una propiedad deliberada del diseño, no una casualidad: mientras el entorno Docker siga en pie y el repositorio conserve los scripts `40`–`47c` originales, cualquier estado de la migración se puede abandonar sin pérdida. Por eso `07-migracion/sql/` contiene **variantes** de los scripts originales y no reemplazos: `04-sqlserver/40-crear-basedatos.sql` y `47b-particionamiento.sql` quedan intactos.

---

## 7. Criterios de aceptación

La migración se considera terminada cuando:

1. `76-validacion-post-migracion.sql` contra RDS reconcilia contra los conteos que el origen tenga **en ese momento** (`01-postgres/11-verificacion-origen.sql` los produce), con tolerancia de 0.01 en la suma. En la ejecucion registrada fueron 2 000 010 reservas y `SUM(MontoTotal) = 16 709 503 160.28`.
2. Ninguna clave foránea del esquema `dw` queda en `is_not_trusted` ni `is_disabled`.
3. El ETL completa una corrida `FULL` y una `INCREMENTAL` contra la nube, ambas en estado `COMPLETADO` en `etl.Ejecucion`.
4. Una corrida abortada a propósito queda en `FALLIDO` y el relanzamiento converge al mismo estado.
5. Power BI abre el `.pbip`, refresca contra RDS y las 16 tablas cuadran contra SQL Server.
6. La comparación local contra nube existe, con cinco corridas y mediana por consulta, **incluyendo las regresiones**.
7. Ambas instancias RDS quedan detenidas al cerrar.

> **Sobre el punto 6.** Se espera que la nube pierda en varias de las cinco consultas testigo: `db.t3.small` con Express contra un contenedor Developer con 4 GB de memoria y 16 nucleos no es una comparación pareja. Ese resultado se reporta tal cual. El repositorio ya sentó el precedente cuando el Integrante 4 documentó la regresión de T4 en vez de presentar cinco mejoras de cinco.

---

## 8. Documentos relacionados

- `00-docs/08-matriz-herramientas.md` — herramientas evaluadas y justificación de cada elección
- `00-docs/09-inventario-migracion.md` — inventario de objetos con veredicto de portabilidad
- `00-docs/10-validacion-post-migracion.md` — resultados de la validación y comparación local vs nube
- `00-docs/01-arquitectura-etl.md` — arquitectura del ETL, vigente sin cambios
- `07-migracion/` — todos los scripts de provisión, migración y validación
