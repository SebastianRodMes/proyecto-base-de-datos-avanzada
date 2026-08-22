/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   43b-carga-incremental.sql
   ---------------------------------------------------------------------
   Marcas de agua para la carga incremental del ETL.

   Correr DESPUES de 43-etl-control.sql.

   Por que hace falta
   ------------------
   La bitacora de 43-etl-control.sql ya esta completa: etl.Ejecucion,
   etl.Etapa y etl.Error registran cada corrida, etapa y rechazo. Lo que
   NO existe es la carga incremental. El parametro --modo de run_etl.py
   admite el valor INCREMENTAL desde el principio, pero solo lo escribe
   como etiqueta en etl.Ejecucion: no cambia ningun camino de codigo.
   Hoy todos los extractores hacen barrido completo sin predicado y los
   hechos se recargan con TRUNCATE.

   La Semana 4 exige "ejecutar carga incremental utilizando la
   infraestructura cloud", asi que se implementa de verdad.

   Como funciona
   -------------
   etl.Marca guarda, por cada objeto de origen, hasta donde se leyo la
   ultima vez. El extractor pide la marca antes de consultar, filtra por
   ella, y al terminar la corrida se avanza al valor maximo observado.

   La marca se guarda como TEXTO a proposito. Las fuentes no comparten
   tipo: PostgreSQL marca por timestamp, MongoDB por fecha ISO y los
   archivos por fecha de modificacion. Un varchar admite las tres sin
   inventar una columna por tipo, y el extractor sabe como interpretar
   la suya.

   La marca se avanza SOLO si la corrida termina bien. Si el ETL falla a
   media carga, la marca se queda donde estaba y el siguiente intento
   vuelve a traer el mismo lote: es preferible reprocesar a perder datos,
   sobre todo porque la carga de hechos incremental es idempotente
   (borra por clave de negocio antes de insertar).

   Uso:
     sqlcmd -S localhost,1433 -U sa -P <pwd> -C -d TurismoDW -i este.sql
   ===================================================================== */
SET NOCOUNT ON;
GO
USE TurismoDW;
GO

/* ---------------------------------------------------------------------
   1. Tabla de marcas
   --------------------------------------------------------------------- */
IF OBJECT_ID('etl.Marca') IS NOT NULL DROP TABLE etl.Marca;
GO

CREATE TABLE etl.Marca (
    Fuente            varchar(30)  NOT NULL,   -- POSTGRESQL | MONGODB | JSON | XML
    Objeto            varchar(60)  NOT NULL,   -- tabla o coleccion de origen
    TipoMarca         varchar(20)  NOT NULL,   -- TIMESTAMP | FECHA | ARCHIVO
    ValorMarca        varchar(50)  NULL,       -- NULL = nunca se ha cargado
    FilasUltimoLote   bigint       NOT NULL CONSTRAINT DF_EtlMarca_Filas   DEFAULT (0),
    EjecucionId       int          NULL,
    FechaActualizacion datetime2(0) NOT NULL CONSTRAINT DF_EtlMarca_Fecha  DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_EtlMarca PRIMARY KEY CLUSTERED (Fuente, Objeto),
    CONSTRAINT CK_EtlMarca_Tipo CHECK (TipoMarca IN ('TIMESTAMP', 'FECHA', 'ARCHIVO')),
    CONSTRAINT FK_EtlMarca_Ejecucion FOREIGN KEY (EjecucionId)
        REFERENCES etl.Ejecucion (EjecucionId)
) ON FG_DIM;
GO

/* ---------------------------------------------------------------------
   2. Semilla: un renglon por objeto de origen que admite marca.

   Los catalogos pequenos (hotel, tour, paquete_turistico, paquete_hotel,
   paquete_tour, tipo_habitacion) NO llevan marca a proposito: no tienen
   columna de fecha en el origen y juntos no llegan a 2 000 filas. Leerlos
   completos en cada corrida cuesta menos de un segundo y evita inventarles
   un control de cambios que el modelo de origen no ofrece. Queda dicho
   aqui para que no parezca un olvido.
   --------------------------------------------------------------------- */
INSERT INTO etl.Marca (Fuente, Objeto, TipoMarca, ValorMarca) VALUES
    ('POSTGRESQL', 'cliente',             'TIMESTAMP', NULL),
    ('POSTGRESQL', 'preferencia_cliente', 'TIMESTAMP', NULL),
    ('POSTGRESQL', 'reserva',             'TIMESTAMP', NULL),
    ('MONGODB',    'resenas',             'FECHA',     NULL),
    ('MONGODB',    'interacciones_web',   'FECHA',     NULL),
    ('JSON',       'preferencias',        'ARCHIVO',   NULL),
    ('XML',        'paquetes',            'ARCHIVO',   NULL);
