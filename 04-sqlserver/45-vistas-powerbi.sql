/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
   Integrante 1: Alex Herrera
   ---------------------------------------------------------------------
   45-vistas-powerbi.sql

   Capa de presentacion que consume Power BI.

   Por que el reporte NO lee las tablas directamente:
     * El Integrante 2 va a reparticionar dw.FactReserva y a reconstruir
       indices. Si el .pbix apuntara a la tabla fisica, cada cambio suyo
       obligaria a reconstruir el modelo. Contra una vista, su trabajo es
       invisible para el reporte.
     * Las vistas traducen banderas tecnicas (bit, claves -1) a texto que
       se puede poner en un segmentador sin escribir DAX.
     * Reducen el ancho de fila que viaja al modelo: se excluyen columnas
       de auditoria que el reporte no muestra.

   Convencion: dw.vw_Dim* y dw.vw_Fact* replican el nombre de la tabla
   base, de modo que la correspondencia es evidente al depurar.

   Uso: sqlcmd -S TURISMODW -E -C -d TurismoDW -i 45-vistas-powerbi.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

DROP VIEW IF EXISTS dw.vw_EstadoSistema;
DROP VIEW IF EXISTS dw.vw_CalidadDatos;
DROP VIEW IF EXISTS dw.vw_FactInteraccionWeb;
DROP VIEW IF EXISTS dw.vw_FactResena;
DROP VIEW IF EXISTS dw.vw_FactOcupacionDiaria;
DROP VIEW IF EXISTS dw.vw_FactReservaTour;
DROP VIEW IF EXISTS dw.vw_FactReservaHabitacion;
DROP VIEW IF EXISTS dw.vw_FactReserva;
DROP VIEW IF EXISTS dw.vw_DimCanal;
DROP VIEW IF EXISTS dw.vw_DimEstadoReserva;
DROP VIEW IF EXISTS dw.vw_DimPaquete;
DROP VIEW IF EXISTS dw.vw_DimTour;
DROP VIEW IF EXISTS dw.vw_DimTipoHabitacion;
DROP VIEW IF EXISTS dw.vw_DimHotel;
DROP VIEW IF EXISTS dw.vw_DimCliente;
DROP VIEW IF EXISTS dw.vw_DimTiempo;
GO

/* =====================================================================
   DIMENSIONES
   ===================================================================== */

CREATE VIEW dw.vw_DimTiempo
AS
SELECT
    TiempoKey,
    Fecha,
    Anio,
    Trimestre,
    NombreTrimestre,
    Mes,
    NombreMes,
    NombreMesCorto,
    AnioMes,
    -- Etiqueta lista para el eje del grafico, ya ordenable por AnioMes.
    [AnioMesEtiqueta]  = NombreMesCorto + ' ' + CAST(Anio AS varchar(4)),
    Semana,
    DiaDelMes,
    DiaDelAnio,
    DiaSemana,
    NombreDiaSemana,
    [TipoDia]          = CASE WHEN EsFinDeSemana = 1 THEN 'Fin de semana' ELSE 'Entre semana' END,
    TemporadaTuristica,
    [TipoTemporada]    = CASE WHEN EsTemporadaAlta = 1 THEN 'Temporada alta' ELSE 'Temporada verde' END,
    Semestre,
    [NombreSemestre]   = 'S' + CAST(Semestre AS varchar(1))
FROM dw.DimTiempo
WHERE TiempoKey <> -1;    -- la fila centinela no debe aparecer en el calendario
GO

CREATE VIEW dw.vw_DimCliente
AS
SELECT
    ClienteKey,
    ClienteId,
    Identificacion,
    NombreCompleto,
    Correo,
    PaisOrigen,
    Edad,
    RangoEdad,
    [Estado]          = CASE WHEN Activo = 1 THEN 'Activo' ELSE 'Inactivo' END,
    FechaRegistro,
    DestinosPreferidos,
    TipoAlojamiento,
    ActividadesFavoritas,
    PresupuestoEstimado,
    RangoPresupuesto,
    TemporadaViaje,
    [Idioma]          = ISNULL(Idioma, 'Sin dato'),
    [Dieta]           = ISNULL(Dieta, 'Sin dato'),
    [GrupoViaje]      = ISNULL(GrupoViaje, 'Sin dato'),
    [SegmentoVip]     = CASE WHEN EsVip = 1 THEN 'VIP' ELSE 'Regular' END,
    FuenteDatos
