# TurismoDW - Semana 3

Proyecto on-premise de Bases de Datos Avanzadas: PostgreSQL y MongoDB alimentan un modelo estrella en SQL Server 2022; Power BI lo consume mediante un endpoint de alta disponibilidad.

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
