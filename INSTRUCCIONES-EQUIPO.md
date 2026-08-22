# Instrucciones para el equipo

Estado consolidado al 19 de agosto de 2026.

## Checkpoints

| Checkpoint | Responsable | Estado |
|---|---|---|
| Modelo estrella y carga multifuente | Integrante 1 | Completo |
| Filegroups, particiones e indices | Integrante 2 | Completo |
| Alta disponibilidad y recuperacion | Integrante 3 | Completo en variante Always On Docker |
| Rendimiento, consistencia y documentacion | Integrante 4 | Completo salvo capturas finales de Power BI |

## Entorno validado

- Docker Desktop 29.6.2 y Compose 5.3.1.
- SQL Server 2022 Developer.
- PostgreSQL 16.
- MongoDB 7.
- Power BI Desktop 2.157.879.0.
- SSMS 22.
- `sqlcmd`, `bcp` y Python disponibles.

## Arranque

```powershell
docker compose -f docker\docker-compose.yml up -d --build
docker compose -f docker\docker-compose.yml ps -a
```

El primer arranque genera las fuentes, crea `TurismoDW` y ejecuta el ETL. El contenedor `orchestrator` debe finalizar con codigo 0; los otros tres servicios quedan activos.

## Volumen real

| Tabla | Filas |
|---|---:|
| `FactReserva` | 2,000,005 |
| `FactReservaHabitacion` | 1,632,453 |
| `FactReservaTour` | 2,577,212 |
| `FactOcupacionDiaria` | 431,313 |
| `FactResena` | 500,000 |
| `FactInteraccionWeb` | 1,500,000 |

No usar las cifras antiguas de 1,700,004 habitaciones o 2,680,006 tours: pertenecen a otra version del generador. La carga actual es determinista y esta reconciliada 22/22.

## Integrante 1

Entregables:

- scripts `40` a `46`;
- ETL en `05-etl/`;
- proyecto `06-powerbi/TurismoDW.pbip`;
- vistas `dw.vw_*`.

La recarga completa acepta 8,317,880 registros de staging, carga 8,695,473 filas de hechos/ocupacion y registra 84 rechazos esperados.

## Integrante 2

Entregables:

- `47a-medicion-testigo.sql`;
- `47b-particionamiento.sql`;
- `47c-indices-tuning.sql`.

La distribucion anual de `FactReserva` suma exactamente 2,000,005 filas. No eliminar los indices `UQ_*_Negocio`; protegen la idempotencia.

Tras una recarga, `etl.usp_VerificarIntegridad` comprime los delta stores columnstore con `COMPRESS_ALL_ROW_GROUPS` y actualiza estadisticas.

## Integrante 3

La prueba local usa:

```powershell
.\04-sqlserver\50-configurar-alwayson-docker.ps1
.\04-sqlserver\51-prueba-failover-alwayson-docker.ps1
```

Resultado registrado:

- dos replicas `SYNCHRONIZED / HEALTHY`;
- nodo inicial `caf7e3e81503`;
- nuevo principal `sql-secondary`;
- RTO 3.667 s;
- ningun KPI o checksum diferente;
- continuidad con el nodo anterior detenido;
- redundancia restaurada al final.

Los scripts `48a` a `49` permanecen como alternativa Mirroring para instancias Windows. No ejecutarlos contra los contenedores Linux.

## Integrante 4

Evidencia principal:

- `00-docs/06-informe-integrante4.md`;
- `00-docs/05-evidencias/rendimiento-int4/`;
- `00-docs/05-evidencias/validacion-consistencia.txt`;
- `00-docs/05-evidencias/alwayson-configuracion.txt`;
- `00-docs/05-evidencias/evidencia-failover.txt`;
- `00-docs/05-evidencias/powerbi-validacion-refresco.txt`.

Resumen de rendimiento final:

| Prueba | Antes | Despues |
|---|---:|---:|
| T1 | 69 ms | 3 ms |
| T2 | 44 ms | 25 ms |
| T3 | 153 ms | 54 ms |
| T4 | 707 ms | 873 ms |
| T5 | 136 ms | 76 ms |

T4 queda documentada como regresion; no presentar 5/5 mejoras.

## Power BI: ultimo paso interactivo

El PBIP ya se abrio, autentico y refresco. Una consulta DAX sobre el modelo vivo reconcilio las 16 tablas y confirmo `sql-secondary / SYNCHRONIZED`.

1. Capturar pagina 1 y pagina 6.
2. Guardar como `TurismoDW.pbix` si el profesor exige el binario.

