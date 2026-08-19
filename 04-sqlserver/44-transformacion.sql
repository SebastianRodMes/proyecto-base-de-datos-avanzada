/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   44-transformacion.sql

   La "T" y la "L" del ETL: convierte el staging crudo en el modelo
   estrella. Se implementa como procedimientos almacenados y no como un
   script suelto porque:
     * el orquestador de Python necesita invocar y cronometrar cada etapa
       por separado para la bitacora;
     * la transformacion se ejecuta dentro del motor, donde estan los
       datos, en lugar de arrastrar 2 millones de filas a memoria de Python.

   Orden de invocacion:
     1. etl.usp_ValidarStaging          (RF-15: limpieza y validacion)
     2. etl.usp_CargarDimensiones       (MERGE, SCD tipo 1)
     3. etl.usp_CargarHechos            (recarga completa)
     4. etl.usp_CargarOcupacionDiaria   (deriva el KPI de ocupacion)
     5. etl.usp_VerificarIntegridad     (re-habilita FK WITH CHECK)

   Uso: sqlcmd -S TURISMODW -E -C -d TurismoDW -i 44-transformacion.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

DROP PROCEDURE IF EXISTS etl.usp_VerificarIntegridad;
DROP PROCEDURE IF EXISTS etl.usp_CargarOcupacionDiaria;
DROP PROCEDURE IF EXISTS etl.usp_CargarHechos;
DROP PROCEDURE IF EXISTS etl.usp_CargarDimensiones;
DROP PROCEDURE IF EXISTS etl.usp_ValidarStaging;
DROP FUNCTION  IF EXISTS etl.fn_TiempoKey;
DROP TABLE     IF EXISTS etl.Numeros;
GO

/* ---------------------------------------------------------------------
   Tabla de apoyo: 1..4000. Se usa para explotar las estadias en dias.
   Un CTE recursivo seria mas lento y tocaria el limite de recursion.
   --------------------------------------------------------------------- */
CREATE TABLE etl.Numeros (n int NOT NULL PRIMARY KEY CLUSTERED) ON FG_DIM;