GO

/* ---------------------------------------------------------------------
   3. etl.usp_ObtenerMarca

   Devuelve la marca vigente. Si nunca se cargo, devuelve NULL y el
   extractor hace barrido completo: la primera corrida INCREMENTAL sobre
   una base recien migrada equivale a una FULL, que es lo correcto.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_ObtenerMarca
    @Fuente     varchar(30),
    @Objeto     varchar(60),
    @ValorMarca varchar(50) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ValorMarca = NULL;

    SELECT @ValorMarca = ValorMarca
    FROM etl.Marca
    WHERE Fuente = @Fuente AND Objeto = @Objeto;

    -- Un objeto sin renglon se registra al vuelo para que aparezca en la
    -- proxima corrida en vez de quedar invisible.
    IF @@ROWCOUNT = 0
        INSERT INTO etl.Marca (Fuente, Objeto, TipoMarca, ValorMarca)
        VALUES (@Fuente, @Objeto, 'TIMESTAMP', NULL);

    SELECT [ValorMarca] = @ValorMarca;
END
GO

/* ---------------------------------------------------------------------
   4. etl.usp_ActualizarMarca

   Avanza la marca. Nunca retrocede: si el lote vino vacio, @NuevoValor
   llega NULL y el renglon queda como estaba. Eso importa cuando una
   corrida no encuentra novedades y no debe reabrir la ventana.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_ActualizarMarca
    @Fuente      varchar(30),
    @Objeto      varchar(60),
    @NuevoValor  varchar(50),
    @Filas       bigint = 0,
    @EjecucionId int    = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @NuevoValor IS NULL
    BEGIN
        UPDATE etl.Marca
           SET FilasUltimoLote    = @Filas,
               EjecucionId        = @EjecucionId,
               FechaActualizacion = SYSDATETIME()
         WHERE Fuente = @Fuente AND Objeto = @Objeto;
        RETURN;
    END

    UPDATE etl.Marca
       SET ValorMarca         = @NuevoValor,
           FilasUltimoLote    = @Filas,
           EjecucionId        = @EjecucionId,
           FechaActualizacion = SYSDATETIME()
     WHERE Fuente = @Fuente AND Objeto = @Objeto;

    IF @@ROWCOUNT = 0
        INSERT INTO etl.Marca (Fuente, Objeto, TipoMarca, ValorMarca,
                               FilasUltimoLote, EjecucionId)
        VALUES (@Fuente, @Objeto, 'TIMESTAMP', @NuevoValor, @Filas, @EjecucionId);
END
GO

/* ---------------------------------------------------------------------
   5. etl.usp_ReiniciarMarcas

   Vuelve todas las marcas a NULL. Es lo que convierte la siguiente
   corrida INCREMENTAL en un barrido completo, util tras una recarga
   total o tras migrar a un destino nuevo.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE etl.usp_ReiniciarMarcas
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.Marca
       SET ValorMarca = NULL, FilasUltimoLote = 0,
           EjecucionId = NULL, FechaActualizacion = SYSDATETIME();
    SELECT [Marcas reiniciadas] = @@ROWCOUNT;
END
GO

/* ---------------------------------------------------------------------
   6. Vista de consulta rapida del estado incremental
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW etl.vw_EstadoIncremental
AS
SELECT
    m.Fuente,
    m.Objeto,
    m.TipoMarca,
    [Marca]            = ISNULL(m.ValorMarca, '(sin cargar)'),
    m.FilasUltimoLote,
    m.EjecucionId,
    [ModoEjecucion]    = e.Modo,
    [EstadoEjecucion]  = e.Estado,
    m.FechaActualizacion,
    [HorasDesdeCarga]  = DATEDIFF(HOUR, m.FechaActualizacion, SYSDATETIME())
FROM etl.Marca m
LEFT JOIN etl.Ejecucion e ON e.EjecucionId = m.EjecucionId;
GO

PRINT '>> etl.Marca creada con 7 objetos registrados.';
PRINT '   Procedimientos: usp_ObtenerMarca, usp_ActualizarMarca, usp_ReiniciarMarcas.';
PRINT '   Vista: etl.vw_EstadoIncremental.';
GO

SELECT Fuente, Objeto, TipoMarca, Marca FROM etl.vw_EstadoIncremental;
GO
