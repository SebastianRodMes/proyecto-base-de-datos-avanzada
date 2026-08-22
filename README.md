# TurismoDW - Semanas 3 y 4

PostgreSQL y MongoDB alimentan un modelo estrella en SQL Server 2022, consumido por Power BI. Las semanas 3 y 4 llevan esa solucion a la nube: estrategia de migracion, ETL con carga incremental y operacion sobre AWS.

> **Cambio de eje.** Las semanas 1 y 2 se construyeron alrededor de la alta disponibilidad (mirroring, Always On, failover, endpoint `localhost,14330`). El replanteamiento de las semanas 3 y 4 mueve el objetivo hacia integracion, migracion y operacion cloud. El trabajo de HA se conserva como evidencia de las semanas anteriores y sus scripts siguen en el repositorio; lo que cambia es a donde apunta el proyecto. La justificacion completa esta en [00-docs/07-estrategia-migracion.md](00-docs/07-estrategia-migracion.md).

## Migracion a la nube (Semanas 3 y 4)

| Componente | Origen on-premise | Destino AWS |
|---|---|---|
| Base operacional | PostgreSQL 16 en Docker | RDS for PostgreSQL 16, `db.t4g.micro` |
| Base NoSQL | MongoDB 7 en Docker | MongoDB Atlas M0 (capa gratuita) |
| Archivos JSON y XML | `03-archivos/entrada/` | S3, landing zone cruda |
| Almacen analitico | SQL Server 2022 Developer | RDS for SQL Server 2022 Express, `db.t3.micro` |

```powershell
# 1. Provisionar la infraestructura (crea recursos facturables)
.\07-migracion\70-provisionar-aws.ps1

# 2. Inventario de objetos a migrar, leido de los catalogos vivos
.\07-migracion\71-inventario-objetos.ps1

# 3. Migracion piloto del 10 %, que prueba las herramientas
.\07-migracion\72-piloto-migracion.ps1

# 4. Migracion completa
.\07-migracion\73-migrar-postgres.ps1
.\07-migracion\74-migrar-mongo.ps1
.\07-migracion\74b-archivos-a-s3.ps1
.\07-migracion\75-migrar-dw.ps1

# 5. Repuntar Power BI al DW migrado
.\07-migracion\repuntar-powerbi.ps1

# 6. Validar y comparar
.\07-migracion\77-comparar-local-cloud.ps1

# 7. Detener los recursos para que el costo no siga corriendo
.\07-migracion\78-detener-recursos.ps1
```

Documentos de la migracion:

| Documento | Contenido |
|---|---|
| [00-docs/07-estrategia-migracion.md](00-docs/07-estrategia-migracion.md) | Estrategia, arquitectura destino, riesgos y plan de reversion |
| [00-docs/08-matriz-herramientas.md](00-docs/08-matriz-herramientas.md) | Herramientas evaluadas y justificacion de cada eleccion |
| [00-docs/09-inventario-migracion.md](00-docs/09-inventario-migracion.md) | Inventario de objetos con veredicto de portabilidad |

## Carga incremental

El ETL admite `--modo INCREMENTAL`, que procesa solo lo que cambio desde la ultima corrida usando las marcas de agua de `etl.Marca`:

```powershell
cd 05-etl
python run_etl.py --modo FULL          # recarga completa
python run_etl.py --modo INCREMENTAL   # solo las novedades
```

Contraste medido en este laboratorio:

| Modo | Filas de staging | Duracion |
|---|---:|---:|
| `FULL` | 8 317 880 | 8 min 29 s |
| `INCREMENTAL` | 2 050 | 22 s |

Evidencia en `00-docs/05-evidencias/migracion/carga-incremental.txt` y `prueba-recuperacion-etl.txt`.

## Advertencia sobre los puertos de esta maquina

