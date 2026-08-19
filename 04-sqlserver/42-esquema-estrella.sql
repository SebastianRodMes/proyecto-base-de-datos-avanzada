/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   42-esquema-estrella.sql

   Modelo dimensional (esquema estrella) de TurismoDW.

   Grano de cada tabla de hechos -- decidido antes que cualquier columna,
   porque es lo que hace que las medidas se puedan sumar sin doble conteo:

     FactReserva            1 fila = 1 reserva
     FactReservaHabitacion  1 fila = 1 reserva x tipo de habitacion
     FactReservaTour        1 fila = 1 reserva x tour
     FactOcupacionDiaria    1 fila = 1 hotel x dia          (snapshot periodico)
     FactResena             1 fila = 1 resena
     FactInteraccionWeb     1 fila = 1 evento de navegacion

   Por que existe FactOcupacionDiaria:
     "Porcentaje de ocupacion hotelera" es el KPI principal del escenario y
     no se puede calcular correctamente desde el grano de reserva: una
     reserva de 5 noches ocupa 5 dias distintos. Explotar la estadia en
     DAX sobre 2 millones de filas seria inviable, asi que el ETL la
     materializa una sola vez a grano hotel-dia.

   Convenciones:
     * Claves subrogadas INT IDENTITY con sufijo Key.
     * Cada dimension tiene una fila -1 "No aplica / Desconocido" para que
       los hechos nunca queden huerfanos y los JOIN sean INNER.
     * Las claves de negocio del origen se conservan (columnas *Id) para
       la trazabilidad exigida por RNF-05.
     * Las fechas usan clave entera yyyymmdd: entero de 4 bytes, legible en
       depuracion y compatible con el rango de particion del Integrante 2.
     * Dimensiones en FG_DIM, hechos en FG_FACT.

   IMPORTANTE (frontera con el Integrante 2): las tablas de hechos se crean
   con indice agrupado pero SIN indices no agrupados y SIN esquema de
   particion, a proposito, para que su comparacion de rendimiento
   "antes / despues" parta de una linea base limpia.

   Uso: sqlcmd -S TURISMODW -E -C -d TurismoDW -i 42-esquema-estrella.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

/* ---------------------------------------------------------------------
   Limpieza: hechos antes que dimensiones (dependen de ellas)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dw.FactInteraccionWeb;
DROP TABLE IF EXISTS dw.FactResena;
DROP TABLE IF EXISTS dw.FactOcupacionDiaria;
DROP TABLE IF EXISTS dw.FactReservaTour;
DROP TABLE IF EXISTS dw.FactReservaHabitacion;
DROP TABLE IF EXISTS dw.FactReserva;
DROP TABLE IF EXISTS dw.DimCanal;
DROP TABLE IF EXISTS dw.DimEstadoReserva;
DROP TABLE IF EXISTS dw.DimPaquete;
DROP TABLE IF EXISTS dw.DimTour;
DROP TABLE IF EXISTS dw.DimTipoHabitacion;
DROP TABLE IF EXISTS dw.DimHotel;
DROP TABLE IF EXISTS dw.DimCliente;
DROP TABLE IF EXISTS dw.DimTiempo;
GO

/* =====================================================================
   DIMENSIONES
   ===================================================================== */

/* ---------------------------------------------------------------------
   DimTiempo - dimension de calendario, generada, no extraida.
   Es la unica dimension cuya clave NO es IDENTITY: yyyymmdd permite
   calcular la clave desde una fecha sin buscarla, lo que ahorra un JOIN
   por cada fila de hechos durante la carga.
   --------------------------------------------------------------------- */
CREATE TABLE dw.DimTiempo (
    TiempoKey            int          NOT NULL,          -- yyyymmdd
    Fecha                date         NOT NULL,
    Anio                 smallint     NOT NULL,
    Trimestre            tinyint      NOT NULL,
    NombreTrimestre      varchar(10)  NOT NULL,
    Mes                  tinyint      NOT NULL,
    NombreMes            varchar(20)  NOT NULL,
    NombreMesCorto       varchar(10)  NOT NULL,
    AnioMes              int          NOT NULL,          -- yyyymm, para ordenar
    Semana               tinyint      NOT NULL,
    DiaDelMes            tinyint      NOT NULL,
    DiaDelAnio           smallint     NOT NULL,
    DiaSemana            tinyint      NOT NULL,
    NombreDiaSemana      varchar(20)  NOT NULL,
    EsFinDeSemana        bit          NOT NULL,
    -- Temporadas turisticas del escenario (Costa Rica y region):
    --   Alta  = diciembre-abril y julio (seca + vacaciones)
    --   Verde = mayo-junio y agosto-noviembre (lluviosa)
    TemporadaTuristica   varchar(20)  NOT NULL,
    EsTemporadaAlta      bit          NOT NULL,
    Semestre             tinyint      NOT NULL,
    CONSTRAINT PK_DimTiempo PRIMARY KEY CLUSTERED (TiempoKey)
) ON FG_DIM;
GO

