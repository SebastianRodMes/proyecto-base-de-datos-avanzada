/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   41-esquema-staging.sql

   Zona de aterrizaje del ETL. Recibe los datos tal como salen de cada
   fuente, sin transformar, para que la extraccion sea rapida (bcp) y la
   transformacion ocurra despues dentro del motor.

   Reglas de diseno del staging:
     * Todas las columnas son NULLables y de tipo permisivo (NVARCHAR):
       si el origen trae basura, entra igual y se rechaza en la fase de
       validacion, quedando registrada en etl.Error. Si el staging fuera
       estricto, bcp abortaria el lote completo y se perderia la traza.
     * Sin claves primarias ni indices: el objetivo es maxima velocidad de
       insercion masiva. Los indices se crean despues, solo donde el MERGE
       los necesita.
     * Vive en FG_STG y se trunca al inicio de cada corrida.
     * Cada fila lleva EjecucionId para poder rastrear de que corrida vino.

   Uso: sqlcmd -S TURISMODW -E -C -d TurismoDW -i 41-esquema-staging.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

/* ---------------------------------------------------------------------
   Limpieza
   --------------------------------------------------------------------- */
DECLARE @drop nvarchar(max) = N'';
SELECT @drop += N'DROP TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N';' + CHAR(10)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'stg';
EXEC sys.sp_executesql @drop;
GO

/* =====================================================================
   ORIGEN 1 - PostgreSQL (base operacional 'turismo')
   ===================================================================== */

CREATE TABLE stg.Cliente (
    cliente_id        nvarchar(50),
    identificacion    nvarchar(100),
    nombre            nvarchar(200),
    apellidos         nvarchar(200),
    correo            nvarchar(300),
    telefono          nvarchar(50),
    pais_origen       nvarchar(100),
    fecha_nacimiento  nvarchar(50),
    activo            nvarchar(10),
    fecha_registro    nvarchar(50),
    EjecucionId       int
) ON FG_STG;

CREATE TABLE stg.PreferenciaCliente (
    preferencia_id        nvarchar(50),
    cliente_id            nvarchar(50),
    destinos_preferidos   nvarchar(400),
    tipo_alojamiento      nvarchar(200),
    actividades_favoritas nvarchar(400),
    presupuesto_estimado  nvarchar(50),
    temporada_viaje       nvarchar(100),
    datos_adicionales     nvarchar(max),   -- JSONB del origen, se parsea con OPENJSON
    fecha_actualizacion   nvarchar(50),
    EjecucionId           int
) ON FG_STG;

CREATE TABLE stg.Hotel (
    hotel_id        nvarchar(50),
    nombre          nvarchar(300),
    categoria       nvarchar(100),
    direccion       nvarchar(400),
    ciudad          nvarchar(150),
    pais            nvarchar(100),
    servicios       nvarchar(600),
    capacidad_total nvarchar(50),
    activo          nvarchar(10),
    EjecucionId     int
) ON FG_STG;

CREATE TABLE stg.TipoHabitacion (
    tipo_habitacion_id  nvarchar(50),
    hotel_id            nvarchar(50),
    nombre              nvarchar(200),
    descripcion         nvarchar(max),
    capacidad_personas  nvarchar(50),
    tarifa_base         nvarchar(50),
    cantidad_disponible nvarchar(50),
    activo              nvarchar(10),
    EjecucionId         int
) ON FG_STG;

CREATE TABLE stg.Tour (
    tour_id        nvarchar(50),
    nombre         nvarchar(300),
    destino        nvarchar(200),
    descripcion    nvarchar(max),
    fecha_inicio   nvarchar(50),
    fecha_fin      nvarchar(50),
    duracion_horas nvarchar(50),
    cupo_maximo    nvarchar(50),
    precio         nvarchar(50),
    proveedor      nvarchar(300),
    activo         nvarchar(10),
    EjecucionId    int
) ON FG_STG;

CREATE TABLE stg.PaqueteTuristico (
    paquete_id            nvarchar(50),
    nombre                nvarchar(300),
    descripcion           nvarchar(max),
    fecha_inicio          nvarchar(50),
    fecha_fin             nvarchar(50),
    duracion_dias         nvarchar(50),
    precio_total          nvarchar(50),
    servicios_adicionales nvarchar(600),
    activo                nvarchar(10),
    EjecucionId           int
) ON FG_STG;

CREATE TABLE stg.PaqueteHotel (
    paquete_hotel_id nvarchar(50),
    paquete_id       nvarchar(50),
    hotel_id         nvarchar(50),
    noches_incluidas nvarchar(50),
    EjecucionId      int
) ON FG_STG;

CREATE TABLE stg.PaqueteTour (
    paquete_tour_id nvarchar(50),
    paquete_id      nvarchar(50),
    tour_id         nvarchar(50),
    EjecucionId     int
) ON FG_STG;

