# ETL, integración y calidad — Integrante 2

**ITI-821 · Escenario 8: Turismo Inteligente · Semanas 3 y 4**

Este documento cierra el alcance del Integrante 2: integración de PostgreSQL
y MongoDB hacia SQL Server, carga incremental, control de cambios, manejo de
errores, bitácora y calidad antes/después del ETL, primero como diseño
reproducible y finalmente ejecutado contra la infraestructura cloud.

## 1. Implementación entregada

El flujo operativo es:

```text
RDS PostgreSQL ─┐
Atlas MongoDB ──┼─> extracción incremental ─> staging ─> validación
JSON + XML ─────┘                                      │
                                                       v
                               dimensiones + hechos en RDS SQL Server
                                                       │
                                                       v
                                  bitácora, errores y marcas de agua
```

| Componente | Responsabilidad |
|---|---|
| `05-etl/run_etl.py` | Orquesta las cuatro fuentes y solo avanza marcas tras una corrida correcta |
| `04-sqlserver/43b-carga-incremental.sql` | Tabla, procedimientos y vista de marcas de agua |
| `04-sqlserver/44b-transformacion-incremental.sql` | Borrar-e-insertar idempotente de hechos y recálculo acotado de ocupación |
| `05-etl/validar_calidad.py` | Aplica reglas de calidad antes y verifica bitácora e integridad después |
| `07-migracion/80-validar-etl-integrante2.ps1` | Ejecuta el ETL cloud y genera evidencia sin exponer secretos |

## 2. Semana 3 — calidad y prueba controlada

La validación previa del 24 de agosto de 2026 produjo:

| Fuente | Control | Resultado |
|---|---|---:|
| PostgreSQL | Clientes sin identificación | 0 |
| PostgreSQL | Correos inválidos | 0 |
| PostgreSQL | Identificaciones duplicadas | 0 |
| PostgreSQL | Reservas con monto negativo | 0 |
| PostgreSQL | Reservas con fechas incoherentes | 0 |
| PostgreSQL | Estados fuera del dominio | 0 |
| MongoDB | Reseñas fuera del rango 1–5 | 0 |
| MongoDB | Reseñas sin entidad asociada | 0 |
| MongoDB | Interacciones sin fecha | 0 |
| JSON | Identificación vacía, inyectada para probar rechazo | 44 |
| JSON | Presupuesto inválido, inyectado para probar rechazo | 38 |
| XML | Precio inválido, inyectado para probar rechazo | 2 |

Los 84 registros JSON/XML son casos controlados del generador y demuestran
que `etl.usp_ValidarStaging` rechaza datos inválidos conservando el payload
original en `etl.Error`. No son corrupción accidental.

## 3. Semana 4 — ejecución cloud

| Motor | Servicio |
|---|---|
| PostgreSQL 16 | Amazon RDS `turismodw-pg` |
| MongoDB | Atlas, base `turismo_nosql` |
| SQL Server 2022 Express | Amazon RDS `turismodw-sql` |
| Archivos JSON/XML | Cliente local, transmitidos por `bcp` al destino cloud |

Resultado definitivo, ejecución ETL **#5**:

| Métrica | Resultado |
|---|---:|
| Modo | `INCREMENTAL` |
| Estado | `COMPLETADO` |
| Etapas registradas | 23/23 completas |
| Filas leídas | 2 050 |
| Filas reemplazadas en hechos | 0, no había cambios posteriores a las marcas |
| Rechazos nuevos | 0 |
| Duración registrada | 120 s |
| Claves foráneas no confiables/deshabilitadas | 0 |

Las 2 050 filas son los catálogos pequeños de PostgreSQL que se leen
completos porque el origen no les proporciona una columna de cambio. Las
tablas y colecciones con marca devolvieron cero novedades, que es el
resultado correcto para una segunda ejecución idempotente.

| Hecho | Filas finales |
|---|---:|
| `FactReserva` | 2 000 011 |
| `FactReservaHabitacion` | 1 632 459 |
| `FactReservaTour` | 2 577 212 |
| `FactResena` | 500 002 |
| `FactInteraccionWeb` | 1 500 002 |
| `FactOcupacionDiaria` | 431 325 |

Atlas conserva el subconjunto determinista documentado durante la migración
por el límite del cluster M0. El DW mantiene la fotografía analítica completa
migrada desde SQL Server y la carga incremental aplica únicamente documentos
posteriores a la marca; no elimina el histórico que no venga en un lote.

## 4. Incidentes detectados y recuperación

### 4.1 Certificado TLS de `bcp`

Las ejecuciones #2 y #3 extrajeron correctamente las cuatro fuentes y fallaron en
`CARGAR_STG / stg.Cliente`: las herramientas actuales usan ODBC 18 y exigían
confianza explícita en el certificado de RDS. La bitácora quedó en estado
`FALLIDO`, los hechos no cambiaron y las marcas no avanzaron.

Se corrigió `config.argumentos_bcp()` para agregar `-u` cuando
`SQL_CIFRADO` está activo. La ejecución #4 reprocesó el mismo lote y terminó
`COMPLETADO`, demostrando recuperación sin pérdida de datos.

### 4.2 Marcas de agua no monotónicas

`usp_ActualizarMarca` afirmaba que una marca nunca retrocedía, pero reemplazaba
el valor sin compararlo. Un archivo local más antiguo podía reabrir una ventana
ya procesada. Se corrigió con tres garantías:

1. la marca solo cambia si el nuevo valor es mayor;
2. `43b` ahora es reejecutable sin eliminar `etl.Marca` ni su historial;
3. `FilasUltimoLote` recibe el conteo real calculado por el orquestador.

La ejecución #5 probó la corrección: aunque los `mtime` locales eran menores,
las marcas JSON/XML conservaron `1787362659.4497533` y
`1787362659.3683026`, respectivamente.

## 5. Cómo reproducir

Con RDS disponible, la IP autorizada y
`.secrets/turismodw-cloud.env` configurado:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\05-etl\requirements.txt
.\07-migracion\80-validar-etl-integrante2.ps1
```

El script no reemplaza `05-etl/.env` ni escribe credenciales en la evidencia.
Inyecta la configuración solamente a sus procesos hijos.

## 6. Evidencias

| Archivo | Contenido |
|---|---|
| `00-docs/05-evidencias/migracion/etl-integrante2-calidad.txt` | Calidad previa, ejecución #5, etapas, marcas, conteos e integridad |
| `00-docs/05-evidencias/migracion/etl-integrante2-recuperacion-tls.txt` | Ejecución fallida por TLS y etapa responsable |

Resultado final: **ETL CLOUD Y CALIDAD DEL INTEGRANTE 2 VERIFICADOS**.