/* ---------------------------------------------------------------------
   DimCliente - SCD tipo 1 (se sobrescribe; el escenario no pide historia
   de cambios de cliente). Aplana cliente + preferencia_cliente para que el
   analisis de perfil no requiera un snowflake.
   --------------------------------------------------------------------- */
CREATE TABLE dw.DimCliente (
    ClienteKey           int           NOT NULL IDENTITY(1,1),
    ClienteId            bigint        NOT NULL,          -- clave de negocio (PostgreSQL)
    Identificacion       nvarchar(50)  NOT NULL,
    NombreCompleto       nvarchar(220) NOT NULL,
    Nombre               nvarchar(100) NOT NULL,
    Apellidos            nvarchar(100) NOT NULL,
    Correo               nvarchar(150) NULL,
    PaisOrigen           nvarchar(60)  NOT NULL,
    FechaNacimiento      date          NULL,
    Edad                 smallint      NULL,
    RangoEdad            varchar(20)   NOT NULL,
    Activo               bit           NOT NULL,
    FechaRegistro        date          NULL,
    -- Atributos de preferencia (RF-09), aplanados desde preferencia_cliente
    DestinosPreferidos   nvarchar(200) NULL,
    TipoAlojamiento      nvarchar(100) NULL,
    ActividadesFavoritas nvarchar(200) NULL,
    PresupuestoEstimado  decimal(10,2) NULL,
    RangoPresupuesto     varchar(30)   NOT NULL,
    TemporadaViaje       nvarchar(50)  NULL,
    Idioma               varchar(10)   NULL,             -- desde el JSONB
    Dieta                varchar(30)   NULL,
    GrupoViaje           varchar(30)   NULL,
    EsVip                bit           NOT NULL,
    FuenteDatos          varchar(20)   NOT NULL,
    EjecucionIdCarga     int           NOT NULL,
    FechaCarga           datetime2(0)  NOT NULL,
    CONSTRAINT PK_DimCliente PRIMARY KEY CLUSTERED (ClienteKey),
    CONSTRAINT UQ_DimCliente_Negocio UNIQUE (ClienteId)
) ON FG_DIM;
GO

CREATE TABLE dw.DimHotel (
    HotelKey         int           NOT NULL IDENTITY(1,1),
    HotelId          bigint        NOT NULL,
    Nombre           nvarchar(150) NOT NULL,
    Categoria        nvarchar(50)  NOT NULL,
    NumeroEstrellas  tinyint       NULL,
    Ciudad           nvarchar(80)  NOT NULL,
    Pais             nvarchar(60)  NOT NULL,
    Direccion        nvarchar(200) NULL,
    Servicios        nvarchar(300) NULL,
    CapacidadTotal   int           NULL,
    RangoCapacidad   varchar(20)   NOT NULL,
    Activo           bit           NOT NULL,
    EjecucionIdCarga int           NOT NULL,
    FechaCarga       datetime2(0)  NOT NULL,
    CONSTRAINT PK_DimHotel PRIMARY KEY CLUSTERED (HotelKey),
    CONSTRAINT UQ_DimHotel_Negocio UNIQUE (HotelId)
) ON FG_DIM;
GO

