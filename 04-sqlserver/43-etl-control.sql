/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   43-etl-control.sql

   Control, bitacora y trazabilidad del ETL.

   Cubre RNF-05 (mantenibilidad y trazabilidad): "registrar errores y
   permitir rastrear los datos desde su fuente original hasta SQL Server".
   Es el espejo en el DW de las tablas importacion_datos / error_importacion
   que ya existen en la base operacional.

   Tres niveles:
     etl.Ejecucion  -> una fila por corrida del ETL
     etl.Etapa      -> una fila por etapa dentro de la corrida (con tiempos)
     etl.Error      -> una fila por registro rechazado, con el dato original

   Uso: sqlcmd -S TURISMODW -E -C -d TurismoDW -i 43-etl-control.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

DROP PROCEDURE IF EXISTS etl.usp_FinalizarEtapa;
DROP PROCEDURE IF EXISTS etl.usp_IniciarEtapa;
DROP PROCEDURE IF EXISTS etl.usp_FinalizarEjecucion;
DROP PROCEDURE IF EXISTS etl.usp_IniciarEjecucion;
DROP PROCEDURE IF EXISTS etl.usp_RegistrarError;
DROP VIEW IF EXISTS etl.vw_UltimaEjecucion;
DROP TABLE IF EXISTS etl.Error;
DROP TABLE IF EXISTS etl.Etapa;
DROP TABLE IF EXISTS etl.Ejecucion;
GO

/* ---------------------------------------------------------------------
   Una fila por corrida del ETL
   --------------------------------------------------------------------- */
CREATE TABLE etl.Ejecucion (
    EjecucionId        int           NOT NULL IDENTITY(1,1),
    Modo               varchar(20)   NOT NULL,   -- FULL | INCREMENTAL | SOLO-MONGO ...
    Estado             varchar(20)   NOT NULL,   -- EN_PROCESO | COMPLETADO | CON_ERRORES | FALLIDO
    FechaInicio        datetime2(0)  NOT NULL,
    FechaFin           datetime2(0)  NULL,
    DuracionSegundos   AS DATEDIFF(SECOND, FechaInicio, FechaFin),
    RegistrosLeidos    bigint        NOT NULL DEFAULT 0,
    RegistrosCargados  bigint        NOT NULL DEFAULT 0,
    RegistrosRechazados bigint       NOT NULL DEFAULT 0,
    Servidor           sysname       NOT NULL DEFAULT @@SERVERNAME,
    UsuarioEjecucion   sysname       NOT NULL DEFAULT SUSER_SNAME(),
    Mensaje            nvarchar(max) NULL,
    CONSTRAINT PK_EtlEjecucion PRIMARY KEY CLUSTERED (EjecucionId),
    CONSTRAINT CK_EtlEjecucion_Estado CHECK
        (Estado IN ('EN_PROCESO','COMPLETADO','CON_ERRORES','FALLIDO'))
) ON FG_DIM;
GO

/* ---------------------------------------------------------------------
   Una fila por etapa. Los tiempos por etapa son la evidencia que pide el
   enunciado sobre el rendimiento de la carga, y le sirven al Integrante 4.
   --------------------------------------------------------------------- */
CREATE TABLE etl.Etapa (
    EtapaId           int           NOT NULL IDENTITY(1,1),
    EjecucionId       int           NOT NULL,
    Secuencia         int           NOT NULL,
    Nombre            varchar(80)   NOT NULL,   -- EXTRAER_PG, CARGAR_STG, MERGE_DIM ...
    Fuente            varchar(30)   NOT NULL,   -- POSTGRESQL | MONGODB | JSON | XML | INTERNO
    ObjetoDestino     varchar(120)  NULL,
    Estado            varchar(20)   NOT NULL,
    FechaInicio       datetime2(3)  NOT NULL,
    FechaFin          datetime2(3)  NULL,
    DuracionSegundos  AS CAST(DATEDIFF(MILLISECOND, FechaInicio, FechaFin) / 1000.0 AS decimal(10,3)),
    Filas             bigint        NULL,
    Mensaje           nvarchar(max) NULL,
    CONSTRAINT PK_EtlEtapa PRIMARY KEY CLUSTERED (EtapaId),
    CONSTRAINT FK_EtlEtapa_Ejecucion FOREIGN KEY (EjecucionId)
        REFERENCES etl.Ejecucion(EjecucionId)
) ON FG_DIM;

