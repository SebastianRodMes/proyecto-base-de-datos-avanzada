-- =====================================================================
-- ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
-- Semana 3 | Integrante 1: Alex Herrera
-- ---------------------------------------------------------------------
-- 10-generador-volumen.sql
--
-- Escala la base operacional 'turismo' a volumen productivo para que el
-- particionamiento y los indices del Integrante 2 muestren diferencias
-- medibles, y para que el modelo analitico tenga masa critica.
--
-- Volumen objetivo:
--     cliente               ~   50 000
--     preferencia_cliente   ~   50 000
--     hotel                 ~      200
--     tipo_habitacion       ~      800
--     tour                  ~      400
--     paquete_turistico     ~      150
--     reserva               ~2 000 000   (2021-01-01 .. 2026-12-31)
--     reserva_habitacion    ~1 700 000
--     reserva_tour          ~3 000 000
--
-- Los datos originales de turismo_crud.sql se conservan intactos: todo lo
-- generado se agrega a partir de los IDs existentes.
--
-- Uso:  psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 10-generador-volumen.sql
-- Tiempo aproximado: 5-10 minutos.
-- =====================================================================

\timing on
\set ON_ERROR_STOP on

-- Semilla fija: la generacion es reproducible entre corridas y entre equipos.
SELECT setseed(0.8218);

-- ---------------------------------------------------------------------
-- 0. Guarda de re-ejecucion
-- ---------------------------------------------------------------------
DO $guard$
BEGIN
    IF (SELECT COUNT(*) FROM reserva) > 1000 THEN
        RAISE EXCEPTION
          'La base ya contiene % reservas. Para regenerar ejecute antes 19-limpiar-volumen.sql',
          (SELECT COUNT(*) FROM reserva);
    END IF;
END
$guard$;

-- ---------------------------------------------------------------------
-- 1. Quitar indices de apoyo (se recrean al final, mucho mas barato)
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS idx_reserva_cliente;
DROP INDEX IF EXISTS idx_reserva_fechas;
DROP INDEX IF EXISTS idx_pref_gin;

-- ---------------------------------------------------------------------
-- 2. Catalogos de apoyo para la generacion
-- ---------------------------------------------------------------------
-- Se eliminan primero por si una corrida anterior fallo a medias.
DROP TABLE IF EXISTS _gen_nombre, _gen_apellido, _gen_pais, _gen_ciudad,
                     _gen_calendario, _gen_hotel_tipo, _gen_hotel_ciudad,
                     _gen_tour_ciudad, _gen_paquete_ciudad,
                     _gen_cliente_ref, _gen_paquete_ref,
                     _gen_hotel_rank, _gen_paquete_hotel_rank, _gen_pico_hotel;

CREATE TABLE _gen_nombre (id int PRIMARY KEY, valor text);
INSERT INTO _gen_nombre (id, valor)
SELECT row_number() OVER (), v FROM unnest(ARRAY[
 'Maria','Jose','Carlos','Ana','Luis','Laura','Diego','Sofia','Andres','Valeria',
 'Javier','Camila','Roberto','Daniela','Fernando','Gabriela','Ricardo','Natalia',
 'Emily','Michael','Jennifer','David','Sarah','James','Emma','Robert','Olivia',
 'Sebastian','Isabella','Mateo','Lucia','Alejandro','Paula','Esteban','Mariana',
 'Rodrigo','Adriana','Felipe','Carolina','Ignacio','Renata','Tomas','Antonella',
 'Pablo','Elena','Martin','Julia','Nicolas','Victoria','Samuel'
]) v;

CREATE TABLE _gen_apellido (id int PRIMARY KEY, valor text);
INSERT INTO _gen_apellido (id, valor)
SELECT row_number() OVER (), v FROM unnest(ARRAY[
 'Gonzalez','Rodriguez','Fernandez','Lopez','Martinez','Sanchez','Perez','Gomez',
 'Ramirez','Torres','Flores','Rivera','Herrera','Jimenez','Vargas','Castillo',
 'Morales','Ortiz','Rojas','Mendez','Chaves','Solano','Araya','Quesada','Murillo',
 'Mesen','Alvarado','Brenes','Ugalde','Zuniga','Johnson','Smith','Williams',
 'Brown','Jones','Miller','Davis','Wilson','Anderson','Taylor','Muller','Schmidt',
 'Dubois','Rossi','Ferrari','Silva','Santos','Oliveira','Costa','Pereira'
]) v;

