# Comparacion de rendimiento antes y despues

Fecha de ejecucion: 19 de agosto de 2026

Responsable: Integrante 4

Base evaluada: `TurismoDW` sobre SQL Server 2022 Developer en Docker

Volumen principal: 2,000,005 filas en `dw.FactReserva`

## Objetivo

Comprobar el efecto del particionamiento y los indices definidos por el Integrante 2, conservando evidencia repetible del tiempo, CPU, lecturas logicas y planes de ejecucion.

## Metodologia

1. Se ejecuto una corrida de calentamiento que no se incluyo en el calculo.
2. Se ejecutaron cinco corridas de `04-sqlserver/47a-medicion-testigo.sql` antes de aplicar los cambios.
3. Se aplicaron `04-sqlserver/47b-particionamiento.sql` y `04-sqlserver/47c-indices-tuning.sql`.
4. Se repitio una corrida de calentamiento y cinco corridas medidas.
5. Se hizo una recarga ETL completa para probar el comportamiento de los indices durante el ciclo normal de carga.
6. Se detectaron rowgroups `OPEN`, se incorporo su compresion al cierre del ETL y se ejecutaron otras cinco corridas finales.
7. Se utilizo la mediana de las cinco mediciones para reducir el efecto de variaciones puntuales del equipo.
8. Query Store se uso como segunda fuente para contrastar tiempo, CPU, lecturas y planes.
9. Al terminar se ejecuto la validacion integral del modelo; el resultado fue 22 de 22 controles correctos.

Las pruebas se realizaron en el mismo contenedor, con la misma base y el mismo volumen de datos. Por tanto, la comparacion es valida para este ambiente academico, pero no representa un benchmark de produccion.

## Resultado principal

| Consulta | Mediana antes | Mediana despues | Cambio | Aceleracion | Resultado |
|---|---:|---:|---:|---:|---|
| T1 - Reservas de un ano | 69 ms | 3 ms | 95.7% menos | 23.00x | Mejora |
| T2 - Ocupacion por pais y mes | 44 ms | 25 ms | 43.2% menos | 1.76x | Mejora |
| T3 - Ranking de tours | 153 ms | 54 ms | 64.7% menos | 2.83x | Mejora |
| T4 - Perfil y satisfaccion | 707 ms | 873 ms | 23.5% mas | 0.81x | Regresion de tiempo |
| T5 - Tendencia mensual | 136 ms | 76 ms | 44.1% menos | 1.79x | Mejora |

Cuatro de las cinco consultas redujeron su mediana de tiempo. T1 obtuvo el mayor beneficio por la eliminacion de particiones y el indice columnstore. T4 es el unico caso donde no debe afirmarse una mejora de tiempo.

## Corridas individuales

| Consulta | Antes (ms) | Despues final (ms) |
|---|---|---|
| T1 | 67, 69, 107, 64, 95 | 2, 4, 3, 3, 2 |
| T2 | 42, 44, 63, 43, 60 | 13, 26, 27, 25, 12 |
| T3 | 153, 144, 168, 143, 163 | 36, 54, 78, 55, 35 |
| T4 | 661, 635, 707, 729, 720 | 828, 892, 904, 852, 873 |
| T5 | 121, 126, 136, 177, 144 | 78, 75, 76, 73, 79 |

## Hallazgo durante la recarga ETL

| Momento | T1 | T2 | T3 | T4 | T5 |
|---|---:|---:|---:|---:|---:|
| Justo despues de crear los indices | 2 ms | 16 ms | 43 ms | 814 ms | 58 ms |
| Despues de recargar, rowgroups `OPEN` | 101 ms | 111 ms | 265 ms | 1,102 ms | 229 ms |
| Despues de comprimir, resultado final | 3 ms | 25 ms | 54 ms | 873 ms | 76 ms |

La recarga inserto menos de 1,048,576 filas por particion y dejo un delta store abierto en cada una. El indice existia, pero sus datos no estaban comprimidos. Se corrigio `etl.usp_VerificarIntegridad` para ejecutar `REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)` cuando detecta los tres indices columnstore. La evidencia `mantenimiento-columnstore.txt` muestra el cambio de `OPEN` a `COMPRESSED`.