INSERT INTO etl.Numeros (n)
SELECT TOP (4000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
GO

/* ---------------------------------------------------------------------
   Fecha -> clave entera yyyymmdd. -1 cuando la fecha es nula o esta
   fuera del rango cubierto por DimTiempo.
   Escalar en linea (INLINE = ON) para que no penalice 2 millones de filas.
   --------------------------------------------------------------------- */
CREATE FUNCTION etl.fn_TiempoKey (@f date)
RETURNS int
WITH INLINE = ON
AS
BEGIN
    RETURN CASE
             WHEN @f IS NULL THEN -1
             WHEN @f < '2020-01-01' OR @f > '2027-12-31' THEN -1
             ELSE YEAR(@f) * 10000 + MONTH(@f) * 100 + DAY(@f)
           END;
END
GO

/* =====================================================================
   1. VALIDACION Y LIMPIEZA  (RF-15)

   "El proceso ETL debera validar campos obligatorios, normalizar formatos
    y detectar duplicados."

   Estrategia: no se borra nada del staging. Se marcan los registros
   invalidos en etl.Error y las cargas posteriores los excluyen con un
   NOT EXISTS contra esa bitacora. Asi el dato rechazado sigue disponible
   para auditoria, que es justo lo que pide RNF-05.
   ===================================================================== */
CREATE PROCEDURE etl.usp_ValidarStaging
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;

    /* --- Clientes: identificacion obligatoria ------------------------ */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'cliente', c.cliente_id, 'identificacion',
           'no_nulo', 'RECHAZO', 'Identificacion vacia o nula',
           CONCAT('{"cliente_id":"', c.cliente_id, '","correo":"', c.correo, '"}')
    FROM stg.Cliente c
    WHERE NULLIF(LTRIM(RTRIM(c.identificacion)), '') IS NULL;

    /* --- Clientes: formato de correo -------------------------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'cliente', c.cliente_id, 'correo',
           'formato_email', 'ADVERTENCIA', 'Correo con formato invalido',
           CONCAT('{"cliente_id":"', c.cliente_id, '","correo":"', c.correo, '"}')
    FROM stg.Cliente c
    WHERE c.correo IS NOT NULL
      AND (c.correo NOT LIKE '%_@_%.__%' OR c.correo LIKE '% %');

    /* --- Clientes: identificacion duplicada -------------------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'cliente', MIN(c.cliente_id), 'identificacion',
           'duplicado', 'ADVERTENCIA',
           CONCAT('Identificacion repetida en ', COUNT(*), ' registros'),
           CONCAT('{"identificacion":"', c.identificacion, '"}')
    FROM stg.Cliente c
    WHERE c.identificacion IS NOT NULL
    GROUP BY c.identificacion
    HAVING COUNT(*) > 1;

    /* --- Reservas: monto no negativo --------------------------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'reserva', r.reserva_id, 'monto_total',
           'numerico_positivo', 'RECHAZO', 'Monto total negativo o no numerico',
           CONCAT('{"reserva_id":"', r.reserva_id, '","monto_total":"', r.monto_total, '"}')
    FROM stg.Reserva r
    WHERE TRY_CONVERT(decimal(12,2), r.monto_total) IS NULL
       OR TRY_CONVERT(decimal(12,2), r.monto_total) < 0;

    /* --- Reservas: coherencia de fechas ------------------------------ */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'reserva', r.reserva_id, 'fecha_fin',
           'rango_fechas', 'RECHAZO', 'La fecha de fin es anterior a la de inicio',
           CONCAT('{"reserva_id":"', r.reserva_id, '","inicio":"', r.fecha_inicio,
                  '","fin":"', r.fecha_fin, '"}')
    FROM stg.Reserva r
    WHERE TRY_CONVERT(date, r.fecha_inicio) IS NULL
       OR TRY_CONVERT(date, r.fecha_fin)    IS NULL
       OR TRY_CONVERT(date, r.fecha_fin) < TRY_CONVERT(date, r.fecha_inicio);

    /* --- Reservas: estado dentro del dominio permitido --------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'POSTGRESQL', 'reserva', r.reserva_id, 'estado',
           'valor_permitido', 'ADVERTENCIA',
           CONCAT('Estado desconocido: ', r.estado, ' (se asigna DESCONOCIDO)'),
           CONCAT('{"reserva_id":"', r.reserva_id, '","estado":"', r.estado, '"}')
    FROM stg.Reserva r
    WHERE r.estado IS NULL
       OR UPPER(LTRIM(RTRIM(r.estado))) NOT IN ('CONFIRMADA','PENDIENTE','CANCELADA');

    /* --- Resenas de MongoDB: calificacion en rango 1..5 -------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ObjetoOrigen, ClaveNegocio, Campo,
                           ReglaValidacion, Severidad, Descripcion, DatosOriginales)
    SELECT @EjecucionId, 'MONGODB', 'resenas', s.resena_id, 'calificacion',
           'rango_1_5', 'RECHAZO', 'Calificacion fuera del rango permitido',
           CONCAT('{"_id":"', s.resena_id, '","calificacion":"', s.calificacion, '"}')
    FROM stg.Resena s
    WHERE TRY_CONVERT(tinyint, s.calificacion) IS NULL
       OR TRY_CONVERT(tinyint, s.calificacion) NOT BETWEEN 1 AND 5;

    /* --- Preferencias en archivos JSON (RF-10) ----------------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ArchivoOrigen, ObjetoOrigen, NumeroRegistro,
                           ClaveNegocio, Campo, ReglaValidacion, Severidad, Descripcion,
                           DatosOriginales)
    SELECT @EjecucionId, 'JSON', p.archivo_origen, 'preferencias', p.numero_registro,
           p.identificacion, 'identificacion', 'no_nulo', 'RECHAZO',
           'Registro sin identificacion de cliente', p.payload_original
    FROM stg.PreferenciaArchivo p
    WHERE NULLIF(LTRIM(RTRIM(p.identificacion)), '') IS NULL;

    INSERT INTO etl.Error (EjecucionId, Fuente, ArchivoOrigen, ObjetoOrigen, NumeroRegistro,
                           ClaveNegocio, Campo, ReglaValidacion, Severidad, Descripcion,
                           DatosOriginales)
    SELECT @EjecucionId, 'JSON', p.archivo_origen, 'preferencias', p.numero_registro,
           p.identificacion, 'presupuesto_estimado', 'numerico_positivo', 'RECHAZO',
           'Presupuesto no numerico o negativo', p.payload_original
    FROM stg.PreferenciaArchivo p
    WHERE p.presupuesto_estimado IS NOT NULL
      AND (TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) IS NULL
        OR TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) < 0);

    /* --- Paquetes en documentos XML (RF-11) -------------------------- */
    INSERT INTO etl.Error (EjecucionId, Fuente, ArchivoOrigen, ObjetoOrigen, NumeroRegistro,
                           ClaveNegocio, Campo, ReglaValidacion, Severidad, Descripcion,
                           DatosOriginales)
    SELECT @EjecucionId, 'XML', x.archivo_origen, 'paquetes', x.numero_registro,
           x.codigo_paquete, 'precio_total', 'numerico_positivo', 'RECHAZO',
           'Precio total invalido en el documento XML', x.payload_original
    FROM stg.PaqueteArchivo x
    WHERE TRY_CONVERT(decimal(10,2), x.precio_total) IS NULL
       OR TRY_CONVERT(decimal(10,2), x.precio_total) <= 0;

    SELECT [RegistrosRechazados]  = COUNT_BIG(CASE WHEN Severidad = 'RECHAZO'     THEN 1 END),
           [Advertencias]         = COUNT_BIG(CASE WHEN Severidad = 'ADVERTENCIA' THEN 1 END)
    FROM etl.Error
    WHERE EjecucionId = @EjecucionId;
END
GO

/* =====================================================================
   2. DIMENSIONES  (MERGE, SCD tipo 1)
   ===================================================================== */
CREATE PROCEDURE etl.usp_CargarDimensiones
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ahora datetime2(0) = SYSDATETIME();
    DECLARE @hoy   date         = CAST(SYSDATETIME() AS date);

    /* ---------------- DimHotel ---------------------------------------- */
    MERGE dw.DimHotel AS d
    USING (
        SELECT HotelId        = TRY_CONVERT(bigint, h.hotel_id),
               Nombre         = h.nombre,
               Categoria      = ISNULL(h.categoria, 'Sin categoria'),
               NumeroEstrellas= TRY_CONVERT(tinyint, LEFT(h.categoria, 1)),
               Ciudad         = ISNULL(h.ciudad, 'Sin ciudad'),
               Pais           = ISNULL(h.pais, 'Sin pais'),
               Direccion      = h.direccion,
               Servicios      = h.servicios,
               CapacidadTotal = TRY_CONVERT(int, h.capacidad_total),
               RangoCapacidad = CASE
                                  WHEN TRY_CONVERT(int, h.capacidad_total) IS NULL THEN 'Sin dato'
                                  WHEN TRY_CONVERT(int, h.capacidad_total) < 60  THEN 'Pequeno (<60)'
                                  WHEN TRY_CONVERT(int, h.capacidad_total) < 150 THEN 'Mediano (60-149)'
                                  WHEN TRY_CONVERT(int, h.capacidad_total) < 300 THEN 'Grande (150-299)'
                                  ELSE 'Muy grande (300+)' END,
               Activo         = CASE WHEN UPPER(h.activo) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END
        FROM stg.Hotel h
        WHERE TRY_CONVERT(bigint, h.hotel_id) IS NOT NULL
    ) AS o
    ON d.HotelId = o.HotelId
    WHEN MATCHED THEN UPDATE SET
        d.Nombre = o.Nombre, d.Categoria = o.Categoria, d.NumeroEstrellas = o.NumeroEstrellas,
        d.Ciudad = o.Ciudad, d.Pais = o.Pais, d.Direccion = o.Direccion,
        d.Servicios = o.Servicios, d.CapacidadTotal = o.CapacidadTotal,
        d.RangoCapacidad = o.RangoCapacidad, d.Activo = o.Activo,
        d.EjecucionIdCarga = @EjecucionId, d.FechaCarga = @ahora
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (HotelId, Nombre, Categoria, NumeroEstrellas, Ciudad, Pais, Direccion, Servicios,
         CapacidadTotal, RangoCapacidad, Activo, EjecucionIdCarga, FechaCarga)
        VALUES (o.HotelId, o.Nombre, o.Categoria, o.NumeroEstrellas, o.Ciudad, o.Pais,
                o.Direccion, o.Servicios, o.CapacidadTotal, o.RangoCapacidad, o.Activo,
                @EjecucionId, @ahora);

    /* ---------------- DimTipoHabitacion ------------------------------- */
    MERGE dw.DimTipoHabitacion AS d
    USING (
        SELECT TipoHabitacionId  = TRY_CONVERT(bigint, t.tipo_habitacion_id),
               HotelId           = TRY_CONVERT(bigint, t.hotel_id),
               HotelKey          = ISNULL(h.HotelKey, -1),
               Nombre            = t.nombre,
               CapacidadPersonas = ISNULL(TRY_CONVERT(int, t.capacidad_personas), 0),
               TarifaBase        = ISNULL(TRY_CONVERT(decimal(10,2), t.tarifa_base), 0),
               RangoTarifa       = CASE
                                     WHEN TRY_CONVERT(decimal(10,2), t.tarifa_base) < 80  THEN 'Economica (<80)'
                                     WHEN TRY_CONVERT(decimal(10,2), t.tarifa_base) < 160 THEN 'Media (80-159)'
                                     WHEN TRY_CONVERT(decimal(10,2), t.tarifa_base) < 320 THEN 'Alta (160-319)'
                                     ELSE 'Premium (320+)' END,
               CantidadDisponible= ISNULL(TRY_CONVERT(int, t.cantidad_disponible), 0),
               Activo            = CASE WHEN UPPER(t.activo) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END
        FROM stg.TipoHabitacion t
        LEFT JOIN dw.DimHotel h ON h.HotelId = TRY_CONVERT(bigint, t.hotel_id)
        WHERE TRY_CONVERT(bigint, t.tipo_habitacion_id) IS NOT NULL
    ) AS o
    ON d.TipoHabitacionId = o.TipoHabitacionId
    WHEN MATCHED THEN UPDATE SET
        d.HotelId = o.HotelId, d.HotelKey = o.HotelKey, d.Nombre = o.Nombre,
        d.CapacidadPersonas = o.CapacidadPersonas, d.TarifaBase = o.TarifaBase,
        d.RangoTarifa = o.RangoTarifa, d.CantidadDisponible = o.CantidadDisponible,
        d.Activo = o.Activo, d.EjecucionIdCarga = @EjecucionId, d.FechaCarga = @ahora
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (TipoHabitacionId, HotelId, HotelKey, Nombre, CapacidadPersonas, TarifaBase,
         RangoTarifa, CantidadDisponible, Activo, EjecucionIdCarga, FechaCarga)
        VALUES (o.TipoHabitacionId, o.HotelId, o.HotelKey, o.Nombre, o.CapacidadPersonas,
                o.TarifaBase, o.RangoTarifa, o.CantidadDisponible, o.Activo,
                @EjecucionId, @ahora);

    /* ---------------- DimTour ----------------------------------------- */
    MERGE dw.DimTour AS d
    USING (
        SELECT TourId        = TRY_CONVERT(bigint, t.tour_id),
               Nombre        = t.nombre,
               Destino       = ISNULL(t.destino, 'Sin destino'),
               -- El nombre sigue el patron "<Actividad> <Ciudad>"; se clasifica
               -- contra el catalogo cerrado de actividades del escenario.
               TipoActividad = CASE
                    WHEN t.nombre LIKE 'Canopy%'              THEN 'Canopy'
                    WHEN t.nombre LIKE 'City Tour%'           THEN 'City Tour'
                    WHEN t.nombre LIKE 'Rafting%'             THEN 'Rafting'
                    WHEN t.nombre LIKE 'Buceo%'               THEN 'Buceo'
                    WHEN t.nombre LIKE 'Avistamiento%'        THEN 'Avistamiento de Aves'
                    WHEN t.nombre LIKE 'Tour de Cafe%'        THEN 'Tour de Cafe'
                    WHEN t.nombre LIKE 'Kayak%'               THEN 'Kayak'
                    WHEN t.nombre LIKE 'Snorkel%'             THEN 'Snorkel'
                    WHEN t.nombre LIKE 'Trekking%'            THEN 'Trekking'
                    WHEN t.nombre LIKE 'Safari%'              THEN 'Safari Fotografico'
                    WHEN t.nombre LIKE 'Cabalgata%'           THEN 'Cabalgata'
                    WHEN t.nombre LIKE 'Tour Gastronomico%'   THEN 'Gastronomico'
                    ELSE 'Otro' END,
               Proveedor     = t.proveedor,
               DuracionHoras = TRY_CONVERT(int, t.duracion_horas),
               RangoDuracion = CASE
                                 WHEN TRY_CONVERT(int, t.duracion_horas) IS NULL  THEN 'Sin dato'
                                 WHEN TRY_CONVERT(int, t.duracion_horas) <= 3     THEN 'Corto (<=3h)'
                                 WHEN TRY_CONVERT(int, t.duracion_horas) <= 6     THEN 'Medio (4-6h)'
                                 ELSE 'Largo (7h+)' END,
               CupoMaximo    = TRY_CONVERT(int, t.cupo_maximo),
               Precio        = TRY_CONVERT(decimal(10,2), t.precio),
               Activo        = CASE WHEN UPPER(t.activo) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END
        FROM stg.Tour t
        WHERE TRY_CONVERT(bigint, t.tour_id) IS NOT NULL
    ) AS o
    ON d.TourId = o.TourId
    WHEN MATCHED THEN UPDATE SET
        d.Nombre = o.Nombre, d.Destino = o.Destino, d.TipoActividad = o.TipoActividad,
        d.Proveedor = o.Proveedor, d.DuracionHoras = o.DuracionHoras,
        d.RangoDuracion = o.RangoDuracion, d.CupoMaximo = o.CupoMaximo,
        d.Precio = o.Precio, d.Activo = o.Activo,
        d.EjecucionIdCarga = @EjecucionId, d.FechaCarga = @ahora
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (TourId, Nombre, Destino, TipoActividad, Proveedor, DuracionHoras, RangoDuracion,
         CupoMaximo, Precio, Activo, EjecucionIdCarga, FechaCarga)
        VALUES (o.TourId, o.Nombre, o.Destino, o.TipoActividad, o.Proveedor, o.DuracionHoras,
                o.RangoDuracion, o.CupoMaximo, o.Precio, o.Activo, @EjecucionId, @ahora);

    /* ---------------- DimPaquete --------------------------------------
       Fuente principal PostgreSQL; el XML (RF-11) enriquece los que ya
       existen y aporta los que solo llegan por documento.
       ------------------------------------------------------------------ */
    MERGE dw.DimPaquete AS d
    USING (
        SELECT PaqueteId    = TRY_CONVERT(bigint, p.paquete_id),
               Nombre       = p.nombre,
               TipoPaquete  = CASE
                    WHEN p.nombre LIKE 'Aventura%'     THEN 'Aventura'
                    WHEN p.nombre LIKE 'Descanso%'     THEN 'Descanso'
                    WHEN p.nombre LIKE 'Cultural%'     THEN 'Cultural'
                    WHEN p.nombre LIKE 'Ecoturismo%'   THEN 'Ecoturismo'
                    WHEN p.nombre LIKE 'Familiar%'     THEN 'Familiar'
                    WHEN p.nombre LIKE 'Luna de Miel%' THEN 'Luna de Miel'
                    WHEN p.nombre LIKE 'Premium%'      THEN 'Premium'
                    WHEN p.nombre LIKE 'Express%'      THEN 'Express'
                    ELSE 'General' END,
               DuracionDias = TRY_CONVERT(int, p.duracion_dias),
               RangoDuracion= CASE
                                WHEN TRY_CONVERT(int, p.duracion_dias) IS NULL THEN 'Sin dato'
                                WHEN TRY_CONVERT(int, p.duracion_dias) <= 4    THEN 'Corto (<=4d)'
                                WHEN TRY_CONVERT(int, p.duracion_dias) <= 8    THEN 'Medio (5-8d)'
                                ELSE 'Largo (9d+)' END,
               PrecioTotal  = TRY_CONVERT(decimal(10,2), p.precio_total),
               RangoPrecio  = CASE
                                WHEN TRY_CONVERT(decimal(10,2), p.precio_total) < 700  THEN 'Economico (<700)'
                                WHEN TRY_CONVERT(decimal(10,2), p.precio_total) < 1500 THEN 'Medio (700-1499)'
                                WHEN TRY_CONVERT(decimal(10,2), p.precio_total) < 3000 THEN 'Alto (1500-2999)'
                                ELSE 'Premium (3000+)' END,
               ServiciosAdicionales = p.servicios_adicionales,
               Activo       = CASE WHEN UPPER(p.activo) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END
        FROM stg.PaqueteTuristico p
        WHERE TRY_CONVERT(bigint, p.paquete_id) IS NOT NULL
    ) AS o
    ON d.PaqueteId = o.PaqueteId
    WHEN MATCHED THEN UPDATE SET
        d.Nombre = o.Nombre, d.TipoPaquete = o.TipoPaquete, d.DuracionDias = o.DuracionDias,
        d.RangoDuracion = o.RangoDuracion, d.PrecioTotal = o.PrecioTotal,
        d.RangoPrecio = o.RangoPrecio, d.ServiciosAdicionales = o.ServiciosAdicionales,
        d.Activo = o.Activo, d.FuenteDatos = 'POSTGRESQL',
        d.EjecucionIdCarga = @EjecucionId, d.FechaCarga = @ahora
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (PaqueteId, Nombre, TipoPaquete, DuracionDias, RangoDuracion, PrecioTotal,
         RangoPrecio, ServiciosAdicionales, Activo, FuenteDatos, EjecucionIdCarga, FechaCarga)
        VALUES (o.PaqueteId, o.Nombre, o.TipoPaquete, o.DuracionDias, o.RangoDuracion,
                o.PrecioTotal, o.RangoPrecio, o.ServiciosAdicionales, o.Activo,
                'POSTGRESQL', @EjecucionId, @ahora);

    /* ---------------- DimCliente --------------------------------------
       Aplana cliente + preferencia_cliente. Los atributos del JSONB se
       extraen con JSON_VALUE; el campo se valida con ISJSON antes, porque
       el origen puede traer texto libre.
       Los rechazos detectados en usp_ValidarStaging se excluyen aqui.
       ------------------------------------------------------------------ */
    MERGE dw.DimCliente AS d
    USING (
        SELECT ClienteId       = TRY_CONVERT(bigint, c.cliente_id),
               Identificacion  = c.identificacion,
               NombreCompleto  = LTRIM(RTRIM(ISNULL(c.nombre,'') + ' ' + ISNULL(c.apellidos,''))),
               Nombre          = ISNULL(c.nombre, 'Sin nombre'),
               Apellidos       = ISNULL(c.apellidos, 'Sin apellidos'),
               Correo          = c.correo,
               PaisOrigen      = ISNULL(NULLIF(LTRIM(RTRIM(c.pais_origen)), ''), 'Sin pais'),
               FechaNacimiento = TRY_CONVERT(date, c.fecha_nacimiento),
               Edad            = CASE WHEN TRY_CONVERT(date, c.fecha_nacimiento) IS NOT NULL
                                      THEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy)
                                 END,
               RangoEdad       = CASE
                    WHEN TRY_CONVERT(date, c.fecha_nacimiento) IS NULL THEN 'Sin dato'
                    WHEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy) < 25 THEN '18-24'
                    WHEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy) < 35 THEN '25-34'
                    WHEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy) < 45 THEN '35-44'
                    WHEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy) < 55 THEN '45-54'
                    WHEN DATEDIFF(YEAR, TRY_CONVERT(date, c.fecha_nacimiento), @hoy) < 65 THEN '55-64'
                    ELSE '65+' END,
               Activo          = CASE WHEN UPPER(c.activo) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END,
               FechaRegistro   = TRY_CONVERT(date, c.fecha_registro),
               DestinosPreferidos   = p.destinos_preferidos,
               TipoAlojamiento      = p.tipo_alojamiento,
               ActividadesFavoritas = p.actividades_favoritas,
               PresupuestoEstimado  = TRY_CONVERT(decimal(10,2), p.presupuesto_estimado),
               RangoPresupuesto     = CASE
                    WHEN TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) IS NULL   THEN 'Sin dato'
                    WHEN TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) < 1500    THEN 'Bajo (<1500)'
                    WHEN TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) < 3000    THEN 'Medio (1500-2999)'
                    WHEN TRY_CONVERT(decimal(10,2), p.presupuesto_estimado) < 5000    THEN 'Alto (3000-4999)'
                    ELSE 'Premium (5000+)' END,
               TemporadaViaje  = p.temporada_viaje,
               Idioma          = CASE WHEN ISJSON(p.datos_adicionales) = 1
                                      THEN JSON_VALUE(p.datos_adicionales, '$.idioma') END,
               Dieta           = CASE WHEN ISJSON(p.datos_adicionales) = 1
                                      THEN JSON_VALUE(p.datos_adicionales, '$.dieta') END,
               GrupoViaje      = CASE WHEN ISJSON(p.datos_adicionales) = 1
                                      THEN JSON_VALUE(p.datos_adicionales, '$.grupo') END,
               EsVip           = CASE WHEN ISJSON(p.datos_adicionales) = 1
                                       AND JSON_VALUE(p.datos_adicionales, '$.vip') = 'true'
                                      THEN 1 ELSE 0 END
        FROM stg.Cliente c
        LEFT JOIN stg.PreferenciaCliente p
               ON TRY_CONVERT(bigint, p.cliente_id) = TRY_CONVERT(bigint, c.cliente_id)
        WHERE TRY_CONVERT(bigint, c.cliente_id) IS NOT NULL
          AND NOT EXISTS (
                SELECT 1 FROM etl.Error e
                 WHERE e.EjecucionId  = @EjecucionId
                   AND e.ObjetoOrigen = 'cliente'
                   AND e.Severidad    = 'RECHAZO'
                   AND e.ClaveNegocio = c.cliente_id)
    ) AS o
    ON d.ClienteId = o.ClienteId
    WHEN MATCHED THEN UPDATE SET
        d.Identificacion = o.Identificacion, d.NombreCompleto = o.NombreCompleto,
        d.Nombre = o.Nombre, d.Apellidos = o.Apellidos, d.Correo = o.Correo,
        d.PaisOrigen = o.PaisOrigen, d.FechaNacimiento = o.FechaNacimiento,
        d.Edad = o.Edad, d.RangoEdad = o.RangoEdad, d.Activo = o.Activo,
        d.FechaRegistro = o.FechaRegistro, d.DestinosPreferidos = o.DestinosPreferidos,
        d.TipoAlojamiento = o.TipoAlojamiento, d.ActividadesFavoritas = o.ActividadesFavoritas,
        d.PresupuestoEstimado = o.PresupuestoEstimado, d.RangoPresupuesto = o.RangoPresupuesto,
        d.TemporadaViaje = o.TemporadaViaje, d.Idioma = o.Idioma, d.Dieta = o.Dieta,
        d.GrupoViaje = o.GrupoViaje, d.EsVip = o.EsVip, d.FuenteDatos = 'POSTGRESQL',
        d.EjecucionIdCarga = @EjecucionId, d.FechaCarga = @ahora
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (ClienteId, Identificacion, NombreCompleto, Nombre, Apellidos, Correo, PaisOrigen,
         FechaNacimiento, Edad, RangoEdad, Activo, FechaRegistro, DestinosPreferidos,
         TipoAlojamiento, ActividadesFavoritas, PresupuestoEstimado, RangoPresupuesto,
         TemporadaViaje, Idioma, Dieta, GrupoViaje, EsVip, FuenteDatos,
         EjecucionIdCarga, FechaCarga)
        VALUES (o.ClienteId, o.Identificacion, o.NombreCompleto, o.Nombre, o.Apellidos,
                o.Correo, o.PaisOrigen, o.FechaNacimiento, o.Edad, o.RangoEdad, o.Activo,
                o.FechaRegistro, o.DestinosPreferidos, o.TipoAlojamiento,
                o.ActividadesFavoritas, o.PresupuestoEstimado, o.RangoPresupuesto,
                o.TemporadaViaje, o.Idioma, o.Dieta, o.GrupoViaje, o.EsVip,
                'POSTGRESQL', @EjecucionId, @ahora);

    /* ---------------- Enriquecimiento desde archivos JSON (RF-10) ------
       Los archivos aportan preferencias de visitantes que no estan en la
       base operacional. Solo actualizan clientes existentes; no crean
       clientes nuevos, para no inventar identidades.
       ------------------------------------------------------------------ */
    UPDATE d
       SET d.DestinosPreferidos  = COALESCE(a.destinos_preferidos, d.DestinosPreferidos),
           d.TipoAlojamiento     = COALESCE(a.tipo_alojamiento,    d.TipoAlojamiento),
           d.PresupuestoEstimado = COALESCE(TRY_CONVERT(decimal(10,2), a.presupuesto_estimado),
                                            d.PresupuestoEstimado),
           d.TemporadaViaje      = COALESCE(a.temporada_viaje,     d.TemporadaViaje),
           d.Idioma              = COALESCE(a.idioma,              d.Idioma),
           d.GrupoViaje          = COALESCE(a.grupo_viaje,         d.GrupoViaje),
           d.FuenteDatos         = 'POSTGRESQL+JSON',
           d.EjecucionIdCarga    = @EjecucionId,
           d.FechaCarga          = @ahora
    FROM dw.DimCliente d
    JOIN stg.PreferenciaArchivo a ON a.identificacion = d.Identificacion
    WHERE NOT EXISTS (
            SELECT 1 FROM etl.Error e
             WHERE e.EjecucionId    = @EjecucionId
               AND e.Fuente         = 'JSON'
               AND e.Severidad      = 'RECHAZO'
               AND e.NumeroRegistro = a.numero_registro
               AND e.ArchivoOrigen  = a.archivo_origen);

    /* ---------------- Enriquecimiento desde XML (RF-11) ---------------- */
    UPDATE d
       SET d.ServiciosAdicionales = COALESCE(x.servicios_adicionales, d.ServiciosAdicionales),
           d.FuenteDatos          = 'POSTGRESQL+XML',
           d.EjecucionIdCarga     = @EjecucionId,
           d.FechaCarga           = @ahora
    FROM dw.DimPaquete d
    JOIN stg.PaqueteArchivo x
      ON TRY_CONVERT(bigint, REPLACE(x.codigo_paquete, 'PKG-', '')) = d.PaqueteId
    WHERE NOT EXISTS (
            SELECT 1 FROM etl.Error e
             WHERE e.EjecucionId    = @EjecucionId
               AND e.Fuente         = 'XML'
               AND e.Severidad      = 'RECHAZO'
               AND e.NumeroRegistro = x.numero_registro
               AND e.ArchivoOrigen  = x.archivo_origen);

    /* ---------------- DimCanal (desde MongoDB) ------------------------- */
    MERGE dw.DimCanal AS d
    USING (
        SELECT DISTINCT
               Canal       = ISNULL(NULLIF(LTRIM(RTRIM(i.canal)), ''), 'Desconocido'),
               Dispositivo = ISNULL(NULLIF(LTRIM(RTRIM(i.dispositivo)), ''), 'Desconocido')
        FROM stg.InteraccionWeb i
    ) AS o
    ON d.Canal = o.Canal AND d.Dispositivo = o.Dispositivo
    WHEN NOT MATCHED BY TARGET THEN INSERT (Canal, Dispositivo, EsMovil)
        VALUES (o.Canal, o.Dispositivo,
                CASE WHEN o.Dispositivo IN ('Movil','Tablet','movil','tablet') THEN 1 ELSE 0 END);

    /* ---------------- Resumen ------------------------------------------ */
    SELECT [Dimension] = 'dw.DimCliente',        [Filas] = COUNT_BIG(*) FROM dw.DimCliente
    UNION ALL SELECT 'dw.DimHotel',          COUNT_BIG(*) FROM dw.DimHotel
    UNION ALL SELECT 'dw.DimTipoHabitacion', COUNT_BIG(*) FROM dw.DimTipoHabitacion
    UNION ALL SELECT 'dw.DimTour',           COUNT_BIG(*) FROM dw.DimTour
    UNION ALL SELECT 'dw.DimPaquete',        COUNT_BIG(*) FROM dw.DimPaquete
    UNION ALL SELECT 'dw.DimCanal',          COUNT_BIG(*) FROM dw.DimCanal
    UNION ALL SELECT 'dw.DimTiempo',         COUNT_BIG(*) FROM dw.DimTiempo;