El compose original publica PostgreSQL y MongoDB en los puertos de siempre, pero muchas maquinas de desarrollo ya tienen servicios **nativos** ahi. Docker publica sobre IPv6 y el servicio nativo ocupa IPv4, de modo que una cadena con `127.0.0.1` **habla con el servicio nativo sin dar ningun error**. Paso en este proyecto: una corrida del ETL reporto 2 000 005 reservas cuando el contenedor tenia 2 000 010.

Por eso `docker/docker-compose.override.yml` los publica en puertos que no chocan, y hay que pasar los dos archivos:

```powershell
docker compose -f docker\docker-compose.yml `
               -f docker\docker-compose.override.yml up -d --build
```

| Servicio | Puerto en el host |
|---|---|
| PostgreSQL | `15432` |
| MongoDB | `27018` |
| SQL Server | `1433` |

## Resultado actual

| Componente | Estado |
|---|---|
| PostgreSQL 16 | 2,000,005 reservas cargadas |
| MongoDB 7 | 500,000 resenas y 1,500,000 interacciones |
| SQL Server 2022 Developer | `TurismoDW` poblada y particionada |
| Consistencia | 22/22 controles correctos |
| Rendimiento | 4 de 5 consultas testigo mejoran |
| Always On | 2 replicas sincronizadas y failover probado |
| Recuperacion | RTO 3.667 s, 0 diferencias en 7 controles |
| Power BI | 17 tablas, 26 relaciones, 52 medidas, 6 paginas y 55 visuales |

El informe completo del Integrante 4 esta en [00-docs/06-informe-integrante4.md](00-docs/06-informe-integrante4.md).

## Resultado de la migracion (Semana 4)

| Componente | Destino | Resultado |
|---|---|---|
| PostgreSQL | RDS for PostgreSQL 16 | 11/11 tablas exactas, suma al centimo, indice GIN sobre JSONB intacto |
| Almacen analitico | RDS for SQL Server 2022 Express | **8,699,504 filas**, 14/14 controles, **checksums identicos** |
| Claves foraneas | | 32/32 validadas y confiables |
| Particionamiento | | Distribucion identica, los 12 filegroups reproducidos |
| Archivos JSON/XML | S3 | 5/5 byte a byte |
| MongoDB | Atlas M0 | 2 colecciones migradas |
| ETL apuntando a la nube | | `COMPLETADO`, 19 etapas, 0 rechazos |
| Power BI | | 16 particiones repuntadas, 16 vistas responden |

**El hallazgo principal:** RDS for SQL Server **si acepta filegroups de usuario**, asi que los scripts `41` a `45` y `47b` migraron sin una sola modificacion. La restriccion de "solo PRIMARY" es de Azure SQL Database, no de los servicios gestionados en general.

Los resultados completos, con los seis incidentes encontrados durante la ejecucion y la comparacion de rendimiento entre los dos entornos, estan en [00-docs/10-validacion-post-migracion.md](00-docs/10-validacion-post-migracion.md).

## Puesta en marcha

Requisitos: Docker Desktop, Power BI Desktop, SSMS, `sqlcmd` y `bcp`.

```powershell
# Levanta PostgreSQL, MongoDB y SQL Server; la primera vez genera y carga todo.
docker compose -f docker\docker-compose.yml up -d --build

