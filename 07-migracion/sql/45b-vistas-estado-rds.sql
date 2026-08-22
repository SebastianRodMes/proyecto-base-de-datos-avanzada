/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   45b-vistas-estado-rds.sql
   ---------------------------------------------------------------------
   Reemplaza dw.vw_EstadoSistema por una version valida en Amazon RDS.
   Correr DESPUES de 04-sqlserver/45-vistas-powerbi.sql.

   El problema
   -----------
   La vista original (45-vistas-powerbi.sql:327) fue escrita para el eje
   de alta disponibilidad de las semanas 1-2: lee sys.database_mirroring,
   sys.availability_replicas, sys.availability_groups, sys.dm_hadr_* y
   sys.dm_os_sys_info para reportar a que nodo se conecto Power BI, su rol
   en el grupo de disponibilidad y si estaba sincronizado.

   En RDS eso no aplica:

     - No hay mirroring ni AG propio. La redundancia la da Multi-AZ, que
       AWS administra y no se configura desde T-SQL. En una instancia
       Express Single-AZ esas DMV devuelven vacio, asi que las columnas
       quedarian en 'Sin configurar' sin explicar por que.
     - sys.dm_os_sys_info exige VIEW SERVER STATE. El usuario maestro de
       RDS suele tenerlo, pero no esta garantizado en toda configuracion,
       y si falta la vista revienta en tiempo de consulta y con ella la
       pagina 6 del reporte.

   La solucion
   -----------
   Se conservan las VEINTIUNA columnas con nombre y tipo identicos, para
   que el modelo semantico de Power BI (EstadoSistema.tmdl, 21 columnas)
   no requiera ningun cambio. Lo que cambia es de donde sale cada valor:

     RolMirroring / EstadoMirroring / Socio / Testigo
         Pasan a describir la redundancia REAL del servicio gestionado.
         Si RDS esta en Multi-AZ usa internamente un grupo de
         disponibilidad y las DMV de hadr si devuelven filas: se leen y se
         reportan. Si es Single-AZ se reporta explicitamente como tal, en
         vez de mentir con 'Sin configurar'.

     InicioInstancia
         Se deja de usar sys.dm_os_sys_info. Se usa la fecha de creacion
         de tempdb, que SQL Server recrea en cada arranque del motor: da
         exactamente el mismo dato y solo necesita permiso de lectura
         sobre sys.databases, que cualquier usuario tiene.

   Todo lo relativo al ETL (UltimaCarga*) sale de etl.vw_UltimaEjecucion
   igual que antes, sin cambios.
   ===================================================================== */
SET NOCOUNT ON;
GO
USE TurismoDW;
GO

CREATE OR ALTER VIEW dw.vw_EstadoSistema
AS
SELECT
    [NodoActual]         = CONVERT(nvarchar(128), @@SERVERNAME),
    [Instancia]          = CONVERT(nvarchar(128), ISNULL(@@SERVICENAME, 'MSSQLSERVER')),
    [Edicion]            = CONVERT(nvarchar(60),  SERVERPROPERTY('Edition')),
    [BaseDatos]          = DB_NAME(),
    [ModeloRecuperacion] = CONVERT(nvarchar(30),  DATABASEPROPERTYEX(DB_NAME(), 'Recovery')),

    /* Redundancia del servicio gestionado. Se mantienen los nombres de
       columna del modelo original a proposito: Power BI los tiene atados. */
    [RolMirroring]       = CONVERT(nvarchar(30),
                              COALESCE('RDS ' + ag.Rol COLLATE DATABASE_DEFAULT,
                                       'RDS Single-AZ')),
    [EstadoMirroring]    = CONVERT(nvarchar(30),
                              COALESCE(ag.Estado COLLATE DATABASE_DEFAULT,
                                       'GESTIONADO POR AWS')),
    [Socio]              = CONVERT(nvarchar(128),
                              COALESCE(ag.Socio COLLATE DATABASE_DEFAULT,
                                       'N/D (sin replica de lectura)')),
    [Testigo]            = CONVERT(nvarchar(128),
                              COALESCE('Cluster: ' + ag.TipoCluster COLLATE DATABASE_DEFAULT,
                                       'Cluster: RDS gestionado por AWS')),

    /* tempdb se recrea en cada arranque del motor: su create_date ES la
       hora de inicio de la instancia, sin necesitar VIEW SERVER STATE. */
    [InicioInstancia]    = arranque.InicioInstancia,
    [HorasEnLinea]       = DATEDIFF(HOUR, arranque.InicioInstancia, SYSDATETIME()),

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
FROM (SELECT [InicioInstancia] = create_date
        FROM sys.databases
       WHERE name = 'tempdb') AS arranque
LEFT JOIN etl.vw_UltimaEjecucion u ON 1 = 1
OUTER APPLY (
    /* Si la instancia es Multi-AZ, RDS levanta un AG interno y estas DMV
       si devuelven fila. Si es Single-AZ, el APPLY queda en NULL y los
       COALESCE de arriba reportan el modo gestionado. */
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
     AND ars.group_id   = ar.group_id
     AND ars.is_local   = 1
    JOIN sys.dm_hadr_database_replica_states drs
      ON drs.replica_id  = ar.replica_id
     AND drs.group_id    = ar.group_id
     AND drs.is_local    = 1
     AND drs.database_id = DB_ID()
) ag;
GO

PRINT '>> dw.vw_EstadoSistema reemplazada por la version RDS (21 columnas intactas).';
GO

/* Comprobacion rapida: debe devolver exactamente una fila y ninguna
   columna en error. Si esto corre, la pagina 6 de Power BI funciona. */
SELECT NodoActual, Edicion, RolMirroring, EstadoMirroring, Testigo,
       InicioInstancia, HorasEnLinea, UltimaCargaEstado
FROM dw.vw_EstadoSistema;
GO
