-- =====================================================================
-- ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
-- Integrante 1: Alex Herrera
-- ---------------------------------------------------------------------
-- 11-verificacion-origen.sql
--
-- Fotografia del origen relacional ANTES de correr el ETL.
--
-- Los numeros que produce este script son los valores esperados que se le
-- pasan a 04-sqlserver/46-validacion-consistencia.sql. Sin esta linea base
-- no se puede afirmar que el modelo analitico quedo completo: solo se
-- sabria cuantas filas tiene el DW, no cuantas debia tener.
--
-- Uso:
--   psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 11-verificacion-origen.sql
-- =====================================================================

\pset border 2
\pset numericlocale on

\echo ''
\echo '=== 1. Conteo de filas por tabla ==='

SELECT 'cliente'             AS tabla, COUNT(*) AS filas FROM cliente
UNION ALL SELECT 'preferencia_cliente', COUNT(*) FROM preferencia_cliente
UNION ALL SELECT 'hotel',               COUNT(*) FROM hotel
UNION ALL SELECT 'tipo_habitacion',     COUNT(*) FROM tipo_habitacion
UNION ALL SELECT 'tour',                COUNT(*) FROM tour
UNION ALL SELECT 'paquete_turistico',   COUNT(*) FROM paquete_turistico
UNION ALL SELECT 'paquete_hotel',       COUNT(*) FROM paquete_hotel
UNION ALL SELECT 'paquete_tour',        COUNT(*) FROM paquete_tour
UNION ALL SELECT 'reserva',             COUNT(*) FROM reserva
UNION ALL SELECT 'reserva_habitacion',  COUNT(*) FROM reserva_habitacion
UNION ALL SELECT 'reserva_tour',        COUNT(*) FROM reserva_tour
UNION ALL SELECT 'importacion_datos',   COUNT(*) FROM importacion_datos
UNION ALL SELECT 'error_importacion',   COUNT(*) FROM error_importacion
ORDER BY tabla;

\echo ''
\echo '=== 2. Totales monetarios (valores esperados para el DW) ==='

SELECT
    COUNT(*)                                    AS reservas_totales,
    ROUND(SUM(monto_total), 2)                  AS suma_monto_total,
    ROUND(AVG(monto_total), 2)                  AS ticket_promedio,
    ROUND(SUM(monto_total) FILTER (WHERE estado = 'CONFIRMADA'), 2)
                                                AS ingresos_confirmados,
    MIN(fecha_inicio)                           AS primera_fecha,
    MAX(fecha_inicio)                           AS ultima_fecha
FROM reserva;

\echo ''
\echo '=== 3. Distribucion por estado ==='

SELECT
    estado,
    COUNT(*)                                                  AS reservas,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)        AS porcentaje,
    ROUND(SUM(monto_total), 2)                                AS monto
FROM reserva
GROUP BY estado
ORDER BY reservas DESC;

\echo ''
\echo '=== 4. Estacionalidad: reservas por anio y mes de inicio ==='

SELECT
    EXTRACT(YEAR  FROM fecha_inicio)::int AS anio,
    EXTRACT(MONTH FROM fecha_inicio)::int AS mes,
    COUNT(*)                              AS reservas
FROM reserva
GROUP BY 1, 2
ORDER BY 1, 2;

\echo ''
\echo '=== 5. Promedio de estadia y anticipacion ==='

SELECT
    ROUND(AVG(fecha_fin - fecha_inicio), 2)                     AS noches_promedio,
    ROUND(AVG(fecha_inicio - fecha_reserva::date), 2)           AS dias_anticipacion_promedio,
    ROUND(AVG(cantidad_personas), 2)                            AS personas_promedio
FROM reserva;

\echo ''
\echo '=== 6. Integridad referencial: no debe haber huerfanos ==='

SELECT 'reserva sin cliente' AS prueba, COUNT(*) AS filas
  FROM reserva r LEFT JOIN cliente c USING (cliente_id) WHERE c.cliente_id IS NULL
UNION ALL
SELECT 'reserva_habitacion sin reserva', COUNT(*)
  FROM reserva_habitacion rh LEFT JOIN reserva r USING (reserva_id) WHERE r.reserva_id IS NULL
UNION ALL
SELECT 'reserva_habitacion sin tipo_habitacion', COUNT(*)
  FROM reserva_habitacion rh LEFT JOIN tipo_habitacion th USING (tipo_habitacion_id)
 WHERE th.tipo_habitacion_id IS NULL
UNION ALL
SELECT 'reserva_tour sin tour', COUNT(*)
  FROM reserva_tour rt LEFT JOIN tour t USING (tour_id) WHERE t.tour_id IS NULL
UNION ALL
SELECT 'paquete sin hotel asociado', COUNT(*)
  FROM paquete_turistico p LEFT JOIN paquete_hotel ph USING (paquete_id)
 WHERE ph.paquete_id IS NULL
UNION ALL
SELECT 'fecha_fin anterior a fecha_inicio', COUNT(*)
  FROM reserva WHERE fecha_fin < fecha_inicio;

\echo ''
\echo '=== 7. Catalogo turistico ==='

SELECT
    (SELECT COUNT(*) FROM hotel)                          AS hoteles,
    (SELECT COUNT(*) FROM hotel WHERE activo)             AS hoteles_activos,
    (SELECT COUNT(DISTINCT ciudad) FROM hotel)            AS ciudades,
    (SELECT COUNT(DISTINCT pais)   FROM hotel)            AS paises,
    (SELECT SUM(cantidad_disponible) FROM tipo_habitacion WHERE activo)
                                                          AS habitaciones_publicadas,
    (SELECT COUNT(*) FROM tour)                           AS tours,
    (SELECT COUNT(*) FROM paquete_turistico)              AS paquetes;

\echo ''
\echo '=== 8. Tamano de la base y de las tablas mayores ==='

SELECT pg_size_pretty(pg_database_size(current_database())) AS tamano_base;

SELECT
    relname                                        AS tabla,
    to_char(n_live_tup, 'FM999G999G999')           AS filas_estimadas,
    pg_size_pretty(pg_total_relation_size(relid))  AS tamano_total
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 8;

\echo ''
\echo '=== 9. Valores para 46-validacion-consistencia.sql ==='
\echo 'Copie estos numeros al ejecutar la validacion en SQL Server:'

SELECT
    'sqlcmd -S TURISMODW -E -C -d TurismoDW -i 46-validacion-consistencia.sql -v ReservasOrigen='
    || (SELECT COUNT(*) FROM reserva)
    || ' MontoOrigen=' || (SELECT ROUND(SUM(monto_total), 2) FROM reserva)
    AS comando_sugerido;