Validacion realizada: 17 tablas, 26 relaciones, 52 medidas, 6 paginas, 55 visuales, 89 referencias correctas y 16/16 tablas sin diferencias frente a SQL Server.

## Semanas 3 y 4: migracion y operacion cloud

El enunciado `00-docs/Semana 3 y 4.docx` cambia el eje del proyecto: de alta
disponibilidad a integracion, migracion y operacion en la nube. Los scripts de
HA (`48` a `51`) se conservan como evidencia de las semanas anteriores.

| Checkpoint | Responsable | Estado |
|---|---|---|
| Estrategia y herramientas de migracion | Integrante 1 | Completo |
| Inventario de objetos a migrar | Integrante 1 | Completo |
| Carga incremental y bitacora | Integrante 1 | Completo |
| Prueba de recuperacion ante error de ETL | Integrante 1 | Completo |
| Migracion piloto y completa a AWS | Integrante 1 | Completo |
| ETL apuntando a la nube | Integrante 1 | Completo con `--solo-pg`; falta una corrida que ejercite Mongo y archivos |
| Power BI apuntando a la nube | Integrante 1 | Modelo repuntado y validado de forma estatica; **faltan las capturas del refresco real** |
| Validacion de dashboard local contra nube | Integrante 3 | **Pendiente** |
| Metricas de negocio sobre el modelo migrado | Integrante 3 | **Pendiente**, revisar si el escenario pide indicadores nuevos |
| Manual de usuario | Integrante 3 | **Pendiente** |
| Tema de investigacion: decision, documento y prototipo | Integrante 4 | **No iniciado** |
| Demostracion de la tecnologia investigada | Integrante 4 | **No iniciado** |
| Pruebas de rendimiento y recuperacion contra la nube | Integrante 4 | **Pendiente**. Ojo: `79-prueba-recuperacion-etl.ps1` tiene `localhost,1433` fijo y no lee `.env.aws` |
| Registro de calidad de datos antes/despues del ETL | Integrante 2 | **Pendiente**. El mecanismo existe (`etl.usp_ValidarStaging`, `dw.vw_CalidadDatos`); falta capturarlo |
| Verificar `43b`/`44b` y correr una incremental completa | Integrante 2 | **Pendiente** |
| Manual tecnico | Equipo | **No iniciado** |
| Video de demostracion | Equipo | **No iniciado** |
| Presentacion ejecutiva final | Equipo | **No iniciado** |

El detalle de cada pendiente, con el porque y como retomarlo, esta en
`00-docs/11-traspaso-cloud.md`.

### Resultado de la migracion

| Componente | Resultado |
|---|---|
| RDS for PostgreSQL | 11/11 tablas exactas, indice GIN sobre JSONB intacto |
| RDS for SQL Server | 8,699,504 filas, 14/14 controles, checksums identicos |
| Claves foraneas | 32/32 confiables |
| S3 | 5/5 archivos byte a byte |
| Atlas M0 | resenas completa; interacciones_web al 50 % determinista |
| ETL cloud | COMPLETADO, 19 etapas, 0 rechazos |

Detalle completo, con los seis incidentes de la ejecucion, en
`00-docs/10-validacion-post-migracion.md`.

### Lo que hay que saber antes de correr nada

**Los puertos.** Muchas maquinas del equipo tienen PostgreSQL o MongoDB
nativos escuchando en 5432, 5433 y 27017. Docker publica sobre IPv6 y el
servicio nativo ocupa IPv4, asi que una conexion a `127.0.0.1` termina
hablando con el servicio nativo **sin dar error**. En esta maquina eso hizo
que una corrida del ETL leyera 2 000 005 reservas cuando el contenedor tenia
2 000 010. Use siempre los dos archivos de compose:

```powershell
docker compose -f docker\docker-compose.yml `
               -f docker\docker-compose.override.yml up -d --build
