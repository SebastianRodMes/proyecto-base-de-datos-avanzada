# Informe de cierre - Integrante 4

Fecha de validacion: 19 de agosto de 2026

Proyecto: Turismo Inteligente - Semana 3

Responsable: Sergio, Integrante 4

## Estado ejecutivo

| Requerimiento | Estado | Evidencia principal |
|---|---|---|
| Base analitica y modelo estrella | Cumplido | 8 dimensiones, 6 hechos y 2 vistas operativas |
| Carga desde PostgreSQL y MongoDB | Cumplido | 8,317,880 registros leidos por ETL |
| Filegroups y particionamiento | Cumplido | 8 particiones anuales de `dw.FactReserva` |
| Indices y comparacion | Cumplido | 4 de 5 consultas mejoran; planes e IO guardados |
| Consistencia del modelo | Cumplido | 22/22 controles correctos |
| Alta disponibilidad | Cumplido para laboratorio | Always On sincronico de 2 replicas y endpoint estable |
| Prueba de falla y RTO | Cumplido | RTO 3.667 s, sin diferencias en 7 controles |
| Modelo, lienzo y refresco Power BI | Validado | 16/16 tablas reconciliadas, 52 medidas, 6 paginas y 55 visuales |
| Capturas y archivo PBIX | Requiere accion en GUI | Capturar paginas 1 y 6; guardar PBIX si lo exige el profesor |

## Arquitectura validada

```text
PostgreSQL 16 ----\
MongoDB 7 --------+--> ETL Python + bcp --> staging --> TurismoDW
JSON / XML -------/                          |            |
                                              |            +--> replica sql-secondary
                                              |                 SYNCHRONIZED
                                              |
                                              +--> dw.* + Query Store

Power BI Import --> localhost:14330 --> proxy TCP --> replica con rol PRIMARY
                                                 antes: caf7e3e81503
                                                 despues: sql-secondary
```

El SQL Server principal y la replica son SQL Server 2022 Developer en contenedores locales. El proxy de cliente conserva el mismo servidor y puerto para Power BI aunque cambie la replica primaria.

## Datos reconciliados

| Objeto | Filas |
|---|---:|
| `dw.FactReserva` | 2,000,005 |
| `dw.FactReservaHabitacion` | 1,632,453 |
| `dw.FactReservaTour` | 2,577,212 |
| `dw.FactOcupacionDiaria` | 431,313 |
| `dw.FactResena` | 500,000 |
| `dw.FactInteraccionWeb` | 1,500,000 |

Monto total reconciliado: `16,709,495,659.28`.

Registros invalidos controlados: 84 (44 `no_nulo` JSON, 38 `numerico_positivo` JSON y 2 `numerico_positivo` XML).

La salida de `46-validacion-consistencia.sql` fue `22 OK / 0 REVISAR / 0 OMITIDOS`, tanto despues del tuning como despues de una recarga completa.

## Rendimiento

Metodologia: una corrida de calentamiento, cinco corridas medidas por estado y mediana como estadistico principal.

| Consulta | Antes | Despues final | Resultado |
|---|---:|---:|---|
| T1 - Reservas de un ano | 69 ms | 3 ms | 95.7% menos |
| T2 - Ocupacion por pais y mes | 44 ms | 25 ms | 43.2% menos |
| T3 - Ranking de tours | 153 ms | 54 ms | 64.7% menos |
| T4 - Perfil y satisfaccion | 707 ms | 873 ms | 23.5% mas |
| T5 - Tendencia mensual | 136 ms | 76 ms | 44.1% menos |

T4 une `FactReserva` y `FactResena` por cliente, lo cual produce una expansion intermedia. Aunque Query Store mostro menos CPU y lecturas, el tiempo de pared aumento. Se documenta como regresion y se recomienda preagregar ambos hechos por cliente.

### Hallazgo de operacion

Una recarga completa dejo los columnstore en delta stores `OPEN` y elimino temporalmente la mejora. Se corrigio `etl.usp_VerificarIntegridad` para ejecutar de forma condicional:

```sql
ALTER INDEX ... REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
```

Despues del mantenimiento, los rowgroups quedaron `COMPRESSED` y se recupero el rendimiento. La recarga posterior al tuning duro 492 s; la inicial habia durado 535 s. Una sola diferencia global no se interpreta como garantia porque extraccion, cache y carga del equipo tambien influyen.

## Alta disponibilidad y recuperacion

La evidencia anterior del repositorio tenia cero reservas, por lo que no demostraba recuperacion de la base real. Se reemplazo por una prueba sobre los 2,000,005 registros.

Topologia probada:

- grupo `ag_TurismoDW`;
- dos replicas en `SYNCHRONOUS_COMMIT`;
- certificados para el endpoint HADR en Linux;
- `CLUSTER_TYPE=NONE` con promocion manual;
- endpoint de cliente `localhost,14330`;
- resincronizacion del nodo anterior al finalizar.

Resultado:

| Control | Antes | Despues |
|---|---:|---:|
| Nodo | `caf7e3e81503` | `sql-secondary` |
| Reservas | 2,000,005 | 2,000,005 |
| Monto total | 16,709,495,659.28 | 16,709,495,659.28 |
| Monto confirmado | 13,425,538,311.48 | 13,425,538,311.48 |
| Ocupacion | 30.1854% | 30.1854% |
| Resenas | 500,000 | 500,000 |
| Interacciones | 1,500,000 | 1,500,000 |
| Checksum de reservas | 406050629 | 406050629 |

RTO observado: **3.667 segundos**. Con el nodo anterior detenido, el endpoint siguio devolviendo todos los valores. Tras reiniciarlo se ejecuto `HADR RESUME` y regreso a `SECONDARY / SYNCHRONIZED / HEALTHY`.

Esta topologia demuestra recuperacion manual en una computadora. `CLUSTER_TYPE=NONE` no sustituye un cluster productivo con WSFC o Pacemaker y no debe presentarse como failover automatico.

## Power BI

Power BI Desktop acepto el PBIP y cargo correctamente el metamodelo:

- 17 tablas;
- 26 relaciones;
- 52 medidas DAX;
- 6 paginas;
- 55 visuales;
- 65 archivos JSON validos;
- 89 referencias de campos, 0 invalidas.

Las 16 particiones M ahora usan `Sql.Database("localhost,14330", "TurismoDW")`. `dw.vw_EstadoSistema` reconoce tanto Mirroring como Always On y muestra `AG PRIMARY`, el estado de sincronizacion y la replica asociada.

El refresco se completo y se valido directamente contra el modelo tabular vivo mediante DAX. Los conteos de las 16 tablas importadas coincidieron con SQL Server. Los principales resultados fueron:

| Control | Power BI | SQL Server |
|---|---:|---:|
| Reservas | 2,000,005 | 2,000,005 |
| Ingresos confirmados | 13,425,538,311.48 | 13,425,538,311.48 |
| Ocupacion | 30.1854251101893% | 30.1854251101893% |
| Resenas | 500,000 | 500,000 |
| Interacciones | 1,500,000 | 1,500,000 |

El mismo modelo devolvio `sql-secondary / SYNCHRONIZED`, confirmando que el dashboard refresco por el endpoint de alta disponibilidad despues del failover. La evidencia reproducible esta en `00-docs/05-evidencias/powerbi-validacion-refresco.txt`.

Para completar la evidencia visual solo falta guardar capturas de:

1. pagina 1, KPIs principales;
2. pagina 6, nodo `sql-secondary`, rol `AG PRIMARY` y estado `SYNCHRONIZED`;
3. opcionalmente guardar el entregable binario como `TurismoDW.pbix`.

## Como reproducir

```powershell
# Stack de datos y ETL
docker compose -f docker\docker-compose.yml up -d --build

# Filegroups, particionamiento e indices (despues de la linea base)
sqlcmd -S localhost,1433 -U sa -C -d TurismoDW -i 04-sqlserver\47b-particionamiento.sql
sqlcmd -S localhost,1433 -U sa -C -d TurismoDW -i 04-sqlserver\47c-indices-tuning.sql

# Always On local
.\04-sqlserver\50-configurar-alwayson-docker.ps1

# Failover y evidencia
.\04-sqlserver\51-prueba-failover-alwayson-docker.ps1

# Abrir reporte
Start-Process .\06-powerbi\TurismoDW.pbip
```

## Inventario de evidencias

- `00-docs/05-evidencias/origen-postgresql.txt`
- `00-docs/05-evidencias/origen-mongodb.txt`
- `00-docs/05-evidencias/validacion-consistencia.txt`
- `00-docs/05-evidencias/rendimiento-int4/comparacion-rendimiento.md`
- `00-docs/05-evidencias/rendimiento-int4/planes-query-store/`
- `00-docs/05-evidencias/rendimiento-int4/mantenimiento-columnstore.txt`
- `00-docs/05-evidencias/rendimiento-int4/validacion-post-recarga.txt`
- `00-docs/05-evidencias/alwayson-configuracion.txt`
- `00-docs/05-evidencias/evidencia-failover.txt`
- `00-docs/05-evidencias/validacion-post-failover.txt`
- `00-docs/05-evidencias/powerbi-validacion-estatica.txt`