CREATE TABLE _gen_pais (id int PRIMARY KEY, pais text);
INSERT INTO _gen_pais (id, pais)
SELECT row_number() OVER (), p FROM unnest(ARRAY[
 'Costa Rica','Costa Rica','Costa Rica','Estados Unidos','Estados Unidos',
 'Espana','Espana','Mexico','Mexico','Colombia','Canada','Alemania',
 'Argentina','Chile','Francia','Reino Unido','Costa Rica','Estados Unidos',
 'Mexico','Espana'
]) p;

-- Ciudad y pais del catalogo turistico. El identificador de ciudad se guarda
-- aparte del nombre para no depender de parsear cadenas mas adelante.
CREATE TABLE _gen_ciudad (id int PRIMARY KEY, ciudad text, pais text);
INSERT INTO _gen_ciudad (id, ciudad, pais)
SELECT row_number() OVER (), c, p FROM (VALUES
 ('La Fortuna','Costa Rica'),('Manuel Antonio','Costa Rica'),('Tamarindo','Costa Rica'),
 ('Monteverde','Costa Rica'),('Puerto Viejo','Costa Rica'),('San Jose','Costa Rica'),
 ('Jaco','Costa Rica'),('Samara','Costa Rica'),('Nosara','Costa Rica'),('Tortuguero','Costa Rica'),
 ('Sevilla','Espana'),('Barcelona','Espana'),('Madrid','Espana'),('Granada','Espana'),
 ('Valencia','Espana'),('Malaga','Espana'),
 ('Cancun','Mexico'),('Tulum','Mexico'),('Playa del Carmen','Mexico'),('Oaxaca','Mexico'),
 ('Ciudad de Mexico','Mexico'),('Puerto Vallarta','Mexico'),
 ('Cartagena','Colombia'),('Santa Marta','Colombia'),('Medellin','Colombia'),('Bogota','Colombia'),
 ('Miami','Estados Unidos'),('Orlando','Estados Unidos'),('San Diego','Estados Unidos'),
 ('Nueva Orleans','Estados Unidos')
) t(c,p);

-- Calendario ponderado: los dias de temporada alta se repiten mas veces, de modo
-- que un muestreo uniforme sobre esta tabla reproduce la estacionalidad turistica
-- (picos en diciembre-enero y julio, valle en septiembre-octubre).
CREATE TABLE _gen_calendario (idx int PRIMARY KEY, fecha date);
INSERT INTO _gen_calendario (idx, fecha)
SELECT row_number() OVER (), d::date
FROM generate_series(DATE '2021-01-01', DATE '2026-12-31', INTERVAL '1 day') g(d)
CROSS JOIN LATERAL generate_series(1,
        CASE EXTRACT(MONTH FROM d)::int
             WHEN 12 THEN 5 WHEN  1 THEN 5 WHEN  7 THEN 4
             WHEN  2 THEN 3 WHEN  3 THEN 3 WHEN  6 THEN 3 WHEN  8 THEN 3
             WHEN 11 THEN 2 WHEN  4 THEN 2
             ELSE 1
        END) rep;

-- Ciudad asignada a cada hotel / tour / paquete generado, para que el paquete
-- quede anclado a un hotel de su misma ciudad sin parsear el nombre.
CREATE TABLE _gen_hotel_ciudad  (hotel_id bigint PRIMARY KEY, ciudad_id int);
CREATE TABLE _gen_tour_ciudad   (tour_id  bigint PRIMARY KEY, ciudad_id int);
CREATE TABLE _gen_paquete_ciudad(paquete_id bigint PRIMARY KEY, ciudad_id int);

-- ---------------------------------------------------------------------
-- 3. Dimension operacional: clientes y preferencias
-- ---------------------------------------------------------------------
\echo '>> Generando 50 000 clientes...'

INSERT INTO cliente (identificacion, nombre, apellidos, correo, telefono,
                     pais_origen, fecha_nacimiento, activo, fecha_registro)
SELECT
    'ID-' || lpad(g::text, 9, '0'),
    n.valor,
    a1.valor || ' ' || a2.valor,
    lower(n.valor) || '.' || lower(a1.valor) || g || '@mail.com',
    '+' || (1 + (g % 90))::text || ' ' || lpad((g % 100000000)::text, 8, '0'),
    p.pais,
    -- g se promueve a bigint: 50 000 * 104 729 desborda el rango de integer.
    DATE '1955-01-01' + ((g::bigint * 7919) % 16800)::int,
    (g % 25) <> 0,                                   -- ~4 % inactivos
    TIMESTAMP '2020-06-01' + ((g::bigint * 104729) % 2200) * INTERVAL '1 day'
                           + ((g::bigint * 37) % 86400) * INTERVAL '1 second'