CREATE INDEX IX_EtlEtapa_Ejecucion ON etl.Etapa (EjecucionId, Secuencia) ON FG_IDX;
GO

/* ---------------------------------------------------------------------
   Un registro rechazado por fila. Guarda el dato original completo para
   que se pueda reprocesar o auditar sin volver a la fuente.
   --------------------------------------------------------------------- */
CREATE TABLE etl.Error (
    ErrorId          bigint        NOT NULL IDENTITY(1,1),
    EjecucionId      int           NOT NULL,
    Fuente           varchar(30)   NOT NULL,
    ArchivoOrigen    nvarchar(300) NULL,
    ObjetoOrigen     varchar(120)  NULL,      -- tabla o coleccion
    NumeroRegistro   bigint        NULL,
    ClaveNegocio     nvarchar(100) NULL,
    Campo            varchar(100)  NULL,
    ReglaValidacion  varchar(100)  NOT NULL,  -- no_nulo, formato_email, rango, duplicado ...
    Severidad        varchar(20)   NOT NULL DEFAULT 'RECHAZO',  -- RECHAZO | ADVERTENCIA
    Descripcion      nvarchar(500) NOT NULL,
    DatosOriginales  nvarchar(max) NULL,
    FechaDeteccion   datetime2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_EtlError PRIMARY KEY CLUSTERED (ErrorId),
    CONSTRAINT FK_EtlError_Ejecucion FOREIGN KEY (EjecucionId)
        REFERENCES etl.Ejecucion(EjecucionId)
) ON FG_DIM;

CREATE INDEX IX_EtlError_Ejecucion ON etl.Error (EjecucionId, Fuente) ON FG_IDX;
GO

/* =====================================================================
   Procedimientos de bitacora
   ===================================================================== */

CREATE PROCEDURE etl.usp_IniciarEjecucion
    @Modo        varchar(20),
    @EjecucionId int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Una corrida anterior que quedo colgada (proceso muerto) se marca como
    -- fallida antes de abrir la nueva, para que la bitacora no mienta.
    UPDATE etl.Ejecucion
       SET Estado   = 'FALLIDO',
           FechaFin = SYSDATETIME(),
           Mensaje  = ISNULL(Mensaje, '') + ' | Cerrada automaticamente al iniciar una nueva ejecucion.'
     WHERE Estado = 'EN_PROCESO';

    INSERT INTO etl.Ejecucion (Modo, Estado, FechaInicio)
    VALUES (@Modo, 'EN_PROCESO', SYSDATETIME());

    SET @EjecucionId = SCOPE_IDENTITY();
END
GO

CREATE PROCEDURE etl.usp_IniciarEtapa
    @EjecucionId   int,
    @Nombre        varchar(80),
    @Fuente        varchar(30),
    @ObjetoDestino varchar(120) = NULL,
    @EtapaId       int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sec int =
        (SELECT ISNULL(MAX(Secuencia), 0) + 1 FROM etl.Etapa WHERE EjecucionId = @EjecucionId);

    INSERT INTO etl.Etapa (EjecucionId, Secuencia, Nombre, Fuente, ObjetoDestino,
                           Estado, FechaInicio)
    VALUES (@EjecucionId, @sec, @Nombre, @Fuente, @ObjetoDestino, 'EN_PROCESO', SYSDATETIME());

    SET @EtapaId = SCOPE_IDENTITY();
END
GO

CREATE PROCEDURE etl.usp_FinalizarEtapa
    @EtapaId  int,
    @Filas    bigint       = NULL,
    @Estado   varchar(20)  = 'COMPLETADO',
    @Mensaje  nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.Etapa
       SET Estado   = @Estado,
           FechaFin = SYSDATETIME(),
           Filas    = @Filas,
           Mensaje  = @Mensaje
     WHERE EtapaId = @EtapaId;
END
GO