La ejecucion ETL completa paso de 535 a 492 segundos en esta corrida, aunque la etapa de hechos aumento de 114.8 a 157.2 segundos por el mantenimiento de indices durante los `INSERT`. La duracion total tambien depende de extraccion, staging, cache y carga del equipo; por eso no se interpreta esa unica diferencia global como una mejora garantizada del ETL.

## Contraste con Query Store

Los siguientes valores son la captura de Query Store inmediatamente posterior a crear los indices: promedios de seis ejecuciones por plan, una de calentamiento y cinco medidas. Las medianas del resultado principal corresponden a la prueba final posterior a la recarga y compresion.

| Consulta | Tiempo antes/despues | CPU antes/despues | Lecturas antes/despues |
|---|---:|---:|---:|
| T1 | 78.56 / 3.46 ms | 978.00 / 3.46 ms | 27,287 / 268 |
| T2 | 50.54 / 16.08 ms | 362.83 / 16.08 ms | 4,372 / 257 |
| T3 | 160.41 / 43.70 ms | 1,730.71 / 43.69 ms | 31,811 / 2,400.67 |
| T4 | 710.54 / 869.84 ms | 9,669.97 / 8,921.58 ms | 38,994 / 10,374.67 |
| T5 | 140.16 / 60.79 ms | 1,454.93 / 60.79 ms | 27,381 / 1,662 |

T4 redujo aproximadamente 73.4% sus lecturas logicas y 7.7% su CPU promedio, pero su duracion aumento aproximadamente 22.4% en Query Store. La consulta une dos tablas de hechos por cliente y genera una expansion intermedia de filas; por ello, el indice reduce IO pero no elimina el costo estructural de la consulta ni la variabilidad del paralelismo. Para un ajuste posterior se recomienda preagregar reservas y resenas por cliente antes de combinarlas.

## Particionamiento observado

La tabla `dw.FactReserva` quedo alineada al esquema `ps_TurismoAnio` con la siguiente distribucion:

| Particion | Rango | Filas |
|---:|---|---:|
| 1 | Anterior a 2021 | 0 |
| 2 | 2021 | 333,424 |
| 3 | 2022 | 334,078 |
| 4 | 2023 | 333,542 |
| 5 | 2024 | 334,499 |
| 6 | 2025 | 331,702 |
| 7 | 2026 | 332,760 |
| 8 | 2027 en adelante | 0 |

## Evidencias relacionadas

- `antes-run1.txt` a `antes-run5.txt`: salida completa previa, con `STATISTICS IO, TIME`.
- `despues-run1.txt` a `despues-run5.txt`: salida completa posterior.
- `post-recarga-sin-compresion-run1.txt` a `run5.txt`: degradacion detectada con delta stores abiertos.
- `despues-final-run1.txt` a `run5.txt`: medicion final despues del mantenimiento.
- `particionamiento.txt`: filegroups, esquema, funcion y distribucion de filas.
- `indices.txt`: creacion y validacion de indices.
- `mantenimiento-columnstore.txt`: estados `OPEN` y `COMPRESSED` antes y despues.
- `despliegue-mantenimiento-etl.txt`: redespliegue del procedimiento corregido.
- `query-store-testigos.txt`: metricas consolidadas por consulta y plan.
- `planes-query-store/`: diez planes XML que pueden abrirse en SSMS.
- `validacion-post-tuning.txt`: resultado de consistencia posterior, 22/22 correcto.
- `validacion-post-recarga.txt`: consistencia despues de la recarga, 22/22 correcto.

## Conclusion

El cambio cumple el objetivo de acelerar los patrones analiticos principales y conserva la consistencia del modelo. No se generaliza que todas las consultas mejoran: T4 evidencia que un indice no sustituye el rediseño de una consulta con union entre hechos. Esta excepcion queda registrada como hallazgo y recomendacion de mejora.