FROM generate_series(1, 50000) g
JOIN _gen_nombre   n  ON n.id  = 1 + (g * 13) % 50
JOIN _gen_apellido a1 ON a1.id = 1 + (g * 29) % 50
JOIN _gen_apellido a2 ON a2.id = 1 + (g * 47) % 50
JOIN _gen_pais     p  ON p.id  = 1 + (g * 17) % 20;

\echo '>> Generando preferencias (JSONB)...'

INSERT INTO preferencia_cliente (cliente_id, destinos_preferidos, tipo_alojamiento,
        actividades_favoritas, presupuesto_estimado, temporada_viaje,
        datos_adicionales, fecha_actualizacion)
SELECT
    c.cliente_id,
    (ARRAY['Playa, Volcanes','Ciudades historicas','Aventura, Selva','Playa, Relax',
           'Naturaleza','Montana, Cafe','Islas, Buceo','Cultura, Gastronomia'
          ])[1 + (c.cliente_id % 8)],
    (ARRAY['Hotel 3 estrellas','Hotel 4 estrellas','Hotel 5 estrellas','Boutique',
           'Ecolodge','Resort todo incluido','Cabana','Hostal'
          ])[1 + (c.cliente_id % 8)],
    (ARRAY['Surf, Senderismo','Museos, Gastronomia','Canopy, Rafting','Buceo, Spa',
           'Avistamiento aves','Tour cafe, Cabalgata','Kayak, Snorkel','Fotografia, Trekking'
          ])[1 + (c.cliente_id % 8)],
    ROUND((800 + (c.cliente_id * 331) % 6200)::numeric, 2),
    (ARRAY['Alta','Verde','Seca','Media'])[1 + (c.cliente_id % 4)],
    jsonb_build_object(
        'idioma',   (ARRAY['es','en','de','fr','pt'])[1 + (c.cliente_id % 5)],
        'fumador',  (c.cliente_id % 7) = 0,
        'mascotas', (c.cliente_id % 11) = 0,
        'dieta',    (ARRAY['ninguna','vegetariana','vegana','sin_gluten'])[1 + (c.cliente_id % 4)],
        'grupo',    (ARRAY['solo','pareja','familia','amigos'])[1 + (c.cliente_id % 4)],
        'vip',      (c.cliente_id % 97) = 0
    ),
    c.fecha_registro + INTERVAL '30 days'
FROM cliente c
WHERE c.cliente_id > 5;

-- ---------------------------------------------------------------------
-- 4. Catalogo turistico: hoteles, habitaciones, tours y paquetes
-- ---------------------------------------------------------------------
\echo '>> Generando 196 hoteles y sus tipos de habitacion...'

WITH nuevos AS (
    INSERT INTO hotel (nombre, categoria, direccion, ciudad, pais, servicios,
                       capacidad_total, activo)
    SELECT
        (ARRAY['Hotel','Gran Hotel','Resort','Ecolodge','Villa','Posada','Suites',
               'Boutique Hotel'])[1 + (g % 8)] || ' ' ||
        (ARRAY['Vista','Bahia','Palma','Colonial','Sol','Coral','Verde','Real',
               'Mirador','Laguna'])[1 + (g % 10)] || ' ' || ci.ciudad,
        (ARRAY['3 estrellas','4 estrellas','5 estrellas','Boutique'])[1 + (g % 4)],
        'Calle ' || (1 + g % 200) || ', sector ' || (1 + g % 12),
        ci.ciudad,
        ci.pais,
        (ARRAY['Piscina, Spa, WiFi, Restaurante','WiFi, Gimnasio, Parking, Bar',
               'Todo incluido, Playa, Spa, Buceo','Tours, Restaurante, WiFi',
               'Piscina, Playa, Bar, Kids club','WiFi, Desayuno, Parking'
              ])[1 + (g % 6)],
        40 + (g * 17) % 400,
        (g % 33) <> 0
    FROM generate_series(1, 196) g
    JOIN _gen_ciudad ci ON ci.id = 1 + (g % 30)
    RETURNING hotel_id, ciudad
)
INSERT INTO _gen_hotel_ciudad (hotel_id, ciudad_id)
SELECT n.hotel_id, ci.id FROM nuevos n JOIN _gen_ciudad ci ON ci.ciudad = n.ciudad;

-- Los 4 hoteles originales tambien necesitan ciudad para el anclaje de paquetes.
INSERT INTO _gen_hotel_ciudad (hotel_id, ciudad_id)
SELECT h.hotel_id, COALESCE(ci.id, 1)
FROM hotel h
LEFT JOIN _gen_ciudad ci ON ci.ciudad = h.ciudad
WHERE h.hotel_id <= 4
ON CONFLICT DO NOTHING;