END
GO

/* =====================================================================
   3. HECHOS  (recarga completa)

   Se recargan por TRUNCATE + INSERT en lugar de MERGE: con 2 millones de
   filas y una ventana de carga nocturna, la recarga completa es varias
   veces mas rapida que comparar fila por fila, y elimina el riesgo de
   quedar con hechos huerfanos si el origen borra registros.
   ===================================================================== */
CREATE PROCEDURE etl.usp_CargarHechos
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ahora datetime2(0) = SYSDATETIME();

    -- Las FK se deshabilitan durante la carga masiva y se revalidan
    -- completas al final (usp_VerificarIntegridad): validar el conjunto de
    -- una vez es mucho mas barato que validar 2 millones de filas una a una.
    ALTER TABLE dw.FactReserva            NOCHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactReservaHabitacion  NOCHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactReservaTour        NOCHECK CONSTRAINT ALL;

    TRUNCATE TABLE dw.FactReserva;
    TRUNCATE TABLE dw.FactReservaHabitacion;
    TRUNCATE TABLE dw.FactReservaTour;

    /* ---------------- FactReserva -------------------------------------- */
    INSERT INTO dw.FactReserva
        (ReservaId, FechaReservaKey, FechaInicioKey, FechaFinKey, ClienteKey,
         PaqueteKey, EstadoKey, CantidadPersonas, MontoTotal, Noches,
         DiasAnticipacion, MontoConfirmado, EsCancelada, ConteoReserva,
         EjecucionIdCarga, FechaCarga)
    SELECT
        r.ReservaId,
        etl.fn_TiempoKey(r.FechaReserva),
        etl.fn_TiempoKey(r.FechaInicio),
        etl.fn_TiempoKey(r.FechaFin),
        ISNULL(dc.ClienteKey, -1),
        ISNULL(dp.PaqueteKey, -1),
        ISNULL(de.EstadoKey,  -1),
        r.CantidadPersonas,
        r.MontoTotal,
        DATEDIFF(DAY, r.FechaInicio, r.FechaFin),
        DATEDIFF(DAY, r.FechaReserva, r.FechaInicio),
        CASE WHEN r.Estado = 'CONFIRMADA' THEN r.MontoTotal ELSE 0 END,
        CASE WHEN r.Estado = 'CANCELADA'  THEN 1 ELSE 0 END,
        1,
        @EjecucionId,
        @ahora
    FROM (
        SELECT ReservaId        = TRY_CONVERT(bigint, s.reserva_id),
               ClienteId        = TRY_CONVERT(bigint, s.cliente_id),
               PaqueteId        = TRY_CONVERT(bigint, s.paquete_id),
               FechaReserva     = TRY_CONVERT(date, s.fecha_reserva),
               FechaInicio      = TRY_CONVERT(date, s.fecha_inicio),
               FechaFin         = TRY_CONVERT(date, s.fecha_fin),
               CantidadPersonas = ISNULL(TRY_CONVERT(int, s.cantidad_personas), 1),
               MontoTotal       = ISNULL(TRY_CONVERT(decimal(12,2), s.monto_total), 0),
               Estado           = UPPER(LTRIM(RTRIM(ISNULL(s.estado, 'DESCONOCIDO'))))
        FROM stg.Reserva s
        WHERE TRY_CONVERT(bigint, s.reserva_id) IS NOT NULL
          AND NOT EXISTS (
                SELECT 1 FROM etl.Error e
                 WHERE e.EjecucionId  = @EjecucionId
                   AND e.ObjetoOrigen = 'reserva'
                   AND e.Severidad    = 'RECHAZO'
                   AND e.ClaveNegocio = s.reserva_id)
    ) r
    LEFT JOIN dw.DimCliente       dc ON dc.ClienteId = r.ClienteId
    LEFT JOIN dw.DimPaquete       dp ON dp.PaqueteId = r.PaqueteId
    LEFT JOIN dw.DimEstadoReserva de ON de.Estado    = r.Estado;

    /* ---------------- FactReservaHabitacion ---------------------------- */
    INSERT INTO dw.FactReservaHabitacion
        (ReservaHabitacionId, ReservaId, FechaInicioKey, FechaFinKey, ClienteKey,
         HotelKey, TipoHabitacionKey, EstadoKey, CantidadHabitaciones, TarifaAplicada,
         Noches, NochesHabitacion, IngresoAlojamiento, EjecucionIdCarga, FechaCarga)
    SELECT
        TRY_CONVERT(bigint, rh.reserva_habitacion_id),
        f.ReservaId,
        f.FechaInicioKey,
        f.FechaFinKey,
        f.ClienteKey,
        ISNULL(dth.HotelKey, -1),
        ISNULL(dth.TipoHabitacionKey, -1),
        f.EstadoKey,
        ISNULL(TRY_CONVERT(int, rh.cantidad_habitaciones), 1),
        ISNULL(TRY_CONVERT(decimal(10,2), rh.tarifa_aplicada), 0),
        f.Noches,
        ISNULL(TRY_CONVERT(int, rh.cantidad_habitaciones), 1) * f.Noches,
        ISNULL(TRY_CONVERT(int, rh.cantidad_habitaciones), 1) * f.Noches
            * ISNULL(TRY_CONVERT(decimal(10,2), rh.tarifa_aplicada), 0),
        @EjecucionId,
        @ahora
    FROM stg.ReservaHabitacion rh
    JOIN dw.FactReserva f
      ON f.ReservaId = TRY_CONVERT(bigint, rh.reserva_id)
    LEFT JOIN dw.DimTipoHabitacion dth
      ON dth.TipoHabitacionId = TRY_CONVERT(bigint, rh.tipo_habitacion_id)
    WHERE TRY_CONVERT(bigint, rh.reserva_habitacion_id) IS NOT NULL;

    /* ---------------- FactReservaTour ---------------------------------- */
    INSERT INTO dw.FactReservaTour
        (ReservaTourId, ReservaId, FechaInicioKey, ClienteKey, TourKey, EstadoKey,
         CantidadPersonas, PrecioAplicado, IngresoTour, ConteoTour,
         EjecucionIdCarga, FechaCarga)
    SELECT
        TRY_CONVERT(bigint, rt.reserva_tour_id),
        f.ReservaId,
        f.FechaInicioKey,
        f.ClienteKey,
        ISNULL(dt.TourKey, -1),
        f.EstadoKey,
        ISNULL(TRY_CONVERT(int, rt.cantidad_personas), 1),
        ISNULL(TRY_CONVERT(decimal(10,2), rt.precio_aplicado), 0),
        ISNULL(TRY_CONVERT(int, rt.cantidad_personas), 1)
            * ISNULL(TRY_CONVERT(decimal(10,2), rt.precio_aplicado), 0),
        1,
        @EjecucionId,
        @ahora
    FROM stg.ReservaTour rt
    JOIN dw.FactReserva f
      ON f.ReservaId = TRY_CONVERT(bigint, rt.reserva_id)
    LEFT JOIN dw.DimTour dt
      ON dt.TourId = TRY_CONVERT(bigint, rt.tour_id)
    WHERE TRY_CONVERT(bigint, rt.reserva_tour_id) IS NOT NULL;

    /* ---------------- FactResena (MongoDB, RF-12) ---------------------- */
    TRUNCATE TABLE dw.FactResena;

    INSERT INTO dw.FactResena
        (ResenaId, TiempoKey, ClienteKey, HotelKey, TourKey, PaqueteKey, TipoEntidad,
         Calificacion, EsPositiva, EsNegativa, EsVerificada, LongitudTexto, Idioma,
         ConteoResena, EjecucionIdCarga, FechaCarga)
    SELECT
        s.resena_id,
        etl.fn_TiempoKey(TRY_CONVERT(date, s.fecha)),
        ISNULL(dc.ClienteKey, -1),
        CASE WHEN UPPER(s.tipo_entidad) = 'HOTEL'   THEN ISNULL(dh.HotelKey, -1)   ELSE -1 END,
        CASE WHEN UPPER(s.tipo_entidad) = 'TOUR'    THEN ISNULL(dt.TourKey, -1)    ELSE -1 END,
        CASE WHEN UPPER(s.tipo_entidad) = 'PAQUETE' THEN ISNULL(dp.PaqueteKey, -1) ELSE -1 END,
        UPPER(ISNULL(s.tipo_entidad, 'DESCONOCIDO')),
        TRY_CONVERT(tinyint, s.calificacion),
        CASE WHEN TRY_CONVERT(tinyint, s.calificacion) >= 4 THEN 1 ELSE 0 END,
        CASE WHEN TRY_CONVERT(tinyint, s.calificacion) <= 2 THEN 1 ELSE 0 END,
        CASE WHEN UPPER(s.verificada) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END,
        LEN(ISNULL(s.comentario, '')),
        s.idioma,
        1,
        @EjecucionId,
        @ahora
    FROM stg.Resena s
    LEFT JOIN dw.DimCliente dc ON dc.ClienteId = TRY_CONVERT(bigint, s.cliente_id)
    LEFT JOIN dw.DimHotel   dh ON dh.HotelId   = TRY_CONVERT(bigint, s.entidad_id)
                              AND UPPER(s.tipo_entidad) = 'HOTEL'
    LEFT JOIN dw.DimTour    dt ON dt.TourId    = TRY_CONVERT(bigint, s.entidad_id)
                              AND UPPER(s.tipo_entidad) = 'TOUR'
    LEFT JOIN dw.DimPaquete dp ON dp.PaqueteId = TRY_CONVERT(bigint, s.entidad_id)
                              AND UPPER(s.tipo_entidad) = 'PAQUETE'
    WHERE s.resena_id IS NOT NULL
      AND NOT EXISTS (
            SELECT 1 FROM etl.Error e
             WHERE e.EjecucionId  = @EjecucionId
               AND e.ObjetoOrigen = 'resenas'
               AND e.Severidad    = 'RECHAZO'
               AND e.ClaveNegocio = s.resena_id);

    /* ---------------- FactInteraccionWeb (MongoDB, RF-13) -------------- */
    TRUNCATE TABLE dw.FactInteraccionWeb;

    INSERT INTO dw.FactInteraccionWeb
        (InteraccionId, TiempoKey, ClienteKey, CanalKey, HotelKey, TourKey, TipoEvento,
         DestinoBuscado, DuracionSegundos, EsConversion, ConteoEvento,
         EjecucionIdCarga, FechaCarga)
    SELECT
        i.interaccion_id,
        etl.fn_TiempoKey(TRY_CONVERT(date, i.fecha_evento)),
        ISNULL(dc.ClienteKey, -1),
        ISNULL(dk.CanalKey, -1),
        CASE WHEN UPPER(i.entidad_tipo) = 'HOTEL' THEN ISNULL(dh.HotelKey, -1) ELSE -1 END,
        CASE WHEN UPPER(i.entidad_tipo) = 'TOUR'  THEN ISNULL(dt.TourKey, -1)  ELSE -1 END,
        ISNULL(i.tipo_evento, 'desconocido'),
        i.destino_buscado,
        ISNULL(TRY_CONVERT(int, i.duracion_seg), 0),
        CASE WHEN UPPER(i.convirtio) IN ('TRUE','T','1','SI') THEN 1 ELSE 0 END,
        1,
        @EjecucionId,
        @ahora
    FROM stg.InteraccionWeb i
    LEFT JOIN dw.DimCliente dc ON dc.ClienteId = TRY_CONVERT(bigint, i.cliente_id)
    LEFT JOIN dw.DimCanal   dk ON dk.Canal       = ISNULL(NULLIF(LTRIM(RTRIM(i.canal)), ''), 'Desconocido')
                              AND dk.Dispositivo = ISNULL(NULLIF(LTRIM(RTRIM(i.dispositivo)), ''), 'Desconocido')
    LEFT JOIN dw.DimHotel   dh ON dh.HotelId   = TRY_CONVERT(bigint, i.entidad_id)
                              AND UPPER(i.entidad_tipo) = 'HOTEL'
    LEFT JOIN dw.DimTour    dt ON dt.TourId    = TRY_CONVERT(bigint, i.entidad_id)
                              AND UPPER(i.entidad_tipo) = 'TOUR'
    WHERE i.interaccion_id IS NOT NULL;

    /* ---------------- Resumen ------------------------------------------ */
    SELECT [Hecho] = 'dw.FactReserva',           [Filas] = COUNT_BIG(*) FROM dw.FactReserva
    UNION ALL SELECT 'dw.FactReservaHabitacion', COUNT_BIG(*) FROM dw.FactReservaHabitacion
    UNION ALL SELECT 'dw.FactReservaTour',       COUNT_BIG(*) FROM dw.FactReservaTour
    UNION ALL SELECT 'dw.FactResena',            COUNT_BIG(*) FROM dw.FactResena
    UNION ALL SELECT 'dw.FactInteraccionWeb',    COUNT_BIG(*) FROM dw.FactInteraccionWeb;