CREATE TABLE dw.DimTipoHabitacion (
    TipoHabitacionKey  int           NOT NULL IDENTITY(1,1),
    TipoHabitacionId   bigint        NOT NULL,
    HotelId            bigint        NOT NULL,
    HotelKey           int           NOT NULL,
    Nombre             nvarchar(100) NOT NULL,
    CapacidadPersonas  int           NOT NULL,
    TarifaBase         decimal(10,2) NOT NULL,
    RangoTarifa        varchar(30)   NOT NULL,
    CantidadDisponible int           NOT NULL,
    Activo             bit           NOT NULL,
    EjecucionIdCarga   int           NOT NULL,
    FechaCarga         datetime2(0)  NOT NULL,
    CONSTRAINT PK_DimTipoHabitacion PRIMARY KEY CLUSTERED (TipoHabitacionKey),
    CONSTRAINT UQ_DimTipoHab_Negocio UNIQUE (TipoHabitacionId)
) ON FG_DIM;
GO

CREATE TABLE dw.DimTour (
    TourKey          int           NOT NULL IDENTITY(1,1),
    TourId           bigint        NOT NULL,
    Nombre           nvarchar(150) NOT NULL,
    Destino          nvarchar(100) NOT NULL,
    TipoActividad    nvarchar(60)  NOT NULL,   -- derivado del nombre del tour
    Proveedor        nvarchar(150) NULL,
    DuracionHoras    int           NULL,
    RangoDuracion    varchar(30)   NOT NULL,
    CupoMaximo       int           NULL,
    Precio           decimal(10,2) NULL,
    Activo           bit           NOT NULL,
    EjecucionIdCarga int           NOT NULL,
    FechaCarga       datetime2(0)  NOT NULL,
    CONSTRAINT PK_DimTour PRIMARY KEY CLUSTERED (TourKey),
    CONSTRAINT UQ_DimTour_Negocio UNIQUE (TourId)
) ON FG_DIM;
GO

CREATE TABLE dw.DimPaquete (
    PaqueteKey           int           NOT NULL IDENTITY(1,1),
    PaqueteId            bigint        NOT NULL,
    Nombre               nvarchar(150) NOT NULL,
    TipoPaquete          nvarchar(60)  NOT NULL,   -- Aventura / Cultural / ...
    DuracionDias         int           NULL,
    RangoDuracion        varchar(30)   NOT NULL,
    PrecioTotal          decimal(10,2) NULL,
    RangoPrecio          varchar(30)   NOT NULL,
    ServiciosAdicionales nvarchar(300) NULL,
    Activo               bit           NOT NULL,
    FuenteDatos          varchar(20)   NOT NULL,   -- POSTGRESQL | XML
    EjecucionIdCarga     int           NOT NULL,
    FechaCarga           datetime2(0)  NOT NULL,
    CONSTRAINT PK_DimPaquete PRIMARY KEY CLUSTERED (PaqueteKey),
    CONSTRAINT UQ_DimPaquete_Negocio UNIQUE (PaqueteId)
) ON FG_DIM;
GO

/* ---------------------------------------------------------------------
   DimEstadoReserva - dimension pequena; se carga por catalogo, no por ETL,
   porque los estados son un dominio cerrado de la aplicacion.
   --------------------------------------------------------------------- */
CREATE TABLE dw.DimEstadoReserva (
    EstadoKey        int          NOT NULL IDENTITY(1,1),
    Estado           varchar(30)  NOT NULL,
    Descripcion      nvarchar(100) NOT NULL,
    EsConfirmada     bit          NOT NULL,
    EsCancelada      bit          NOT NULL,
    CuentaParaIngreso bit         NOT NULL,   -- solo CONFIRMADA suma ingresos
    CONSTRAINT PK_DimEstadoReserva PRIMARY KEY CLUSTERED (EstadoKey),
    CONSTRAINT UQ_DimEstadoReserva UNIQUE (Estado)
) ON FG_DIM;
GO

CREATE TABLE dw.DimCanal (
    CanalKey     int          NOT NULL IDENTITY(1,1),
    Canal        varchar(50)  NOT NULL,
    Dispositivo  varchar(40)  NOT NULL,
    EsMovil      bit          NOT NULL,
    CONSTRAINT PK_DimCanal PRIMARY KEY CLUSTERED (CanalKey),
    CONSTRAINT UQ_DimCanal UNIQUE (Canal, Dispositivo)
) ON FG_DIM;
GO

/* =====================================================================
   HECHOS
   ===================================================================== */

/* ---------------------------------------------------------------------
   FactReserva - grano: 1 reserva.
   FechaInicioKey es la CLAVE DE PARTICION acordada con el Integrante 2:
   es la fecha por la que se consulta y se archiva el historico, y es la
   que reparte las filas de forma pareja entre 2021 y 2026.
   --------------------------------------------------------------------- */