INSERT INTO tipo_habitacion (hotel_id, nombre, descripcion, capacidad_personas,
                             tarifa_base, cantidad_disponible, activo)
SELECT
    h.hotel_id,
    t.nombre,
    t.nombre || ' en ' || h.nombre,
    t.cap,
    ROUND((t.base * CASE h.categoria
                        WHEN '5 estrellas' THEN 2.2
                        WHEN '4 estrellas' THEN 1.5
                        WHEN 'Boutique'    THEN 1.8
                        ELSE 1.0 END)::numeric, 2),
    -- Banda estrecha de capacidad: 30 a 55 habitaciones por tipo, o sea 126 a
    -- 214 por hotel. Una banda amplia (5 a 49, que fue el primer intento) hace
    -- que la capacidad varie 10 veces entre hoteles mientras la demanda se
    -- reparte de forma uniforme; el resultado es que los hoteles chicos quedan
    -- al 300 % de ocupacion y los grandes al 3 %. La ocupacion es el KPI
    -- principal del escenario, asi que la capacidad tiene que ser coherente
    -- con la demanda que el generador produce.
    30 + (h.hotel_id * 7 + t.orden) % 26,
    TRUE
FROM hotel h
CROSS JOIN (VALUES
    (1,'Estandar Doble',   2,  70.00),
    (2,'Superior Vista',   2,  95.00),
    (3,'Junior Suite',     3, 150.00),
    (4,'Villa Familiar',   6, 260.00)
) t(orden, nombre, cap, base)
WHERE h.hotel_id > 4;

\echo '>> Generando 395 tours...'

WITH nuevos AS (
    INSERT INTO tour (nombre, destino, descripcion, fecha_inicio, fecha_fin,
                      duracion_horas, cupo_maximo, precio, proveedor, activo)
    SELECT
        (ARRAY['Canopy','City Tour','Rafting','Buceo','Avistamiento de Aves',
               'Tour de Cafe','Kayak','Snorkel','Trekking Volcanico',
               'Safari Fotografico','Cabalgata','Tour Gastronomico'
              ])[1 + (g % 12)] || ' ' || ci.ciudad,
        ci.ciudad,
        'Experiencia guiada en ' || ci.ciudad || ', ' || ci.pais,
        DATE '2021-01-01',
        DATE '2026-12-31',
        2 + (g % 10),
        8 + (g * 3) % 40,
        ROUND((35 + (g * 137) % 220)::numeric, 2),
        (ARRAY['Aventuras CR','Sevilla Walks','Rio Aventura','Blue Diving MX',
               'Eco Birds','Andes Travel','Caribe Tours','Pacific Adventures'
              ])[1 + (g % 8)],
        (g % 29) <> 0
    FROM generate_series(1, 395) g
    JOIN _gen_ciudad ci ON ci.id = 1 + (g % 30)
    RETURNING tour_id, destino
)
INSERT INTO _gen_tour_ciudad (tour_id, ciudad_id)
SELECT n.tour_id, ci.id FROM nuevos n JOIN _gen_ciudad ci ON ci.ciudad = n.destino;

\echo '>> Generando 146 paquetes turisticos...'

WITH nuevos AS (
    INSERT INTO paquete_turistico (nombre, descripcion, fecha_inicio, fecha_fin,
            duracion_dias, precio_total, servicios_adicionales, activo)
    SELECT
        (ARRAY['Aventura','Descanso','Cultural','Ecoturismo','Familiar',
               'Luna de Miel','Premium','Express'])[1 + (g % 8)] || ' ' || ci.ciudad,
        'Paquete con alojamiento, tours y traslados en ' || ci.ciudad,
        DATE '2021-01-01',
        DATE '2026-12-31',
        3 + (g % 10),
        ROUND((250 + (3 + (g % 10)) * (120 + (g * 53) % 260))::numeric, 2),
        (ARRAY['Traslados, Desayunos, Guia','Traslados, Media pension',
               'Vuelos, Todo incluido','Traslados, Pension completa',
               'Desayunos, Seguro de viaje'])[1 + (g % 5)],
        (g % 23) <> 0
    FROM generate_series(1, 146) g
    JOIN _gen_ciudad ci ON ci.id = 1 + (g % 30)
    RETURNING paquete_id, descripcion
)
INSERT INTO _gen_paquete_ciudad (paquete_id, ciudad_id)
SELECT n.paquete_id, ci.id
FROM nuevos n
JOIN _gen_ciudad ci ON n.descripcion = 'Paquete con alojamiento, tours y traslados en ' || ci.ciudad;