END
GO

/* =====================================================================
   4. FactOcupacionDiaria

   "Porcentaje de ocupacion hotelera" es el primer KPI del escenario.
   Una reserva de N noches ocupa N dias distintos, asi que hay que explotar
   la estadia. Se hace aqui, una sola vez, y no en DAX sobre 2 millones de
   filas, que seria inviable en el reporte.

   Solo cuentan las reservas CONFIRMADAS: una reserva cancelada o pendiente
   no ocupa una habitacion.
   ===================================================================== */
CREATE PROCEDURE etl.usp_CargarOcupacionDiaria
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ahora datetime2(0) = SYSDATETIME();

    TRUNCATE TABLE dw.FactOcupacionDiaria;

    ;WITH Estadia AS (
        -- Una fila por (reserva-habitacion x noche ocupada).
        -- La noche de salida no se cuenta: se ocupa desde la llegada hasta
        -- la vispera del check-out.
        SELECT
            HotelKey     = frh.HotelKey,
            Fecha        = DATEADD(DAY, n.n - 1, dt.Fecha),
            Habitaciones = frh.CantidadHabitaciones,
            Personas     = fr.CantidadPersonas,
            Ingreso      = frh.CantidadHabitaciones * frh.TarifaAplicada,
            ReservaId    = frh.ReservaId
        FROM dw.FactReservaHabitacion frh
        JOIN dw.FactReserva      fr ON fr.ReservaId = frh.ReservaId
        JOIN dw.DimEstadoReserva de ON de.EstadoKey = fr.EstadoKey
        JOIN dw.DimTiempo        dt ON dt.TiempoKey = frh.FechaInicioKey
        JOIN etl.Numeros          n ON n.n <= frh.Noches
        WHERE de.EsConfirmada = 1
          AND frh.Noches BETWEEN 1 AND 4000
          AND frh.HotelKey <> -1
    ),
    Capacidad AS (
        -- Denominador: habitaciones publicadas por hotel (capacidad instalada).
        SELECT HotelKey, Disponibles = SUM(CantidadDisponible)
        FROM dw.DimTipoHabitacion
        WHERE Activo = 1 AND HotelKey <> -1
        GROUP BY HotelKey
    )
    INSERT INTO dw.FactOcupacionDiaria
        (TiempoKey, HotelKey, HabitacionesOcupadas, HabitacionesDisponibles,
         PersonasAlojadas, IngresoDia, ReservasActivas, EjecucionIdCarga, FechaCarga)
    SELECT
        etl.fn_TiempoKey(e.Fecha),
        e.HotelKey,
        SUM(e.Habitaciones),
        MAX(ISNULL(c.Disponibles, 0)),
        SUM(e.Personas),
        SUM(e.Ingreso),
        COUNT(DISTINCT e.ReservaId),
        @EjecucionId,
        @ahora
    FROM Estadia e
    LEFT JOIN Capacidad c ON c.HotelKey = e.HotelKey
    WHERE e.Fecha BETWEEN '2020-01-01' AND '2027-12-31'
    GROUP BY etl.fn_TiempoKey(e.Fecha), e.HotelKey;

    SELECT [Hecho] = 'dw.FactOcupacionDiaria',
           [Filas] = COUNT_BIG(*),
           [OcupacionPromedio] = CAST(100.0 * SUM(CAST(HabitacionesOcupadas AS bigint))
                                      / NULLIF(SUM(CAST(HabitacionesDisponibles AS bigint)), 0)
                                      AS decimal(5,2))
    FROM dw.FactOcupacionDiaria;