CREATE TABLE dw.FactReserva (
    ReservaKey          bigint        NOT NULL IDENTITY(1,1),
    ReservaId           bigint        NOT NULL,   -- clave de negocio, trazabilidad
    -- Claves foraneas dimensionales
    FechaReservaKey     int           NOT NULL,
    FechaInicioKey      int           NOT NULL,   -- <<< clave de particion
    FechaFinKey         int           NOT NULL,
    ClienteKey          int           NOT NULL,
    PaqueteKey          int           NOT NULL,
    EstadoKey           int           NOT NULL,
    -- Medidas aditivas
    CantidadPersonas    int           NOT NULL,
    MontoTotal          decimal(12,2) NOT NULL,
    Noches              int           NOT NULL,
    DiasAnticipacion    int           NOT NULL,
    -- Medidas semiaditivas / banderas para promedios ponderados
    MontoConfirmado     decimal(12,2) NOT NULL,   -- 0 si no esta CONFIRMADA
    EsCancelada         bit           NOT NULL,
    ConteoReserva       tinyint       NOT NULL,   -- siempre 1: facilita COUNT como SUM
    -- Trazabilidad (RNF-05)
    EjecucionIdCarga    int           NOT NULL,
    FechaCarga          datetime2(0)  NOT NULL,
    CONSTRAINT PK_FactReserva PRIMARY KEY CLUSTERED (ReservaKey)
) ON FG_FACT;
GO

CREATE TABLE dw.FactReservaHabitacion (
    ReservaHabitacionKey bigint        NOT NULL IDENTITY(1,1),
    ReservaHabitacionId  bigint        NOT NULL,
    ReservaId            bigint        NOT NULL,
    FechaInicioKey       int           NOT NULL,
    FechaFinKey          int           NOT NULL,
    ClienteKey           int           NOT NULL,
    HotelKey             int           NOT NULL,
    TipoHabitacionKey    int           NOT NULL,
    EstadoKey            int           NOT NULL,
    CantidadHabitaciones int           NOT NULL,
    TarifaAplicada       decimal(10,2) NOT NULL,
    Noches               int           NOT NULL,
    NochesHabitacion     int           NOT NULL,   -- habitaciones x noches
    IngresoAlojamiento   decimal(12,2) NOT NULL,
    EjecucionIdCarga     int           NOT NULL,
    FechaCarga           datetime2(0)  NOT NULL,
    CONSTRAINT PK_FactReservaHabitacion PRIMARY KEY CLUSTERED (ReservaHabitacionKey)
) ON FG_FACT;
GO

CREATE TABLE dw.FactReservaTour (
    ReservaTourKey    bigint        NOT NULL IDENTITY(1,1),
    ReservaTourId     bigint        NOT NULL,
    ReservaId         bigint        NOT NULL,
    FechaInicioKey    int           NOT NULL,
    ClienteKey        int           NOT NULL,
    TourKey           int           NOT NULL,
    EstadoKey         int           NOT NULL,
    CantidadPersonas  int           NOT NULL,
    PrecioAplicado    decimal(10,2) NOT NULL,
    IngresoTour       decimal(12,2) NOT NULL,
    ConteoTour        tinyint       NOT NULL,
    EjecucionIdCarga  int           NOT NULL,
    FechaCarga        datetime2(0)  NOT NULL,
    CONSTRAINT PK_FactReservaTour PRIMARY KEY CLUSTERED (ReservaTourKey)
) ON FG_FACT;
GO

/* ---------------------------------------------------------------------
   FactOcupacionDiaria - snapshot periodico, grano hotel x dia.
   Se calcula una vez en el ETL explotando cada estadia en sus dias.
   PorcentajeOcupacion NO se almacena como medida sumable: se guardan
   numerador y denominador y el porcentaje se calcula en DAX
   (SUM(ocupadas) / SUM(disponibles)), que es lo unico correcto al agregar.
   --------------------------------------------------------------------- */
