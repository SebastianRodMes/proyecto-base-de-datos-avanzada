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

## Criterio de cierre

La entrega esta lista cuando:

- `46-validacion-consistencia.sql` devuelve `MODELO CONSISTENTE`;
- ambos nodos HA estan `SYNCHRONIZED / HEALTHY`;
- el endpoint `localhost,14330` devuelve 2,000,005 reservas;
- Power BI refresca y la pagina 6 muestra `sql-secondary / AG PRIMARY / SYNCHRONIZED`;
- las capturas se guardan en `00-docs/05-evidencias/`.