END
GO

/* =====================================================================
   5. Verificacion de integridad

   Re-habilita las FK WITH CHECK. Si alguna falla, hay hechos apuntando a
   dimensiones inexistentes y la carga no debe darse por buena.
   ===================================================================== */
CREATE PROCEDURE etl.usp_VerificarIntegridad
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;

    ALTER TABLE dw.FactReserva            WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactReservaHabitacion  WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactReservaTour        WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactOcupacionDiaria    WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactResena             WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dw.FactInteraccionWeb     WITH CHECK CHECK CONSTRAINT ALL;

    -- Estadisticas al dia: el Integrante 2 y el 4 miden planes sobre esto.
    UPDATE STATISTICS dw.FactReserva            WITH FULLSCAN;
    UPDATE STATISTICS dw.FactReservaHabitacion  WITH FULLSCAN;
    UPDATE STATISTICS dw.FactReservaTour        WITH FULLSCAN;
    UPDATE STATISTICS dw.FactOcupacionDiaria    WITH FULLSCAN;
    UPDATE STATISTICS dw.FactResena             WITH FULLSCAN;
    UPDATE STATISTICS dw.FactInteraccionWeb     WITH FULLSCAN;

    SELECT [Restriccion]   = fk.name,
           [Tabla]         = OBJECT_NAME(fk.parent_object_id),
           [NoConfiable]   = fk.is_not_trusted,
           [Deshabilitada] = fk.is_disabled
    FROM sys.foreign_keys fk
    WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) = 'dw'
      AND (fk.is_not_trusted = 1 OR fk.is_disabled = 1);
END
GO

PRINT '';
PRINT '=== Procedimientos de transformacion creados ===';
SELECT [Procedimiento] = s.name + '.' + p.name
FROM sys.procedures p
JOIN sys.schemas s ON s.schema_id = p.schema_id
WHERE s.name = 'etl'
ORDER BY p.name;
GO

PRINT '>> Transformacion lista. Siguiente: 45-vistas-powerbi.sql';
GO
