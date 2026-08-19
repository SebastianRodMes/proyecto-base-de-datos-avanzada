-- =====================================================================
-- ITI-821 | Escenario 8 | Semana 3 | Integrante 1
-- 19-limpiar-volumen.sql
--
-- Revierte 10-generador-volumen.sql y deja la base 'turismo' exactamente
-- como la dejo turismo_crud.sql (5 clientes, 5 reservas, 4 hoteles...).
-- Util para volver a generar desde cero.
--
-- Uso: psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 19-limpiar-volumen.sql
-- =====================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- Auxiliares de generacion (si una corrida fallo a medias)
DROP TABLE IF EXISTS _gen_nombre, _gen_apellido, _gen_pais, _gen_ciudad,
                     _gen_calendario, _gen_hotel_tipo, _gen_hotel_ciudad,
                     _gen_tour_ciudad, _gen_paquete_ciudad,
                     _gen_cliente_ref, _gen_paquete_ref,
                     _gen_hotel_rank, _gen_paquete_hotel_rank, _gen_pico_hotel, _gen_meta;

-- Hijos antes que padres: se respeta el orden de las claves foraneas.
DELETE FROM reserva_tour       WHERE reserva_tour_id      > 6;
DELETE FROM reserva_habitacion WHERE reserva_habitacion_id > 4;
DELETE FROM reserva            WHERE reserva_id           > 5;
DELETE FROM paquete_tour       WHERE paquete_tour_id      > 5;
DELETE FROM paquete_hotel      WHERE paquete_hotel_id     > 4;
DELETE FROM paquete_turistico  WHERE paquete_id           > 4;
DELETE FROM tipo_habitacion    WHERE tipo_habitacion_id   > 7;
DELETE FROM tour               WHERE tour_id              > 5;
DELETE FROM hotel              WHERE hotel_id             > 4;
DELETE FROM preferencia_cliente WHERE cliente_id          > 5;
DELETE FROM cliente            WHERE cliente_id           > 5;
DELETE FROM importacion_datos  WHERE importacion_id       > 3;

-- Devolver las secuencias al valor original.
SELECT setval('cliente_cliente_id_seq',                        5, true);
SELECT setval('preferencia_cliente_preferencia_id_seq',        5, true);
SELECT setval('hotel_hotel_id_seq',                            4, true);
SELECT setval('tipo_habitacion_tipo_habitacion_id_seq',        7, true);
SELECT setval('tour_tour_id_seq',                              5, true);
SELECT setval('paquete_turistico_paquete_id_seq',              4, true);
SELECT setval('paquete_hotel_paquete_hotel_id_seq',            4, true);
SELECT setval('paquete_tour_paquete_tour_id_seq',              5, true);
SELECT setval('reserva_reserva_id_seq',                        5, true);
SELECT setval('reserva_habitacion_reserva_habitacion_id_seq',  4, true);
SELECT setval('reserva_tour_reserva_tour_id_seq',              6, true);
SELECT setval('importacion_datos_importacion_id_seq',          3, true);

COMMIT;

VACUUM FULL ANALYZE;

\echo '>> Base revertida al estado de turismo_crud.sql'