```

PostgreSQL queda en `15432` y MongoDB en `27018`.

**Las credenciales.** Nada de AWS ni de Atlas se versiona. `70-provisionar-aws.ps1`
genera las contrasenas y las deja en `.secrets\turismodw-cloud.env`, que esta
en `.gitignore` junto con `05-etl/.env.aws`, `*_accessKeys.csv` y `*.pem`.

Consecuencia directa: **quien clone el repositorio no recibe ninguna
credencial**. Los pasos para volver a tenerlas estan en
`00-docs/11-traspaso-cloud.md`.

**El costo.** Las dos instancias RDS suman unos 0.052 USD/hora con las clases
actuales (`db.t4g.micro` mas `db.t3.small`). Al terminar cada sesion:

```powershell
.\07-migracion\78-detener-recursos.ps1
```

Quedan detenidas y solo se paga almacenamiento, unos 0.15 USD por dia. **AWS
reinicia sola una instancia detenida a los 7 dias**: si el proyecto se deja
parado mas tiempo, conviene eliminarlas con `-Eliminar`.

### Carga incremental

```powershell
cd 05-etl
python run_etl.py --modo INCREMENTAL
```

Las marcas de agua viven en `etl.Marca` y se consultan con
`etl.vw_EstadoIncremental`. Solo avanzan si la corrida termina bien: un fallo
deja la marca donde estaba para que el siguiente intento reprocese el mismo
lote en vez de saltarselo. La carga de hechos borra por clave de negocio antes
de insertar, asi que reprocesar es inofensivo.

Los catalogos pequenos (hotel, tipo_habitacion, tour y los de paquetes) se
leen completos siempre: el origen no les da columna de fecha y entre todos no
llegan a 2 000 filas.

### Scripts nuevos

| Script | Que hace |
|---|---|
| `07-migracion/70-provisionar-aws.ps1` | Crea red, S3, IAM y las dos instancias RDS |
| `07-migracion/71-inventario-objetos.ps1` | Inventario de los tres motores desde los catalogos vivos |
| `07-migracion/72-piloto-migracion.ps1` | Migracion piloto del 10 % |
| `07-migracion/73-migrar-postgres.ps1` | `pg_dump` / `pg_restore` hacia RDS |
| `07-migracion/74-migrar-mongo.ps1` | `mongodump` / `mongorestore` hacia Atlas |
| `07-migracion/74b-archivos-a-s3.ps1` | JSON y XML hacia la landing zone de S3 |
| `07-migracion/75-migrar-dw.ps1` | DDL portable mas `bcp` hacia RDS SQL Server |
| `07-migracion/76-validacion-post-migracion.sql` | Conteos, sumas y checksums |
| `07-migracion/77-comparar-local-cloud.ps1` | Integridad y rendimiento, local contra nube |
| `07-migracion/78-detener-recursos.ps1` | Detiene o elimina la infraestructura |
| `07-migracion/79-prueba-recuperacion-etl.ps1` | Prueba de recuperacion ante error de ETL |
| `07-migracion/repuntar-powerbi.ps1` | Cambia el servidor de las 16 particiones del modelo |
| `04-sqlserver/43b-carga-incremental.sql` | Tabla `etl.Marca` y sus procedimientos |
| `04-sqlserver/44b-transformacion-incremental.sql` | Carga de hechos por clave de negocio |

## Criterio de cierre

### Semanas 1 y 2, eje de alta disponibilidad (cumplido)

- `46-validacion-consistencia.sql` devuelve `MODELO CONSISTENTE`;
- ambos nodos HA estan `SYNCHRONIZED / HEALTHY`;
- el endpoint `localhost,14330` devuelve 2,000,005 reservas;
- Power BI refresca y la pagina 6 muestra `sql-secondary / AG PRIMARY / SYNCHRONIZED`;
- las capturas se guardan en `00-docs/05-evidencias/`.

> Este criterio quedo **congelado** como evidencia de las semanas 1 y 2. Los
> conteos de 2,000,005 reservas corresponden a esa carga; la prueba de carga
> incremental agrego 5 reservas de 2027 y el total vigente es 2,000,010 en
> local y 2,000,011 en la nube. No es una discrepancia: es la prueba de que la
> carga incremental funciona.

### Semanas 3 y 4, eje de migracion y operacion cloud

La entrega esta lista cuando:

- `07-migracion/76-validacion-post-migracion.sql` contra RDS devuelve
  `MIGRACION VERIFICADA`;
- `07-migracion/77-comparar-local-cloud.ps1` reporta checksums identicos en las
  14 tablas;
- una corrida `INCREMENTAL` del ETL contra la nube termina en `COMPLETADO`;
- Power BI abre el `.pbip`, **refresca contra RDS** y se guardan las capturas de
  las paginas 1 y 6;
- el tema de investigacion tiene su prototipo y su evidencia;
- existen manual tecnico, manual de usuario, video y presentacion final;
- las instancias RDS quedan detenidas.

**Lo que falta y de quien es** esta en `00-docs/11-traspaso-cloud.md`.
