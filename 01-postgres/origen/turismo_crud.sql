-- Escenario 8: Turismo Inteligente - CRUD y consultas (modelo en turismo_ddl.sql)
\pset border 2

-- CREATE
BEGIN;

-- Clientes
INSERT INTO cliente (identificacion, nombre, apellidos, correo, telefono, pais_origen, fecha_nacimiento) VALUES
 ('CR-101010101', 'María',   'González Rojas',  'maria.gonzalez@mail.com', '+506 8888-1111', 'Costa Rica', '1990-03-15'),
 ('ES-20304050X', 'Javier',  'Fernández Ruiz',  'javier.fernandez@mail.es','+34 611-223-344', 'España',     '1985-07-22'),
 ('US-556677889', 'Emily',   'Johnson',         'emily.johnson@mail.com',  '+1 305-555-0199', 'Estados Unidos','1993-11-02'),
 ('MX-998877665', 'Carlos',  'Ramírez López',   'carlos.ramirez@mail.mx',  '+52 55-1234-5678','México',     '1978-01-30'),
 ('CO-112233445', 'Valentina','Muñoz Herrera',  'valentina.munoz@mail.co', '+57 300-987-6543','Colombia',   '1998-06-19');

-- Preferencias de cliente
INSERT INTO preferencia_cliente (cliente_id, destinos_preferidos, tipo_alojamiento, actividades_favoritas, presupuesto_estimado, temporada_viaje, datos_adicionales) VALUES
 (1, 'Playa, Volcanes',     'Hotel 4 estrellas', 'Surf, Senderismo',        2500.00, 'Verde',  '{"idioma":"es","fumador":false,"mascotas":true}'),
 (2, 'Ciudades históricas', 'Boutique',          'Museos, Gastronomía',     4000.00, 'Alta',   '{"idioma":"es","accesibilidad":"silla_ruedas"}'),
 (3, 'Aventura, Selva',     'Ecolodge',          'Canopy, Rafting',         3200.00, 'Seca',   '{"idioma":"en","dieta":"vegetariana"}'),
 (4, 'Playa, Relax',        'Resort todo incluido','Buceo, Spa',            5000.00, 'Alta',   '{"idioma":"es","fumador":true}'),
 (5, 'Naturaleza',          'Cabaña',            'Avistamiento aves',       1800.00, 'Verde',  '{"idioma":"es","grupo":"pareja"}');

-- Hoteles
INSERT INTO hotel (nombre, categoria, direccion, ciudad, pais, servicios, capacidad_total) VALUES
 ('Hotel Vista Arenal', '4 estrellas', 'Km 5 Ruta 142',        'La Fortuna', 'Costa Rica', 'Piscina, Spa, WiFi, Restaurante', 120),
 ('Gran Hotel Colonial', '5 estrellas','Calle Mayor 12',        'Sevilla',    'España',     'WiFi, Gimnasio, Parking, Bar',    200),
 ('Ecolodge Selva Verde','Boutique',   'Sector Sarapiquí',      'Puerto Viejo','Costa Rica','Tours, Restaurante, WiFi',         40),
 ('Caribe Resort & Spa', '5 estrellas','Zona Hotelera Km 10',   'Cancún',     'México',     'Todo incluido, Playa, Spa, Buceo', 350);

-- Tipos de habitación
INSERT INTO tipo_habitacion (hotel_id, nombre, descripcion, capacidad_personas, tarifa_base, cantidad_disponible) VALUES
 (1, 'Estándar Doble',  'Habitación con vista al jardín',       2, 85.00,  30),
 (1, 'Suite Volcán',    'Suite con vista al volcán Arenal',     3, 160.00, 10),
 (2, 'Doble Superior',  'Habitación clásica reformada',         2, 140.00, 50),
 (2, 'Suite Real',      'Suite de lujo con salón',              4, 380.00, 8),
 (3, 'Bungalow Selva',  'Bungalow ecológico entre la selva',    2, 110.00, 15),
 (4, 'Junior Suite',    'Vista al mar, balcón privado',         3, 250.00, 40),
 (4, 'Villa Familiar',  'Villa con dos habitaciones y piscina', 6, 620.00, 12);