# Estado. El orquestador termina con codigo 0 cuando finaliza la carga.
docker compose -f docker\docker-compose.yml ps -a
```

Servicios base:

| Servicio | Direccion |
|---|---|
| SQL Server principal inicial | `localhost,1433` |
| PostgreSQL, interno a Docker | `postgres:5432` |
| MongoDB, interno a Docker | `mongo:27017` |

Credenciales SQL del laboratorio: autenticacion de base de datos, usuario `sa`, contraseña definida en `docker/docker-compose.yml`.

## Orden de scripts SQL

| Fase | Script |
|---|---|
| Base y filegroups por proposito | `40-crear-basedatos.sql` |
| Staging | `41-esquema-staging.sql` |
| Modelo estrella | `42-esquema-estrella.sql` |
| Control ETL | `43-etl-control.sql` |
| Transformacion | `44-transformacion.sql` |
| Vistas Power BI | `45-vistas-powerbi.sql` |
| Consistencia | `46-validacion-consistencia.sql` |
| Consultas testigo | `47a-medicion-testigo.sql` |
| Particionamiento anual | `47b-particionamiento.sql` |
| Indices | `47c-indices-tuning.sql` |

La primera medicion de `47a` debe ejecutarse antes de `47b` y `47c`. La comparacion final usa cinco corridas por estado y la mediana.

## Alta disponibilidad local

La alternativa reproducible en esta computadora usa Always On entre dos contenedores SQL Server 2022 Developer. El endpoint fijo del cliente es `localhost,14330`.

```powershell
# Crea certificados, endpoints, AG y replica la base real.
.\04-sqlserver\50-configurar-alwayson-docker.ps1

# Cambia de principal, repunta el endpoint, mide RTO y compara los datos.
.\04-sqlserver\51-prueba-failover-alwayson-docker.ps1
```

La topologia queda asi:

```text
Power BI --> localhost:14330 --> proxy --> SQL con rol PRIMARY
                                      +--> caf7e3e81503
                                      `--> sql-secondary
```

Es una prueba de recuperacion manual con `CLUSTER_TYPE=NONE`, adecuada para el laboratorio en una sola maquina. No se presenta como reemplazo de WSFC o Pacemaker ni como failover automatico de produccion.

Los scripts `48a` a `49` se conservan como la alternativa de Database Mirroring para instancias SQL Server sobre Windows.

## Power BI

Abrir:

```powershell
Start-Process .\06-powerbi\TurismoDW.pbip
```

Las 16 consultas M usan `localhost,14330`, por lo que un cambio de replica no modifica el PBIP. En el primer refresco seleccionar:

- autenticacion: **Base de datos**;
- usuario: `sa`;
- contraseña: la configurada para SQL Server;
- confiar en el certificado del servidor, si Power BI muestra la opcion.

La pagina 6 lee `dw.vw_EstadoSistema` y muestra el nodo actual, rol del AG, sincronizacion, ultima carga y calidad de datos.

## Validaciones reproducibles

```powershell
# Origen PostgreSQL
docker exec turismodw-postgres-1 psql -U postgres -d turismo -f /ruta/11-verificacion-origen.sql

# Consistencia DW (valores de esta carga determinista)
sqlcmd -S localhost,14330 -U sa -C -d TurismoDW `
  -i 04-sqlserver\46-validacion-consistencia.sql `
  -v ReservasOrigen=2000005 MontoOrigen=16709495659.28 `
     ResenasOrigen=500000 InteraccionesOrigen=1500000
```

## Estructura del repositorio

| Carpeta | Contenido |
|---|---|
| `00-docs/` | Arquitectura, diccionario, guia de Power BI, informe y evidencias |
| `01-postgres/` | DDL, CRUD y generador relacional |
| `02-mongodb/` | Generador y validacion NoSQL |
| `03-archivos/` | Fuentes JSON y XML |
| `04-sqlserver/` | Modelo, tuning, consistencia y alta disponibilidad |
| `05-etl/` | Orquestador ETL Python + bcp |
| `06-powerbi/` | Proyecto PBIP/TMDL/PBIR |
| `docker/` | Stack reproducible y replica HA opcional |

## Evidencia principal

- `00-docs/05-evidencias/validacion-consistencia.txt`
- `00-docs/05-evidencias/rendimiento-int4/comparacion-rendimiento.md`
- `00-docs/05-evidencias/rendimiento-int4/planes-query-store/`
- `00-docs/05-evidencias/alwayson-configuracion.txt`
- `00-docs/05-evidencias/evidencia-failover.txt`
- `00-docs/05-evidencias/validacion-post-failover.txt`
- `00-docs/05-evidencias/powerbi-validacion-estatica.txt`