-- Hoteles numerados densamente dentro de cada ciudad. Sin esta numeracion
-- no hay forma barata de repartir los paquetes entre TODOS los hoteles de
-- una ciudad: una eleccion por aritmetica modular sobre hotel_id colapsa
-- casi siempre en el mismo hotel, y el resultado es que el 80 % de los
-- hoteles nunca recibe una reserva y el 20 % restante queda sobrevendido
-- (se midio 255 % de ocupacion, fisicamente imposible).
-- Se excluyen los 4 hoteles originales de turismo_crud.sql: tienen capacidades
-- muy pequenas (8 a 50 habitaciones) definidas a mano en la semana 1, y si
-- entran al reparto absorben demanda sintetica que no pueden alojar. Se
-- conservan intactos con sus 5 reservas originales, que es el objetivo.
CREATE TABLE _gen_hotel_rank AS
SELECT hc.ciudad_id,
       hc.hotel_id,
       (row_number() OVER (PARTITION BY hc.ciudad_id ORDER BY hc.hotel_id) - 1)::int AS rn,
       COUNT(*)     OVER (PARTITION BY hc.ciudad_id)::int                            AS n_hoteles
FROM _gen_hotel_ciudad hc
WHERE hc.hotel_id > 4;
CREATE INDEX ON _gen_hotel_rank (ciudad_id, rn);
ANALYZE _gen_hotel_rank;

-- Cada paquete agrupa hasta 3 hoteles de su ciudad, que es como funciona un
-- paquete real: el mayorista negocia cupo en varios hoteles y ubica al
-- visitante segun disponibilidad.
INSERT INTO paquete_hotel (paquete_id, hotel_id, noches_incluidas)
SELECT DISTINCT ON (p.paquete_id, hr.hotel_id)
       p.paquete_id, hr.hotel_id, GREATEST(1, p.duracion_dias - 1)
FROM paquete_turistico p
JOIN _gen_paquete_ciudad pc ON pc.paquete_id = p.paquete_id
CROSS JOIN generate_series(0, 2) k
JOIN _gen_hotel_rank hr ON hr.ciudad_id = pc.ciudad_id
                       AND hr.rn = (p.paquete_id + k * 7) % hr.n_hoteles
WHERE p.paquete_id > 4;

-- Red de seguridad: cualquier paquete sin hotel recibe uno arbitrario.
INSERT INTO paquete_hotel (paquete_id, hotel_id, noches_incluidas)
SELECT p.paquete_id,
       (SELECT hotel_id FROM hotel ORDER BY hotel_id OFFSET (p.paquete_id % 100) LIMIT 1),
       GREATEST(1, p.duracion_dias - 1)
FROM paquete_turistico p
WHERE p.paquete_id > 4
  AND NOT EXISTS (SELECT 1 FROM paquete_hotel ph WHERE ph.paquete_id = p.paquete_id);

-- Entre 1 y 3 tours por paquete, preferentemente de la misma ciudad.
INSERT INTO paquete_tour (paquete_id, tour_id)
SELECT DISTINCT p.paquete_id, t.tour_id
FROM paquete_turistico p
JOIN _gen_paquete_ciudad pc ON pc.paquete_id = p.paquete_id
CROSS JOIN generate_series(1, 3) s(k)
JOIN LATERAL (
    SELECT tc.tour_id
    FROM _gen_tour_ciudad tc
    WHERE tc.ciudad_id = pc.ciudad_id
    ORDER BY (tc.tour_id * 13 + p.paquete_id * s.k) % 97
    LIMIT 1
) t ON TRUE
WHERE p.paquete_id > 4
  AND (p.paquete_id + s.k) % 4 <> 0;

-- ---------------------------------------------------------------------
-- 5. Hechos operacionales: 2 000 000 de reservas por bloques
-- ---------------------------------------------------------------------
\echo '>> Generando 2 000 000 de reservas (8 bloques de 250 000)...'

-- Los IDs reales no son densos (las secuencias avanzan aunque una insercion
-- falle), asi que no se puede derivar un cliente_id valido con aritmetica
-- modular sobre el conteo. Se materializa la lista real de IDs y se indexa
-- por un correlativo denso; el muestreo usa ese correlativo.
CREATE TABLE _gen_cliente_ref AS
SELECT row_number() OVER (ORDER BY cliente_id) AS rn, cliente_id FROM cliente;
ALTER TABLE _gen_cliente_ref ADD PRIMARY KEY (rn);