-- Tours
INSERT INTO tour (nombre, destino, descripcion, fecha_inicio, fecha_fin, duracion_horas, cupo_maximo, precio, proveedor) VALUES
 ('Canopy Arenal',        'La Fortuna', 'Recorrido de canopy sobre el bosque',   '2026-09-01','2026-12-20', 4, 20, 65.00,  'Aventuras CR'),
 ('City Tour Sevilla',    'Sevilla',    'Recorrido guiado por el casco histórico','2026-09-05','2026-11-30', 6, 30, 45.00,  'Sevilla Walks'),
 ('Rafting Sarapiquí',    'Puerto Viejo','Rafting clase III-IV',                  '2026-09-10','2026-12-15', 5, 12, 90.00,  'Río Aventura'),
 ('Buceo Arrecife Maya',  'Cancún',     'Inmersión en arrecife de coral',        '2026-09-15','2026-12-31', 3, 15, 120.00, 'Blue Diving MX'),
 ('Avistamiento de Aves', 'Sarapiquí',  'Tour matutino de observación de aves',  '2026-09-02','2026-12-10', 4, 10, 55.00,  'Eco Birds');

-- Paquetes turísticos
INSERT INTO paquete_turistico (nombre, descripcion, fecha_inicio, fecha_fin, duracion_dias, precio_total, servicios_adicionales) VALUES
 ('Aventura Volcánica CR', 'Arenal con canopy y aguas termales', '2026-10-01','2026-10-05', 5, 890.00,  'Traslados, Desayunos, Guía'),
 ('Andalucía Cultural',    'Sevilla histórica y gastronómica',   '2026-11-10','2026-11-15', 6, 1450.00, 'Traslados, Media pensión'),
 ('Caribe Todo Incluido',  'Sol, playa y buceo en Cancún',       '2026-10-20','2026-10-27', 8, 2100.00, 'Vuelos, Todo incluido'),
 ('Ecoturismo Sarapiquí',  'Selva, rafting y aves',              '2026-09-25','2026-09-29', 5, 720.00,  'Traslados, Pensión completa');

-- Hoteles por paquete
INSERT INTO paquete_hotel (paquete_id, hotel_id, noches_incluidas) VALUES
 (1, 1, 4),
 (2, 2, 5),
 (3, 4, 7),
 (4, 3, 4);

-- Tours por paquete
INSERT INTO paquete_tour (paquete_id, tour_id) VALUES
 (1, 1),
 (2, 2),
 (3, 4),
 (4, 3),
 (4, 5);

-- Reservas
INSERT INTO reserva (cliente_id, paquete_id, fecha_inicio, fecha_fin, cantidad_personas, estado, monto_total) VALUES
 (1, 1, '2026-10-01','2026-10-05', 2, 'CONFIRMADA', 1780.00),
 (2, 2, '2026-11-10','2026-11-15', 1, 'PENDIENTE',  1450.00),
 (4, 3, '2026-10-20','2026-10-27', 2, 'CONFIRMADA', 4200.00),
 (5, 4, '2026-09-25','2026-09-29', 2, 'PENDIENTE',  1440.00),
 (3, NULL,'2026-09-15','2026-09-16', 1, 'CONFIRMADA', 120.00);

-- Habitaciones por reserva
INSERT INTO reserva_habitacion (reserva_id, tipo_habitacion_id, cantidad_habitaciones, tarifa_aplicada) VALUES
 (1, 2, 1, 160.00),
 (2, 3, 1, 140.00),
 (3, 6, 1, 250.00),
 (4, 5, 1, 110.00);

-- Tours por reserva
INSERT INTO reserva_tour (reserva_id, tour_id, cantidad_personas, precio_aplicado) VALUES
 (1, 1, 2, 65.00),
 (2, 2, 1, 45.00),
 (3, 4, 2, 120.00),
 (4, 3, 2, 90.00),
 (4, 5, 2, 55.00),
 (5, 4, 1, 120.00);