CREATE TABLE dw.FactOcupacionDiaria (
    OcupacionKey            bigint       NOT NULL IDENTITY(1,1),
    TiempoKey               int          NOT NULL,
    HotelKey                int          NOT NULL,
    HabitacionesOcupadas    int          NOT NULL,   -- numerador
    HabitacionesDisponibles int          NOT NULL,   -- denominador
    PersonasAlojadas        int          NOT NULL,
    IngresoDia              decimal(12,2) NOT NULL,
    ReservasActivas         int          NOT NULL,
    EjecucionIdCarga        int          NOT NULL,
    FechaCarga              datetime2(0) NOT NULL,
    CONSTRAINT PK_FactOcupacionDiaria PRIMARY KEY CLUSTERED (OcupacionKey)
) ON FG_FACT;
GO

/* ---------------------------------------------------------------------
   FactResena - grano: 1 resena (origen MongoDB, RF-12).
   --------------------------------------------------------------------- */
CREATE TABLE dw.FactResena (
    ResenaKey        bigint        NOT NULL IDENTITY(1,1),
    ResenaId         nvarchar(50)  NOT NULL,   -- ObjectId de MongoDB
    TiempoKey        int           NOT NULL,
    ClienteKey       int           NOT NULL,
    HotelKey         int           NOT NULL,   -- -1 si la resena no es de hotel
    TourKey          int           NOT NULL,
    PaqueteKey       int           NOT NULL,
    TipoEntidad      varchar(20)   NOT NULL,
    Calificacion     tinyint       NOT NULL,   -- 1..5
    EsPositiva       bit           NOT NULL,   -- calificacion >= 4
    EsNegativa       bit           NOT NULL,   -- calificacion <= 2
    EsVerificada     bit           NOT NULL,
    LongitudTexto    int           NOT NULL,
    Idioma           varchar(10)   NULL,
    ConteoResena     tinyint       NOT NULL,
    EjecucionIdCarga int           NOT NULL,
    FechaCarga       datetime2(0)  NOT NULL,
    CONSTRAINT PK_FactResena PRIMARY KEY CLUSTERED (ResenaKey)
) ON FG_FACT;
GO

/* ---------------------------------------------------------------------
   FactInteraccionWeb - grano: 1 evento de navegacion (MongoDB, RF-13).
   --------------------------------------------------------------------- */
CREATE TABLE dw.FactInteraccionWeb (
    InteraccionKey   bigint       NOT NULL IDENTITY(1,1),
    InteraccionId    nvarchar(50) NOT NULL,
    TiempoKey        int          NOT NULL,
    ClienteKey       int          NOT NULL,   -- -1 en sesiones anonimas
    CanalKey         int          NOT NULL,
    HotelKey         int          NOT NULL,
    TourKey          int          NOT NULL,
    TipoEvento       varchar(40)  NOT NULL,
    DestinoBuscado   nvarchar(150) NULL,
    DuracionSegundos int          NOT NULL,
    EsConversion     bit          NOT NULL,
    ConteoEvento     tinyint      NOT NULL,
    EjecucionIdCarga int          NOT NULL,
    FechaCarga       datetime2(0) NOT NULL,
    CONSTRAINT PK_FactInteraccionWeb PRIMARY KEY CLUSTERED (InteraccionKey)
) ON FG_FACT;
GO

/* =====================================================================
   INTEGRIDAD REFERENCIAL
   Las FK se declaran WITH NOCHECK y se deshabilitan durante la carga
   masiva; el ETL las re-habilita WITH CHECK al final, lo que valida todo
   el conjunto de una vez en lugar de fila por fila.
   ===================================================================== */

ALTER TABLE dw.FactReserva ADD
    CONSTRAINT FK_FactReserva_FechaReserva FOREIGN KEY (FechaReservaKey) REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FactReserva_FechaInicio  FOREIGN KEY (FechaInicioKey)  REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FactReserva_FechaFin     FOREIGN KEY (FechaFinKey)     REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FactReserva_Cliente      FOREIGN KEY (ClienteKey)      REFERENCES dw.DimCliente(ClienteKey),
    CONSTRAINT FK_FactReserva_Paquete      FOREIGN KEY (PaqueteKey)      REFERENCES dw.DimPaquete(PaqueteKey),
    CONSTRAINT FK_FactReserva_Estado       FOREIGN KEY (EstadoKey)       REFERENCES dw.DimEstadoReserva(EstadoKey);