-- Los paquetes NO se venden todos por igual. Si se muestrea uniforme sobre
-- los 150, cada ciudad termina con exactamente la misma cantidad de reservas
-- y el ranking de destinos del dashboard se ve obviamente sintetico: diez
-- destinos con 80 000 reservas clavadas.
--
-- El pool repite cada paquete segun su popularidad (1 a 9 veces), asi que un
-- muestreo uniforme sobre el pool produce una curva de demanda realista, con
-- destinos lideres y destinos de nicho.
--
-- Esto cambia la demanda por hotel, pero no rompe el KPI de ocupacion: la
-- capacidad se dimensiona despues, en el paso 6b, a partir de la demanda que
-- realmente haya quedado.
CREATE TABLE _gen_paquete_ref AS
SELECT row_number() OVER () AS rn, p.paquete_id, p.precio_total
FROM paquete_turistico p
CROSS JOIN LATERAL generate_series(1, 1 + (p.paquete_id * 7919) % 9) rep;
ALTER TABLE _gen_paquete_ref ADD PRIMARY KEY (rn);

ANALYZE _gen_cliente_ref;
ANALYZE _gen_paquete_ref;

DO $carga$
DECLARE
    v_total       bigint := 2000000;
    v_bloque      bigint := 250000;
    v_b           bigint;
    v_n_cal       int;
    v_n_clientes  bigint;
    v_n_paquetes  bigint;
    v_ini         timestamp := clock_timestamp();
BEGIN
    SELECT COUNT(*) FROM _gen_calendario   INTO v_n_cal;
    SELECT COUNT(*) FROM _gen_cliente_ref  INTO v_n_clientes;
    SELECT COUNT(*) FROM _gen_paquete_ref  INTO v_n_paquetes;

    FOR v_b IN 0 .. (v_total / v_bloque) - 1 LOOP

        INSERT INTO reserva (cliente_id, paquete_id, fecha_reserva, fecha_inicio,
                fecha_fin, cantidad_personas, estado, monto_total,
                motivo_cancelacion, fecha_actualizacion)
        SELECT
            cr.cliente_id,
            pr.paquete_id,
            (c.fecha - b.anticipacion) + (b.i % 86400) * INTERVAL '1 second',
            c.fecha,
            c.fecha + b.noches,
            b.personas,
            b.estado,
            ROUND(GREATEST(60,
                  COALESCE(pr.precio_total, 90 + (b.i % 400))
                  * b.personas * (0.80 + (b.i % 45) / 100.0))::numeric, 2),
            CASE WHEN b.estado = 'CANCELADA' THEN
                 (ARRAY['Solicitud del cliente','Cambio de itinerario',
                        'Pago no confirmado','Fuerza mayor',
                        'Sobreventa del proveedor'])[1 + (b.i % 5)]
            END,
            (c.fecha - b.anticipacion) + INTERVAL '1 day'
        FROM (
            SELECT
                i,
                -- Muestreo con random() y NO con aritmetica modular sobre i.
                -- La version modular tenia un defecto silencioso: 40503 mod 150
                -- da 3, asi que (i * 40503) % 150 solo produce multiplos de 3 y
                -- unicamente 50 de los 150 paquetes se usaban. El sintoma no era
                -- un error sino datos sesgados -- destinos sin una sola reserva --
                -- que solo aparecio al revisar el ranking del dashboard.
                -- Con setseed() al inicio, random() sigue siendo reproducible.
                1 + floor(random() * v_n_clientes)::bigint                      AS cliente_rn,
                CASE WHEN (i % 100) < 85
                     THEN 1 + floor(random() * v_n_paquetes)::bigint END        AS paquete_rn,
                1 + floor(random() * v_n_cal)::int                             AS cal_idx,
                ((i * 7919) % 180 + 1) * INTERVAL '1 day'                      AS anticipacion,
                ((i * 104729) % 12 + 2) * INTERVAL '1 day'                     AS noches,
                (1 + (i * 31) % 8)::int                                        AS personas,
                CASE WHEN (i % 100) < 70 THEN 'CONFIRMADA'
                     WHEN (i % 100) < 82 THEN 'PENDIENTE'
                     ELSE 'CANCELADA' END                                      AS estado
            FROM generate_series(v_b * v_bloque + 1, v_b * v_bloque + v_bloque) g(i)
        ) b
        JOIN _gen_calendario  c  ON c.idx = b.cal_idx
        JOIN _gen_cliente_ref cr ON cr.rn  = b.cliente_rn
        LEFT JOIN _gen_paquete_ref pr ON pr.rn = b.paquete_rn;

        COMMIT;
        RAISE NOTICE 'Bloque % / % completado (% reservas acumuladas) - transcurrido %',
            v_b + 1, v_total / v_bloque, (v_b + 1) * v_bloque,
            clock_timestamp() - v_ini;
    END LOOP;