-- Importaciones ETL
INSERT INTO importacion_datos (tipo_archivo, nombre_archivo, estado, registros_leidos, registros_validos, registros_rechazados, fecha_inicio, fecha_fin) VALUES
 ('CSV',  'clientes_lote1.csv', 'COMPLETADO', 100, 98, 2,  '2026-08-01 08:00','2026-08-01 08:05'),
 ('JSON', 'hoteles_seed.json',  'COMPLETADO', 20,  20, 0,  '2026-08-02 09:00','2026-08-02 09:01'),
 ('CSV',  'reservas_agosto.csv','CON_ERRORES',250, 240,10,  '2026-08-03 10:00','2026-08-03 10:12');

-- Errores de importación
INSERT INTO error_importacion (importacion_id, numero_registro, campo, regla_validacion, descripcion_error, datos_originales) VALUES
 (1, 45, 'correo',   'formato_email',   'Correo sin dominio válido',       '{"correo":"pedro@"}'),
 (1, 88, 'identificacion','no_nulo',    'Identificación vacía',            '{"identificacion":""}'),
 (3, 12, 'monto_total','numerico_positivo','Monto negativo no permitido',   '{"monto_total":"-50"}'),
 (3, 77, 'estado',   'valor_permitido', 'Estado desconocido',              '{"estado":"XYZ"}');

COMMIT;

-- READ / Consultas

-- Conteo de registros por tabla
SELECT 'cliente' AS tabla, COUNT(*) FROM cliente
UNION ALL SELECT 'preferencia_cliente', COUNT(*) FROM preferencia_cliente
UNION ALL SELECT 'hotel', COUNT(*) FROM hotel
UNION ALL SELECT 'tipo_habitacion', COUNT(*) FROM tipo_habitacion
UNION ALL SELECT 'tour', COUNT(*) FROM tour
UNION ALL SELECT 'paquete_turistico', COUNT(*) FROM paquete_turistico
UNION ALL SELECT 'paquete_hotel', COUNT(*) FROM paquete_hotel
UNION ALL SELECT 'paquete_tour', COUNT(*) FROM paquete_tour
UNION ALL SELECT 'reserva', COUNT(*) FROM reserva
UNION ALL SELECT 'reserva_habitacion', COUNT(*) FROM reserva_habitacion
UNION ALL SELECT 'reserva_tour', COUNT(*) FROM reserva_tour
UNION ALL SELECT 'importacion_datos', COUNT(*) FROM importacion_datos
UNION ALL SELECT 'error_importacion', COUNT(*) FROM error_importacion
ORDER BY tabla;

-- Listado de clientes
SELECT cliente_id, identificacion, nombre, apellidos, pais_origen, activo FROM cliente ORDER BY cliente_id;

-- Hoteles con sus tipos de habitación
SELECT h.nombre AS hotel, h.ciudad, th.nombre AS tipo_hab, th.capacidad_personas, th.tarifa_base
FROM hotel h JOIN tipo_habitacion th ON th.hotel_id = h.hotel_id
ORDER BY h.nombre, th.tarifa_base;

-- Reservas con cliente y paquete
SELECT r.reserva_id, c.nombre || ' ' || c.apellidos AS cliente,
       COALESCE(p.nombre,'(sin paquete)') AS paquete,
       r.fecha_inicio, r.fecha_fin, r.cantidad_personas, r.estado, r.monto_total
FROM reserva r
JOIN cliente c ON c.cliente_id = r.cliente_id
LEFT JOIN paquete_turistico p ON p.paquete_id = r.paquete_id
ORDER BY r.reserva_id;

-- Ingresos por estado de reserva
SELECT estado, COUNT(*) AS num_reservas, SUM(monto_total) AS ingresos_totales,
       ROUND(AVG(monto_total),2) AS ticket_promedio
FROM reserva GROUP BY estado ORDER BY ingresos_totales DESC;

-- Composición de cada paquete (hoteles y tours)
SELECT p.nombre AS paquete,
       string_agg(DISTINCT h.nombre, ', ') AS hoteles,
       string_agg(DISTINCT t.nombre, ', ') AS tours,
       p.precio_total