CREATE TABLE stg.Reserva (
    reserva_id          nvarchar(50),
    cliente_id          nvarchar(50),
    paquete_id          nvarchar(50),
    fecha_reserva       nvarchar(50),
    fecha_inicio        nvarchar(50),
    fecha_fin           nvarchar(50),
    cantidad_personas   nvarchar(50),
    estado              nvarchar(60),
    monto_total         nvarchar(50),
    motivo_cancelacion  nvarchar(400),
    fecha_actualizacion nvarchar(50),
    EjecucionId         int
) ON FG_STG;

CREATE TABLE stg.ReservaHabitacion (
    reserva_habitacion_id nvarchar(50),
    reserva_id            nvarchar(50),
    tipo_habitacion_id    nvarchar(50),
    cantidad_habitaciones nvarchar(50),
    tarifa_aplicada       nvarchar(50),
    EjecucionId           int
) ON FG_STG;

CREATE TABLE stg.ReservaTour (
    reserva_tour_id   nvarchar(50),
    reserva_id        nvarchar(50),
    tour_id           nvarchar(50),
    cantidad_personas nvarchar(50),
    precio_aplicado   nvarchar(50),
    EjecucionId       int
) ON FG_STG;

/* =====================================================================
   ORIGEN 2 - MongoDB (base 'turismo_nosql')
   ===================================================================== */

CREATE TABLE stg.Resena (
    resena_id      nvarchar(50),      -- ObjectId como cadena
    cliente_id     nvarchar(50),
    tipo_entidad   nvarchar(30),      -- HOTEL | TOUR | PAQUETE
    entidad_id     nvarchar(50),
    calificacion   nvarchar(20),
    titulo         nvarchar(400),
    comentario     nvarchar(max),
    idioma         nvarchar(20),
    fecha          nvarchar(50),
    verificada     nvarchar(10),
    etiquetas      nvarchar(600),     -- lista aplanada, separada por comas
    origen_canal   nvarchar(60),
    EjecucionId    int
) ON FG_STG;

CREATE TABLE stg.InteraccionWeb (
    interaccion_id  nvarchar(50),
    cliente_id      nvarchar(50),     -- NULL en sesiones anonimas
    sesion_id       nvarchar(80),
    tipo_evento     nvarchar(60),
    destino_buscado nvarchar(200),
    entidad_tipo    nvarchar(30),
    entidad_id      nvarchar(50),
    dispositivo     nvarchar(40),
    canal           nvarchar(60),
    pais_visitante  nvarchar(100),
    fecha_evento    nvarchar(50),
    duracion_seg    nvarchar(50),
    convirtio       nvarchar(10),
    EjecucionId     int
) ON FG_STG;

/* =====================================================================
   ORIGEN 3 - Archivos JSON (RF-10: preferencias de visitantes)
   ORIGEN 4 - Documentos XML (RF-11: paquetes turisticos)
   ===================================================================== */

CREATE TABLE stg.PreferenciaArchivo (
    archivo_origen       nvarchar(300),
    numero_registro      int,
    identificacion       nvarchar(100),
    correo               nvarchar(300),
    destinos_preferidos  nvarchar(400),
    tipo_alojamiento     nvarchar(200),
    presupuesto_estimado nvarchar(50),
    temporada_viaje      nvarchar(100),
    idioma               nvarchar(20),
    grupo_viaje          nvarchar(60),
    payload_original     nvarchar(max),   -- se conserva para la traza de errores
    EjecucionId          int
) ON FG_STG;

CREATE TABLE stg.PaqueteArchivo (
    archivo_origen        nvarchar(300),
    numero_registro       int,
    codigo_paquete        nvarchar(60),
    nombre                nvarchar(300),
    destino               nvarchar(200),
    pais                  nvarchar(100),
    duracion_dias         nvarchar(50),
    precio_total          nvarchar(50),
    moneda                nvarchar(20),
    actividades           nvarchar(600),
    servicios_adicionales nvarchar(600),
    temporada             nvarchar(60),
    payload_original      nvarchar(max),
    EjecucionId           int
) ON FG_STG;

GO

/* ---------------------------------------------------------------------
   Indices minimos: solo los que usa el MERGE para resolver claves.
   Se crean sobre FG_IDX para no competir por E/S con los datos.
   --------------------------------------------------------------------- */
CREATE INDEX IX_stgReserva_cliente ON stg.Reserva (cliente_id)        ON FG_IDX;
CREATE INDEX IX_stgReserva_id      ON stg.Reserva (reserva_id)        ON FG_IDX;
CREATE INDEX IX_stgRH_reserva      ON stg.ReservaHabitacion (reserva_id) ON FG_IDX;
CREATE INDEX IX_stgRT_reserva      ON stg.ReservaTour (reserva_id)     ON FG_IDX;
GO

PRINT '';
PRINT '=== Tablas de staging creadas ===';
SELECT
    [Tabla]     = s.name + '.' + t.name,
    [Columnas]  = (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id),
    [Filegroup] = ds.name
FROM sys.tables t
JOIN sys.schemas s      ON s.schema_id = t.schema_id
JOIN sys.indexes i      ON i.object_id = t.object_id AND i.index_id IN (0,1)
JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
WHERE s.name = 'stg'
ORDER BY t.name;
GO

PRINT '>> Staging listo. Siguiente: 42-esquema-estrella.sql';
GO