END
$carga$;

-- ---------------------------------------------------------------------
-- 6. Detalle de reservas: habitaciones y tours
-- ---------------------------------------------------------------------
\echo '>> Materializando el mapa hotel -> tipos de habitacion...'

CREATE TABLE _gen_hotel_tipo AS
SELECT th.hotel_id,
       th.tipo_habitacion_id,
       th.capacidad_personas,
       th.tarifa_base,
       (row_number() OVER (PARTITION BY th.hotel_id ORDER BY th.tipo_habitacion_id) - 1) AS rn,
       COUNT(*)   OVER (PARTITION BY th.hotel_id)                                        AS n_tipos
FROM tipo_habitacion th;
CREATE INDEX ON _gen_hotel_tipo (hotel_id, rn);
ANALYZE _gen_hotel_tipo;

\echo '>> Generando reserva_habitacion...'

-- El alojamiento se reparte entre TODOS los hoteles de la ciudad del paquete,
-- no solo entre los 2-3 que el paquete lista en su catalogo. Es lo que hace un
-- mayorista real: vende el destino y ubica al visitante segun disponibilidad.
--
-- Repartir por paquete no alcanzaba: con 150 paquetes, la demanda se concentraba
-- en ~100 hoteles y algunos quedaban al 3000 % de ocupacion. Al elegir por
-- ciudad, el resto de reserva_id sobre la cantidad de hoteles de esa ciudad
-- distribuye la demanda de forma practicamente uniforme entre los 196 hoteles
-- generados.
INSERT INTO reserva_habitacion (reserva_id, tipo_habitacion_id,
                                cantidad_habitaciones, tarifa_aplicada)
SELECT
    r.reserva_id,
    ht.tipo_habitacion_id,
    GREATEST(1, CEIL(r.cantidad_personas::numeric / ht.capacidad_personas))::int,
    ROUND((ht.tarifa_base * (0.85 + (r.reserva_id % 40) / 100.0))::numeric, 2)
FROM reserva r
JOIN _gen_paquete_ciudad pc ON pc.paquete_id = r.paquete_id
JOIN _gen_hotel_rank     hr ON hr.ciudad_id = pc.ciudad_id
                           AND hr.rn        = r.reserva_id % hr.n_hoteles
JOIN _gen_hotel_tipo     ht ON ht.hotel_id  = hr.hotel_id
                           AND ht.rn        = r.reserva_id % ht.n_tipos
WHERE r.reserva_id > 5;

\echo '>> Generando reserva_tour...'

INSERT INTO reserva_tour (reserva_id, tour_id, cantidad_personas, precio_aplicado)
SELECT
    r.reserva_id,
    pt.tour_id,
    r.cantidad_personas,
    ROUND((t.precio * (0.90 + (r.reserva_id % 25) / 100.0))::numeric, 2)
FROM reserva r
JOIN paquete_tour pt ON pt.paquete_id = r.paquete_id
JOIN tour t          ON t.tour_id     = pt.tour_id
WHERE r.reserva_id > 5;

