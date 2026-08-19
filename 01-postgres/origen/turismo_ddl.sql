-- =====================================================================
-- ESCENARIO 8: TURISMO INTELIGENTE 
-- =====================================================================

DROP TABLE IF EXISTS error_importacion, importacion_datos, reserva_tour,
    reserva_habitacion, reserva, paquete_tour, paquete_hotel,
    paquete_turistico, tour, tipo_habitacion, hotel, preferencia_cliente,
    cliente CASCADE;

-- 1. CLIENTE
CREATE TABLE cliente (
    cliente_id       BIGSERIAL PRIMARY KEY,
    identificacion   VARCHAR(50)  NOT NULL UNIQUE,
    nombre           VARCHAR(100) NOT NULL,
    apellidos        VARCHAR(100) NOT NULL,
    correo           VARCHAR(150) NOT NULL UNIQUE,
    telefono         VARCHAR(20),
    pais_origen      VARCHAR(60),
    fecha_nacimiento DATE,
    activo           BOOLEAN NOT NULL DEFAULT TRUE,
    fecha_registro   TIMESTAMP NOT NULL DEFAULT NOW()
);

-- 2. PREFERENCIA_CLIENTE
CREATE TABLE preferencia_cliente (
    preferencia_id       BIGSERIAL PRIMARY KEY,
    cliente_id           BIGINT NOT NULL REFERENCES cliente(cliente_id),
    destinos_preferidos  VARCHAR(200),
    tipo_alojamiento     VARCHAR(100),
    actividades_favoritas VARCHAR(200),
    presupuesto_estimado NUMERIC(10,2),
    temporada_viaje      VARCHAR(50),
    datos_adicionales    JSONB,
    fecha_actualizacion  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- 3. HOTEL
CREATE TABLE hotel (
    hotel_id         BIGSERIAL PRIMARY KEY,
    nombre           VARCHAR(150) NOT NULL,
    categoria        VARCHAR(50),
    direccion        VARCHAR(200),
    ciudad           VARCHAR(80)  NOT NULL,
    pais             VARCHAR(60)  NOT NULL,
    servicios        VARCHAR(300),
    capacidad_total  INT,
    activo           BOOLEAN NOT NULL DEFAULT TRUE
);

-- 4. TIPO_HABITACION
CREATE TABLE tipo_habitacion (
    tipo_habitacion_id  BIGSERIAL PRIMARY KEY,
    hotel_id            BIGINT NOT NULL REFERENCES hotel(hotel_id),
    nombre              VARCHAR(100) NOT NULL,
    descripcion         TEXT,
    capacidad_personas  INT NOT NULL,
    tarifa_base         NUMERIC(10,2) NOT NULL,
    cantidad_disponible INT NOT NULL DEFAULT 0,
    activo              BOOLEAN NOT NULL DEFAULT TRUE
);

-- 5. TOUR
CREATE TABLE tour (
    tour_id         BIGSERIAL PRIMARY KEY,
    nombre          VARCHAR(150) NOT NULL,
    destino         VARCHAR(100),
    descripcion     TEXT,
    fecha_inicio    DATE,
    fecha_fin       DATE,
    duracion_horas  INT,
    cupo_maximo     INT NOT NULL,
    precio          NUMERIC(10,2) NOT NULL,
    proveedor       VARCHAR(150),
    activo          BOOLEAN NOT NULL DEFAULT TRUE
);

-- 6. PAQUETE_TURISTICO
CREATE TABLE paquete_turistico (
    paquete_id            BIGSERIAL PRIMARY KEY,
    nombre                VARCHAR(150) NOT NULL,
    descripcion           TEXT,
    fecha_inicio          DATE NOT NULL,
    fecha_fin             DATE NOT NULL,
    duracion_dias         INT,
    precio_total          NUMERIC(10,2) NOT NULL,
    servicios_adicionales VARCHAR(300),
    activo                BOOLEAN NOT NULL DEFAULT TRUE,
    CHECK (fecha_fin >= fecha_inicio)
);

-- 7. PAQUETE_HOTEL
CREATE TABLE paquete_hotel (
    paquete_hotel_id BIGSERIAL PRIMARY KEY,
    paquete_id       BIGINT NOT NULL REFERENCES paquete_turistico(paquete_id),
    hotel_id         BIGINT NOT NULL REFERENCES hotel(hotel_id),
    noches_incluidas INT NOT NULL
);

-- 8. PAQUETE_TOUR
CREATE TABLE paquete_tour (
    paquete_tour_id BIGSERIAL PRIMARY KEY,
    paquete_id      BIGINT NOT NULL REFERENCES paquete_turistico(paquete_id),
    tour_id         BIGINT NOT NULL REFERENCES tour(tour_id)
);

-- 9. RESERVA
CREATE TABLE reserva (
    reserva_id          BIGSERIAL PRIMARY KEY,
    cliente_id          BIGINT NOT NULL REFERENCES cliente(cliente_id),
    paquete_id          BIGINT REFERENCES paquete_turistico(paquete_id),
    fecha_reserva       TIMESTAMP NOT NULL DEFAULT NOW(),
    fecha_inicio        DATE NOT NULL,
    fecha_fin           DATE NOT NULL,
    cantidad_personas   INT NOT NULL DEFAULT 1,
    estado              VARCHAR(30) NOT NULL DEFAULT 'PENDIENTE',
    monto_total         NUMERIC(10,2) NOT NULL,
    motivo_cancelacion  VARCHAR(200),
    fecha_actualizacion TIMESTAMP NOT NULL DEFAULT NOW(),
    CHECK (fecha_fin >= fecha_inicio)
);

-- 10. RESERVA_HABITACION
CREATE TABLE reserva_habitacion (
    reserva_habitacion_id BIGSERIAL PRIMARY KEY,
    reserva_id            BIGINT NOT NULL REFERENCES reserva(reserva_id),
    tipo_habitacion_id    BIGINT NOT NULL REFERENCES tipo_habitacion(tipo_habitacion_id),
    cantidad_habitaciones INT NOT NULL,
    tarifa_aplicada       NUMERIC(10,2) NOT NULL
);

-- 11. RESERVA_TOUR
CREATE TABLE reserva_tour (
    reserva_tour_id  BIGSERIAL PRIMARY KEY,
    reserva_id       BIGINT NOT NULL REFERENCES reserva(reserva_id),
    tour_id          BIGINT NOT NULL REFERENCES tour(tour_id),
    cantidad_personas INT NOT NULL,
    precio_aplicado  NUMERIC(10,2) NOT NULL
);

-- 12. IMPORTACION_DATOS (soporte ETL)
CREATE TABLE importacion_datos (
    importacion_id        BIGSERIAL PRIMARY KEY,
    tipo_archivo          VARCHAR(20) NOT NULL,
    nombre_archivo        VARCHAR(200) NOT NULL,
    estado                VARCHAR(30) NOT NULL DEFAULT 'PENDIENTE',
    registros_leidos      INT DEFAULT 0,
    registros_validos     INT DEFAULT 0,
    registros_rechazados  INT DEFAULT 0,
    fecha_inicio          TIMESTAMP,
    fecha_fin             TIMESTAMP
);

-- 13. ERROR_IMPORTACION
CREATE TABLE error_importacion (
    error_id           BIGSERIAL PRIMARY KEY,
    importacion_id     BIGINT NOT NULL REFERENCES importacion_datos(importacion_id),
    numero_registro    INT,
    campo              VARCHAR(100),
    regla_validacion   VARCHAR(150),
    descripcion_error  TEXT,
    datos_originales   JSONB
);

-- Índices de apoyo
CREATE INDEX idx_reserva_cliente ON reserva(cliente_id);
CREATE INDEX idx_reserva_fechas  ON reserva(fecha_inicio, fecha_fin);
CREATE INDEX idx_pref_gin        ON preferencia_cliente USING GIN (datos_adicionales);