ALTER TABLE dw.FactReservaHabitacion ADD
    CONSTRAINT FK_FRH_FechaInicio    FOREIGN KEY (FechaInicioKey)    REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FRH_FechaFin       FOREIGN KEY (FechaFinKey)       REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FRH_Cliente        FOREIGN KEY (ClienteKey)        REFERENCES dw.DimCliente(ClienteKey),
    CONSTRAINT FK_FRH_Hotel          FOREIGN KEY (HotelKey)          REFERENCES dw.DimHotel(HotelKey),
    CONSTRAINT FK_FRH_TipoHabitacion FOREIGN KEY (TipoHabitacionKey) REFERENCES dw.DimTipoHabitacion(TipoHabitacionKey),
    CONSTRAINT FK_FRH_Estado         FOREIGN KEY (EstadoKey)         REFERENCES dw.DimEstadoReserva(EstadoKey);

ALTER TABLE dw.FactReservaTour ADD
    CONSTRAINT FK_FRT_FechaInicio FOREIGN KEY (FechaInicioKey) REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FRT_Cliente     FOREIGN KEY (ClienteKey)     REFERENCES dw.DimCliente(ClienteKey),
    CONSTRAINT FK_FRT_Tour        FOREIGN KEY (TourKey)        REFERENCES dw.DimTour(TourKey),
    CONSTRAINT FK_FRT_Estado      FOREIGN KEY (EstadoKey)      REFERENCES dw.DimEstadoReserva(EstadoKey);

ALTER TABLE dw.FactOcupacionDiaria ADD
    CONSTRAINT FK_FOD_Tiempo FOREIGN KEY (TiempoKey) REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FOD_Hotel  FOREIGN KEY (HotelKey)  REFERENCES dw.DimHotel(HotelKey);

ALTER TABLE dw.FactResena ADD
    CONSTRAINT FK_FRes_Tiempo  FOREIGN KEY (TiempoKey)  REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FRes_Cliente FOREIGN KEY (ClienteKey) REFERENCES dw.DimCliente(ClienteKey),
    CONSTRAINT FK_FRes_Hotel   FOREIGN KEY (HotelKey)   REFERENCES dw.DimHotel(HotelKey),
    CONSTRAINT FK_FRes_Tour    FOREIGN KEY (TourKey)    REFERENCES dw.DimTour(TourKey),
    CONSTRAINT FK_FRes_Paquete FOREIGN KEY (PaqueteKey) REFERENCES dw.DimPaquete(PaqueteKey);

ALTER TABLE dw.FactInteraccionWeb ADD
    CONSTRAINT FK_FIW_Tiempo  FOREIGN KEY (TiempoKey)  REFERENCES dw.DimTiempo(TiempoKey),
    CONSTRAINT FK_FIW_Cliente FOREIGN KEY (ClienteKey) REFERENCES dw.DimCliente(ClienteKey),
    CONSTRAINT FK_FIW_Canal   FOREIGN KEY (CanalKey)   REFERENCES dw.DimCanal(CanalKey),
    CONSTRAINT FK_FIW_Hotel   FOREIGN KEY (HotelKey)   REFERENCES dw.DimHotel(HotelKey),
    CONSTRAINT FK_FIW_Tour    FOREIGN KEY (TourKey)    REFERENCES dw.DimTour(TourKey);

ALTER TABLE dw.DimTipoHabitacion ADD
    CONSTRAINT FK_DimTipoHab_Hotel FOREIGN KEY (HotelKey) REFERENCES dw.DimHotel(HotelKey);
GO

/* =====================================================================
   Unicidad de las claves de negocio en los hechos.
   Estos indices no son "tuning": son restricciones de calidad que impiden
   que una segunda corrida del ETL duplique filas. El tuning de consulta
   (indices de cobertura, columnstore) es del Integrante 2.
   ===================================================================== */
CREATE UNIQUE INDEX UQ_FactReserva_Negocio  ON dw.FactReserva (ReservaId)                 ON FG_IDX;
CREATE UNIQUE INDEX UQ_FRH_Negocio          ON dw.FactReservaHabitacion (ReservaHabitacionId) ON FG_IDX;
CREATE UNIQUE INDEX UQ_FRT_Negocio          ON dw.FactReservaTour (ReservaTourId)         ON FG_IDX;
CREATE UNIQUE INDEX UQ_FOD_Negocio          ON dw.FactOcupacionDiaria (TiempoKey, HotelKey) ON FG_IDX;
CREATE UNIQUE INDEX UQ_FRes_Negocio         ON dw.FactResena (ResenaId)                   ON FG_IDX;
CREATE UNIQUE INDEX UQ_FIW_Negocio          ON dw.FactInteraccionWeb (InteraccionId)      ON FG_IDX;
GO