CREATE PROCEDURE etl.usp_FinalizarEjecucion
    @EjecucionId int,
    @Estado      varchar(20)   = NULL,
    @Mensaje     nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @rechazos bigint =
        (SELECT COUNT_BIG(*) FROM etl.Error
          WHERE EjecucionId = @EjecucionId AND Severidad = 'RECHAZO');

    DECLARE @cargados bigint =
        (SELECT ISNULL(SUM(Filas), 0) FROM etl.Etapa
          WHERE EjecucionId = @EjecucionId AND Nombre LIKE 'CARGAR_DW%');

    -- Si el orquestador no fuerza un estado, se deduce de la bitacora.
    IF @Estado IS NULL
        SET @Estado = CASE
                        WHEN EXISTS (SELECT 1 FROM etl.Etapa
                                      WHERE EjecucionId = @EjecucionId AND Estado = 'FALLIDO')
                             THEN 'FALLIDO'
                        WHEN @rechazos > 0 THEN 'CON_ERRORES'
                        ELSE 'COMPLETADO' END;

    UPDATE etl.Ejecucion
       SET Estado              = @Estado,
           FechaFin            = SYSDATETIME(),
           RegistrosRechazados = @rechazos,
           RegistrosCargados   = @cargados,
           Mensaje             = @Mensaje
     WHERE EjecucionId = @EjecucionId;
END
GO

CREATE PROCEDURE etl.usp_RegistrarError
    @EjecucionId     int,
    @Fuente          varchar(30),
    @ReglaValidacion varchar(100),
    @Descripcion     nvarchar(500),
    @ArchivoOrigen   nvarchar(300) = NULL,
    @ObjetoOrigen    varchar(120)  = NULL,
    @NumeroRegistro  bigint        = NULL,
    @ClaveNegocio    nvarchar(100) = NULL,
    @Campo           varchar(100)  = NULL,
    @Severidad       varchar(20)   = 'RECHAZO',
    @DatosOriginales nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.Error (EjecucionId, Fuente, ArchivoOrigen, ObjetoOrigen, NumeroRegistro,
                           ClaveNegocio, Campo, ReglaValidacion, Severidad, Descripcion,
                           DatosOriginales)
    VALUES (@EjecucionId, @Fuente, @ArchivoOrigen, @ObjetoOrigen, @NumeroRegistro,
            @ClaveNegocio, @Campo, @ReglaValidacion, @Severidad, @Descripcion,
            @DatosOriginales);
END
GO

/* ---------------------------------------------------------------------
   Vista de estado: alimenta la pagina "Estado del sistema" del dashboard
   de Power BI, que evidencia a que nodo esta conectado el reporte y
   cuando fue la ultima carga correcta.
   --------------------------------------------------------------------- */
CREATE VIEW etl.vw_UltimaEjecucion
AS
SELECT TOP (1)
    e.EjecucionId,
    e.Modo,
    e.Estado,
    e.FechaInicio,
    e.FechaFin,
    e.DuracionSegundos,
    e.RegistrosLeidos,
    e.RegistrosCargados,
    e.RegistrosRechazados,
    [NodoActivo]     = e.Servidor,
    [NodoActualReal] = @@SERVERNAME,       -- cambia tras el failover del Integrante 3
    [Etapas]         = (SELECT COUNT(*) FROM etl.Etapa t WHERE t.EjecucionId = e.EjecucionId),
    [EtapasFallidas] = (SELECT COUNT(*) FROM etl.Etapa t
                         WHERE t.EjecucionId = e.EjecucionId AND t.Estado = 'FALLIDO'),
    [HorasDesdeCarga] = DATEDIFF(HOUR, e.FechaFin, SYSDATETIME())
FROM etl.Ejecucion e
ORDER BY e.EjecucionId DESC;
GO

PRINT '';
PRINT '=== Objetos de control ETL creados ===';
SELECT [Objeto] = s.name + '.' + o.name,
       [Tipo]   = o.type_desc
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE s.name = 'etl' AND o.type IN ('U','P','V')
ORDER BY o.type_desc, o.name;
GO

PRINT '>> Control ETL listo. Siguiente: 44-transformacion.sql';
GO
