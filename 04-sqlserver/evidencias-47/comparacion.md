# Comparación de rendimiento — antes vs. después (Integrante 2)

**Escenario 8: Turismo Inteligente · Particionamiento e índices**
Base `TurismoDW` con 2 000 000 de reservas, medido con `SET STATISTICS IO, TIME ON`.

## Qué se hizo

1. **Particionamiento por año** de las tablas de hechos, con clave
   `FechaInicioKey` (función `pf_TurismoAnio`, esquema `ps_TurismoAnio`,
   8 particiones repartidas en filegroups por año).
2. **Índices de tuning**: columnstore no agrupado sobre los hechos grandes
   (`NCCI_*`) e índices de cobertura rowstore (`IX_*`), todos alineados a
   las particiones.

Los índices `UQ_*_Negocio` se dejaron intactos (garantía de que el ETL no
duplica filas), y el modelo de recuperación quedó en `FULL`.

## Resultados (tiempo transcurrido de la consulta principal)

| Consulta testigo | Antes | Después | Mejora |
|---|---|---|---|
| T1 — filtro de un año concreto | 12 492 ms | ~95 ms | ~130× |
| T2 — ocupación hotelera por país y mes | 2 575 ms | ~205 ms | ~12× |
| T3 — ranking de tours más solicitados | 8 655 ms | ~269 ms | ~32× |
| T4 — perfil del visitante vs. satisfacción | 12 665 ms | 3 834 ms | ~3× |
| T5 — tendencia mensual completa | 294 ms | ~300 ms | ≈ igual (ya era mínima) |

## Distribución de las particiones (FactReserva)

| Partición | Año | Filas |
|---|---|---|
| 1 | < 2021 (colchón) | 0 |
| 2 | 2021 | 333 424 |
| 3 | 2022 | 334 078 |
| 4 | 2023 | 333 542 |
| 5 | 2024 | 334 499 |
| 6 | 2025 | 331 702 |
| 7 | 2026 | 332 755 |
| 8 | ≥ 2027 (crecimiento) | 0 |

## Lectura de los resultados

- **T1** es la que más mejora: el particionamiento permite **eliminación de
  particiones** (lee 1 de 8 en vez de recorrer los 2M), y el columnstore
  acelera la suma. De 12 s a menos de 100 ms.
- **T2, T3, T5** son consultas de agregación: el **columnstore** es el que
  hace la diferencia (lee por columnas y comprime).
- **T4** mejora menos porque su `LEFT JOIN` a `FactResena` por cliente genera
  un volumen intermedio grande; aun así baja de ~12 s a ~4 s.

Archivos de evidencia en esta carpeta: `antes.txt`, `particionamiento.txt`,
`indices.txt`, `despues.txt`.