FROM dw.DimCliente;
GO

CREATE VIEW dw.vw_DimHotel
AS
SELECT
    HotelKey,
    HotelId,
    Nombre,
    Categoria,
    NumeroEstrellas,
    Ciudad,
    Pais,
    -- Jerarquia geografica lista para el mapa y el drill-down.
    [PaisCiudad]     = Pais + ' / ' + Ciudad,
    Servicios,
    CapacidadTotal,
    RangoCapacidad,
    [Estado]         = CASE WHEN Activo = 1 THEN 'Operativo' ELSE 'Fuera de servicio' END
FROM dw.DimHotel;
GO

CREATE VIEW dw.vw_DimTipoHabitacion
AS
SELECT
    TipoHabitacionKey,
    TipoHabitacionId,
    HotelKey,
    [TipoHabitacion]   = Nombre,
    CapacidadPersonas,
    TarifaBase,
    RangoTarifa,
    CantidadDisponible,
    [Estado]           = CASE WHEN Activo = 1 THEN 'Disponible' ELSE 'No disponible' END
FROM dw.DimTipoHabitacion;
GO

CREATE VIEW dw.vw_DimTour
AS
SELECT
    TourKey,
    TourId,
    Nombre,
    Destino,
    TipoActividad,
    Proveedor,
    DuracionHoras,
    RangoDuracion,
    CupoMaximo,
    Precio,
    [Estado] = CASE WHEN Activo = 1 THEN 'Activo' ELSE 'Inactivo' END
FROM dw.DimTour;
GO

CREATE VIEW dw.vw_DimPaquete
AS
SELECT
    PaqueteKey,
    PaqueteId,
    Nombre,
    TipoPaquete,
    DuracionDias,
    RangoDuracion,
    PrecioTotal,
    RangoPrecio,
    ServiciosAdicionales,
    [Estado]     = CASE WHEN Activo = 1 THEN 'Activo' ELSE 'Inactivo' END,
    FuenteDatos
FROM dw.DimPaquete;
GO

CREATE VIEW dw.vw_DimEstadoReserva
AS
SELECT
    EstadoKey,
    Estado,
    Descripcion,
    EsConfirmada,
    EsCancelada,
    CuentaParaIngreso
FROM dw.DimEstadoReserva;
GO

CREATE VIEW dw.vw_DimCanal
AS
SELECT
    CanalKey,
    Canal,
    Dispositivo,
    [TipoDispositivo] = CASE WHEN EsMovil = 1 THEN 'Movil' ELSE 'Escritorio' END
FROM dw.DimCanal;
GO

/* =====================================================================
   HECHOS
   Se exponen solo las columnas que el modelo necesita: las de auditoria
   (EjecucionIdCarga, FechaCarga) se quedan fuera para no inflar el modelo
   importado con 2 millones de filas x 2 columnas que nadie visualiza.
   ===================================================================== */

CREATE VIEW dw.vw_FactReserva
AS
SELECT
    ReservaId,
    FechaReservaKey,
    FechaInicioKey,
    FechaFinKey,
    ClienteKey,
    PaqueteKey,
    EstadoKey,
    CantidadPersonas,
    MontoTotal,
    Noches,
    DiasAnticipacion,
    MontoConfirmado,
    EsCancelada,
    ConteoReserva
FROM dw.FactReserva;
GO

CREATE VIEW dw.vw_FactReservaHabitacion
AS
SELECT
    ReservaHabitacionId,
    ReservaId,
    FechaInicioKey,
    ClienteKey,
    HotelKey,
    TipoHabitacionKey,
    EstadoKey,
    CantidadHabitaciones,
    TarifaAplicada,
    Noches,
    NochesHabitacion,
    IngresoAlojamiento