/* =====================================================================
   Filas "No aplica" (-1) en cada dimension.
   Permiten que todo hecho tenga una clave valida aunque el origen venga
   incompleto, de modo que ninguna medida se pierda al hacer INNER JOIN.
   ===================================================================== */

SET IDENTITY_INSERT dw.DimCliente ON;
INSERT INTO dw.DimCliente (ClienteKey, ClienteId, Identificacion, NombreCompleto, Nombre,
        Apellidos, Correo, PaisOrigen, FechaNacimiento, Edad, RangoEdad, Activo,
        FechaRegistro, RangoPresupuesto, EsVip, FuenteDatos, EjecucionIdCarga, FechaCarga)
VALUES (-1, -1, 'N/A', 'No aplica', 'No aplica', 'No aplica', NULL, 'No aplica',
        NULL, NULL, 'No aplica', 0, NULL, 'No aplica', 0, 'SISTEMA', 0, SYSDATETIME());
SET IDENTITY_INSERT dw.DimCliente OFF;

SET IDENTITY_INSERT dw.DimHotel ON;
INSERT INTO dw.DimHotel (HotelKey, HotelId, Nombre, Categoria, Ciudad, Pais,
        RangoCapacidad, Activo, EjecucionIdCarga, FechaCarga)
VALUES (-1, -1, 'No aplica', 'No aplica', 'No aplica', 'No aplica', 'No aplica', 0, 0, SYSDATETIME());
SET IDENTITY_INSERT dw.DimHotel OFF;

SET IDENTITY_INSERT dw.DimTipoHabitacion ON;
INSERT INTO dw.DimTipoHabitacion (TipoHabitacionKey, TipoHabitacionId, HotelId, HotelKey,
        Nombre, CapacidadPersonas, TarifaBase, RangoTarifa, CantidadDisponible, Activo,
        EjecucionIdCarga, FechaCarga)
VALUES (-1, -1, -1, -1, 'No aplica', 0, 0, 'No aplica', 0, 0, 0, SYSDATETIME());
SET IDENTITY_INSERT dw.DimTipoHabitacion OFF;

SET IDENTITY_INSERT dw.DimTour ON;
INSERT INTO dw.DimTour (TourKey, TourId, Nombre, Destino, TipoActividad, RangoDuracion,
        Activo, EjecucionIdCarga, FechaCarga)
VALUES (-1, -1, 'No aplica', 'No aplica', 'No aplica', 'No aplica', 0, 0, SYSDATETIME());
SET IDENTITY_INSERT dw.DimTour OFF;

SET IDENTITY_INSERT dw.DimPaquete ON;
INSERT INTO dw.DimPaquete (PaqueteKey, PaqueteId, Nombre, TipoPaquete, RangoDuracion,
        RangoPrecio, Activo, FuenteDatos, EjecucionIdCarga, FechaCarga)
VALUES (-1, -1, 'Sin paquete', 'Sin paquete', 'No aplica', 'No aplica', 0, 'SISTEMA', 0, SYSDATETIME());
SET IDENTITY_INSERT dw.DimPaquete OFF;
GO

/* Catalogo cerrado de estados (dominio de la aplicacion, no del ETL) */
SET IDENTITY_INSERT dw.DimEstadoReserva ON;
INSERT INTO dw.DimEstadoReserva (EstadoKey, Estado, Descripcion, EsConfirmada, EsCancelada, CuentaParaIngreso)
VALUES (-1, 'DESCONOCIDO', 'Estado no reconocido en el origen', 0, 0, 0),
       ( 1, 'CONFIRMADA',  'Reserva confirmada y vigente',      1, 0, 1),
       ( 2, 'PENDIENTE',   'Reserva registrada sin confirmar',  0, 0, 0),
       ( 3, 'CANCELADA',   'Reserva cancelada',                 0, 1, 0);
SET IDENTITY_INSERT dw.DimEstadoReserva OFF;
GO