-- ---------------------------------------------------------------------
-- 6b. Dimensionar la capacidad instalada segun la demanda pico
--
-- Es el paso que hace creible el KPI de ocupacion hotelera.
--
-- Con una capacidad arbitraria, la ocupacion diaria de algunos hoteles
-- superaba el 160 % y el 1,4 % de los dias-hotel quedaba sobrevendido, lo
-- que ademas contradice RF-07 ("verificar la disponibilidad antes de
-- confirmar una reserva, evitando sobreventas"). El generador no simula esa
-- verificacion reserva por reserva -- seria lentisimo -- asi que resuelve el
-- mismo problema por el otro lado: dimensiona cada hotel para su temporada
-- alta, que es exactamente como se construye un hotel real.
--
-- Capacidad = pico de habitaciones ocupadas en un dia / 0.82, con piso de
-- 40 habitaciones. El resultado medido: ocupacion media 31 %, pico diario
-- maximo 82 %, cero dias por encima de la capacidad.
-- ---------------------------------------------------------------------
\echo '>> Dimensionando la capacidad de cada hotel segun su demanda pico...'

CREATE TABLE _gen_pico_hotel AS
SELECT s.hotel_id, MAX(s.hab)::int AS pico_dia
FROM (
    SELECT th.hotel_id,
           d.dia,
           SUM(rh.cantidad_habitaciones) AS hab
    FROM reserva_habitacion rh
    JOIN reserva r          ON r.reserva_id = rh.reserva_id
                           AND r.estado = 'CONFIRMADA'
    JOIN tipo_habitacion th ON th.tipo_habitacion_id = rh.tipo_habitacion_id
    CROSS JOIN LATERAL generate_series(r.fecha_inicio,
                                       r.fecha_fin - 1,
                                       INTERVAL '1 day') d(dia)
    GROUP BY th.hotel_id, d.dia
) s
GROUP BY s.hotel_id;

WITH objetivo AS (
    SELECT h.hotel_id,
           GREATEST(40, CEIL(COALESCE(p.pico_dia, 0) / 0.82))::int AS total_hab
    FROM hotel h
    LEFT JOIN _gen_pico_hotel p ON p.hotel_id = h.hotel_id
    WHERE h.hotel_id > 4
),
reparto AS (
    SELECT th.tipo_habitacion_id,
           GREATEST(6, CEIL(o.total_hab::numeric / cnt.n))::int AS cupo
    FROM tipo_habitacion th
    JOIN objetivo o ON o.hotel_id = th.hotel_id
    JOIN (SELECT hotel_id, COUNT(*) AS n
            FROM tipo_habitacion GROUP BY hotel_id) cnt ON cnt.hotel_id = th.hotel_id
)
UPDATE tipo_habitacion th
   SET cantidad_disponible = r.cupo
FROM reparto r
WHERE r.tipo_habitacion_id = th.tipo_habitacion_id;

-- capacidad_total del hotel derivada de sus habitaciones, para que el atributo
-- que muestra el dashboard (DimHotel.RangoCapacidad) no contradiga al KPI de
-- ocupacion que sale de FactOcupacionDiaria.
UPDATE hotel h
   SET capacidad_total = c.total
FROM (SELECT hotel_id, SUM(cantidad_disponible * capacidad_personas)::int AS total
      FROM tipo_habitacion GROUP BY hotel_id) c
WHERE c.hotel_id = h.hotel_id AND h.hotel_id > 4;

-- ---------------------------------------------------------------------
-- 7. Bitacora ETL del origen (coherente con el nuevo volumen)
-- ---------------------------------------------------------------------
INSERT INTO importacion_datos (tipo_archivo, nombre_archivo, estado, registros_leidos,
        registros_validos, registros_rechazados, fecha_inicio, fecha_fin)
SELECT
    (ARRAY['CSV','JSON','XML'])[1 + (g % 3)],
    'lote_' || to_char(DATE '2021-01-01' + (g * 30), 'YYYYMM') || '_' || g ||
        (ARRAY['.csv','.json','.xml'])[1 + (g % 3)],
    CASE WHEN g % 9 = 0 THEN 'CON_ERRORES' ELSE 'COMPLETADO' END,
    1000 + (g * 137) % 9000,
    1000 + (g * 137) % 9000 - (CASE WHEN g % 9 = 0 THEN (g * 7) % 120 ELSE 0 END),
    CASE WHEN g % 9 = 0 THEN (g * 7) % 120 ELSE 0 END,
    TIMESTAMP '2021-01-01' + (g * 30) * INTERVAL '1 day',
    TIMESTAMP '2021-01-01' + (g * 30) * INTERVAL '1 day' + INTERVAL '11 minutes'
FROM generate_series(1, 70) g;

-- ---------------------------------------------------------------------
-- 8. Recrear indices, limpiar auxiliares y refrescar estadisticas
-- ---------------------------------------------------------------------
\echo '>> Recreando indices y ejecutando ANALYZE...'

CREATE INDEX idx_reserva_cliente ON reserva(cliente_id);
CREATE INDEX idx_reserva_fechas  ON reserva(fecha_inicio, fecha_fin);
CREATE INDEX idx_pref_gin        ON preferencia_cliente USING GIN (datos_adicionales);
CREATE INDEX IF NOT EXISTS idx_rh_reserva ON reserva_habitacion(reserva_id);
CREATE INDEX IF NOT EXISTS idx_rt_reserva ON reserva_tour(reserva_id);

DROP TABLE IF EXISTS _gen_nombre, _gen_apellido, _gen_pais, _gen_ciudad,
                     _gen_calendario, _gen_hotel_tipo, _gen_hotel_ciudad,
                     _gen_tour_ciudad, _gen_paquete_ciudad,
                     _gen_cliente_ref, _gen_paquete_ref,
                     _gen_hotel_rank, _gen_paquete_hotel_rank, _gen_pico_hotel;

VACUUM ANALYZE;

\echo '>> Generacion completada.'
\timing off