FROM dw.FactReservaHabitacion;
GO

CREATE VIEW dw.vw_FactReservaTour
AS
SELECT
    ReservaTourId,
    ReservaId,
    FechaInicioKey,
    ClienteKey,
    TourKey,
    EstadoKey,
    CantidadPersonas,
    PrecioAplicado,
    IngresoTour,
    ConteoTour
FROM dw.FactReservaTour;
GO

CREATE VIEW dw.vw_FactOcupacionDiaria
AS
SELECT
    TiempoKey,
    HotelKey,
    HabitacionesOcupadas,
    HabitacionesDisponibles,
    PersonasAlojadas,
    IngresoDia,
    ReservasActivas
FROM dw.FactOcupacionDiaria;
GO

CREATE VIEW dw.vw_FactResena
AS
SELECT
    ResenaId,
    TiempoKey,
    ClienteKey,
    HotelKey,
    TourKey,
    PaqueteKey,
    TipoEntidad,
    Calificacion,
    EsPositiva,
    EsNegativa,
    EsVerificada,
    LongitudTexto,
    [Idioma]      = ISNULL(Idioma, 'Sin dato'),
    -- Clasificacion de satisfaccion segun el estandar NPS aplicado a 1-5.
    [Satisfaccion] = CASE WHEN Calificacion >= 4 THEN 'Promotor'
                          WHEN Calificacion = 3  THEN 'Neutro'
                          ELSE 'Detractor' END,
    ConteoResena
FROM dw.FactResena;
GO

CREATE VIEW dw.vw_FactInteraccionWeb
AS
SELECT
    InteraccionId,
    TiempoKey,
    ClienteKey,
    CanalKey,
    HotelKey,
    TourKey,
    TipoEvento,
    DestinoBuscado,
    DuracionSegundos,
    EsConversion,
    ConteoEvento
FROM dw.FactInteraccionWeb;
GO

/* =====================================================================
   VISTAS DE OPERACION - alimentan la pagina "Estado del sistema"
   ===================================================================== */

/* ---------------------------------------------------------------------
   dw.vw_EstadoSistema

   Es la evidencia de que el dashboard esta conectado al modelo de alta
   disponibilidad: muestra a que nodo se conecto el ultimo refresco, su rol
   y cuando fue la ultima carga correcta. Admite tanto el mirroring original
   de Windows como el grupo Always On usado por el laboratorio Docker.
   Tras el failover el valor de NodoActual cambia sin tocar el reporte,
   porque Power BI usa un endpoint logico que se repunta al nodo vivo.
   --------------------------------------------------------------------- */
CREATE VIEW dw.vw_EstadoSistema
AS
SELECT
    [NodoActual]        = CONVERT(nvarchar(128), @@SERVERNAME),
    [Instancia]         = CONVERT(nvarchar(128), ISNULL(@@SERVICENAME, 'MSSQLSERVER')),
    [Edicion]           = CONVERT(nvarchar(60),  SERVERPROPERTY('Edition')),
    [BaseDatos]         = DB_NAME(),
    [ModeloRecuperacion]= CONVERT(nvarchar(30),  DATABASEPROPERTYEX(DB_NAME(), 'Recovery')),
    -- Se conservan los nombres de columna para no romper el modelo Power BI.
    -- Cuando existe un AG, sus valores tienen prioridad sobre mirroring.
    [RolMirroring]      = COALESCE(CONVERT(nvarchar(30), 'AG ' + ag.Rol) COLLATE DATABASE_DEFAULT,
                                   CONVERT(nvarchar(30), m.mirroring_role_desc) COLLATE DATABASE_DEFAULT,
                                   'Sin configurar'),
    [EstadoMirroring]   = COALESCE(CONVERT(nvarchar(30), ag.Estado) COLLATE DATABASE_DEFAULT,
                                   CONVERT(nvarchar(30), m.mirroring_state_desc) COLLATE DATABASE_DEFAULT,
                                   'Sin configurar'),
    [Socio]             = COALESCE(CONVERT(nvarchar(128), ag.Socio) COLLATE DATABASE_DEFAULT,
                                   CONVERT(nvarchar(128), m.mirroring_partner_name) COLLATE DATABASE_DEFAULT,
                                   'N/D'),
    [Testigo]           = COALESCE(CONVERT(nvarchar(128), 'Cluster: ' + ag.TipoCluster) COLLATE DATABASE_DEFAULT,
                                   CONVERT(nvarchar(128), m.mirroring_witness_name) COLLATE DATABASE_DEFAULT,
                                   'N/D'),
    [InicioInstancia]   = si.sqlserver_start_time,
    [HorasEnLinea]      = DATEDIFF(HOUR, si.sqlserver_start_time, SYSDATETIME()),
    -- Ultima corrida del ETL
    [UltimaCargaId]         = u.EjecucionId,
    [UltimaCargaModo]       = u.Modo,
    [UltimaCargaEstado]     = u.Estado,
    [UltimaCargaInicio]     = u.FechaInicio,
    [UltimaCargaFin]        = u.FechaFin,
    [UltimaCargaSegundos]   = u.DuracionSegundos,
    [UltimaCargaFilas]      = u.RegistrosCargados,
    [UltimaCargaRechazos]   = u.RegistrosRechazados,
    [HorasDesdeUltimaCarga] = u.HorasDesdeCarga,
    [FechaConsulta]         = SYSDATETIME()