FROM paquete_turistico p
LEFT JOIN paquete_hotel ph ON ph.paquete_id = p.paquete_id
LEFT JOIN hotel h ON h.hotel_id = ph.hotel_id
LEFT JOIN paquete_tour pt ON pt.paquete_id = p.paquete_id
LEFT JOIN tour t ON t.tour_id = pt.tour_id
GROUP BY p.paquete_id, p.nombre, p.precio_total
ORDER BY p.nombre;

-- Ranking de tours más reservados
SELECT t.nombre AS tour, t.destino,
       COUNT(rt.reserva_tour_id) AS veces_reservado,
       SUM(rt.cantidad_personas) AS total_personas,
       SUM(rt.cantidad_personas * rt.precio_aplicado) AS ingreso_tour
FROM tour t
LEFT JOIN reserva_tour rt ON rt.tour_id = t.tour_id
GROUP BY t.tour_id, t.nombre, t.destino
ORDER BY veces_reservado DESC, ingreso_tour DESC;

-- Preferencias de cliente sobre campos JSONB
SELECT c.nombre, pc.destinos_preferidos, pc.presupuesto_estimado,
       pc.datos_adicionales->>'idioma' AS idioma,
       pc.datos_adicionales->>'dieta'  AS dieta
FROM cliente c JOIN preferencia_cliente pc ON pc.cliente_id = c.cliente_id
ORDER BY pc.presupuesto_estimado DESC;

-- Importaciones ETL y sus errores
SELECT i.nombre_archivo, i.estado, i.registros_leidos, i.registros_validos,
       i.registros_rechazados, COUNT(e.error_id) AS errores_detallados
FROM importacion_datos i
LEFT JOIN error_importacion e ON e.importacion_id = i.importacion_id
GROUP BY i.importacion_id, i.nombre_archivo, i.estado, i.registros_leidos,
         i.registros_validos, i.registros_rechazados
ORDER BY i.importacion_id;

-- UPDATE

-- Confirmar una reserva pendiente
UPDATE reserva
   SET estado = 'CONFIRMADA', fecha_actualizacion = NOW()
 WHERE reserva_id = 2;

-- Subir 10% la tarifa base de las suites
UPDATE tipo_habitacion
   SET tarifa_base = ROUND(tarifa_base * 1.10, 2)
 WHERE nombre ILIKE '%suite%';

-- Enriquecer preferencias JSONB del cliente
UPDATE preferencia_cliente
   SET datos_adicionales = datos_adicionales || '{"vip":true}'::jsonb,
       fecha_actualizacion = NOW()
 WHERE cliente_id = 1;

-- Desactivar un hotel
UPDATE hotel SET activo = FALSE WHERE nombre = 'Ecolodge Selva Verde';

-- Verificación de los UPDATE
SELECT reserva_id, estado FROM reserva WHERE reserva_id = 2;
SELECT nombre, tarifa_base FROM tipo_habitacion WHERE nombre ILIKE '%suite%' ORDER BY nombre;
SELECT cliente_id, datos_adicionales FROM preferencia_cliente WHERE cliente_id = 1;
SELECT nombre, activo FROM hotel WHERE nombre = 'Ecolodge Selva Verde';

-- DELETE

-- Borrado lógico de una reserva (cancelación)
UPDATE reserva
   SET estado = 'CANCELADA', motivo_cancelacion = 'Solicitud del cliente', fecha_actualizacion = NOW()
 WHERE reserva_id = 4;

-- Borrado físico de un error de importación
DELETE FROM error_importacion WHERE error_id = 2;

-- Borrado físico de una importación y sus errores
DELETE FROM error_importacion WHERE importacion_id = 2;
DELETE FROM importacion_datos WHERE importacion_id = 2;

-- Verificación de los DELETE
SELECT reserva_id, estado, motivo_cancelacion FROM reserva WHERE reserva_id = 4;
SELECT COUNT(*) AS errores_restantes FROM error_importacion;
SELECT importacion_id, nombre_archivo FROM importacion_datos ORDER BY importacion_id;