SET IDENTITY_INSERT dw.DimCanal ON;
INSERT INTO dw.DimCanal (CanalKey, Canal, Dispositivo, EsMovil)
VALUES (-1, 'No aplica', 'No aplica', 0);
SET IDENTITY_INSERT dw.DimCanal OFF;
GO

/* =====================================================================
   Carga de DimTiempo (2020-01-01 .. 2027-12-31)
   Se genera aqui y no en el ETL: no depende de ninguna fuente y debe
   existir antes de la primera corrida.
   ===================================================================== */
DECLARE @ini date = '2020-01-01', @fin date = '2027-12-31';

;WITH n AS (
    SELECT TOP (DATEDIFF(DAY, @ini, @fin) + 1)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
), f AS (
    SELECT DATEADD(DAY, i, @ini) AS d FROM n
)
INSERT INTO dw.DimTiempo (TiempoKey, Fecha, Anio, Trimestre, NombreTrimestre, Mes,
        NombreMes, NombreMesCorto, AnioMes, Semana, DiaDelMes, DiaDelAnio, DiaSemana,
        NombreDiaSemana, EsFinDeSemana, TemporadaTuristica, EsTemporadaAlta, Semestre)
SELECT
    YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d),
    d,
    YEAR(d),
    DATEPART(QUARTER, d),
    'T' + CAST(DATEPART(QUARTER, d) AS varchar(1)),
    MONTH(d),
    CHOOSE(MONTH(d), 'Enero','Febrero','Marzo','Abril','Mayo','Junio',
                     'Julio','Agosto','Setiembre','Octubre','Noviembre','Diciembre'),
    CHOOSE(MONTH(d), 'Ene','Feb','Mar','Abr','May','Jun',
                     'Jul','Ago','Set','Oct','Nov','Dic'),
    YEAR(d) * 100 + MONTH(d),
    DATEPART(ISO_WEEK, d),
    DAY(d),
    DATEPART(DAYOFYEAR, d),
    ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1,          -- 1=lunes, independiente de DATEFIRST
    CHOOSE(((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1,
           'Lunes','Martes','Miercoles','Jueves','Viernes','Sabado','Domingo'),
    CASE WHEN ((DATEPART(WEEKDAY, d) + @@DATEFIRST - 2) % 7) + 1 >= 6 THEN 1 ELSE 0 END,
    CASE WHEN MONTH(d) IN (12,1,2,3,4,7) THEN 'Alta' ELSE 'Verde' END,
    CASE WHEN MONTH(d) IN (12,1,2,3,4,7) THEN 1 ELSE 0 END,
    CASE WHEN MONTH(d) <= 6 THEN 1 ELSE 2 END
FROM f;
GO

-- Fila centinela para hechos sin fecha valida.
INSERT INTO dw.DimTiempo (TiempoKey, Fecha, Anio, Trimestre, NombreTrimestre, Mes,
        NombreMes, NombreMesCorto, AnioMes, Semana, DiaDelMes, DiaDelAnio, DiaSemana,
        NombreDiaSemana, EsFinDeSemana, TemporadaTuristica, EsTemporadaAlta, Semestre)
VALUES (-1, '1900-01-01', 1900, 1, 'N/A', 1, 'No aplica', 'N/A', 190001, 1, 1, 1, 1,
        'No aplica', 0, 'No aplica', 0, 1);
GO

/* =====================================================================
   Resultado
   ===================================================================== */
PRINT '';
PRINT '=== Modelo estrella creado ===';
SELECT
    [Tipo]      = CASE WHEN t.name LIKE 'Fact%' THEN 'Hecho' ELSE 'Dimension' END,
    [Tabla]     = 'dw.' + t.name,
    [Filas]     = SUM(CASE WHEN p.index_id IN (0,1) THEN p.rows ELSE 0 END),
    [Filegroup] = MAX(ds.name)
FROM sys.tables t
JOIN sys.schemas s      ON s.schema_id = t.schema_id
JOIN sys.partitions p   ON p.object_id = t.object_id
JOIN sys.indexes i      ON i.object_id = t.object_id AND i.index_id = p.index_id
JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
WHERE s.name = 'dw' AND i.index_id IN (0,1)
GROUP BY t.name
ORDER BY 1 DESC, 2;
GO

PRINT '';
PRINT '>> Modelo estrella listo. Siguiente: 43-etl-control.sql';
GO