FROM sys.database_mirroring m
CROSS JOIN sys.dm_os_sys_info si
LEFT JOIN etl.vw_UltimaEjecucion u ON 1 = 1
OUTER APPLY (
    SELECT TOP (1)
        [Rol]         = ars.role_desc,
        [Estado]      = drs.synchronization_state_desc,
        [TipoCluster] = g.cluster_type_desc,
        [Socio]       = (
            SELECT TOP (1) ar2.replica_server_name
            FROM sys.availability_replicas ar2
            WHERE ar2.group_id = ar.group_id
              AND ar2.replica_server_name <> CONVERT(nvarchar(128), @@SERVERNAME)
            ORDER BY ar2.replica_server_name
        )
    FROM sys.availability_replicas ar
    JOIN sys.availability_groups g
      ON g.group_id = ar.group_id
    JOIN sys.dm_hadr_availability_replica_states ars
      ON ars.replica_id = ar.replica_id
     AND ars.group_id = ar.group_id
     AND ars.is_local = 1
    JOIN sys.dm_hadr_database_replica_states drs
      ON drs.replica_id = ar.replica_id
     AND drs.group_id = ar.group_id
     AND drs.is_local = 1
     AND drs.database_id = DB_ID()
) ag
WHERE m.database_id = DB_ID();
GO

/* ---------------------------------------------------------------------
   dw.vw_CalidadDatos

   Resume etl.Error por fuente y regla. Es la evidencia visible de RF-15
   (limpieza y validacion) y de RNF-05 (trazabilidad) en el dashboard.
   --------------------------------------------------------------------- */
CREATE VIEW dw.vw_CalidadDatos
AS
SELECT
    e.EjecucionId,
    [Fuente]        = e.Fuente,
    [Objeto]        = ISNULL(e.ObjetoOrigen, 'N/D'),
    [Regla]         = e.ReglaValidacion,
    [Severidad]     = e.Severidad,
    [Registros]     = COUNT_BIG(*),
    [PrimeraDeteccion] = MIN(e.FechaDeteccion),
    [UltimaDeteccion]  = MAX(e.FechaDeteccion),
    [EjemploDescripcion] = MIN(e.Descripcion)
FROM etl.Error e
GROUP BY e.EjecucionId, e.Fuente, e.ObjetoOrigen, e.ReglaValidacion, e.Severidad;
GO

PRINT '';
PRINT '=== Vistas creadas ===';
SELECT [Vista] = s.name + '.' + v.name
FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE s.name IN ('dw','etl')
ORDER BY v.name;
GO

PRINT '>> Vistas listas. Siguiente: ejecutar el ETL (05-etl/run_etl.py)';
GO
