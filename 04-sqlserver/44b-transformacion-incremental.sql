/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 4
   Integrante 1: Alex Herrera

   44b-transformacion-incremental.sql
   ---------------------------------------------------------------------
   Version incremental de la carga de hechos y de la ocupacion diaria.

   Correr DESPUES de 44-transformacion.sql y 43b-carga-incremental.sql.

   Que cambia respecto de usp_CargarHechos
   ---------------------------------------
   El procedimiento original vacia las tablas con TRUNCATE y reinserta
   todo. Es lo correcto para una carga completa y es la razon de que la
   recarga mueva 8 695 473 filas cada vez. En modo incremental staging
   solo trae lo que cambio, asi que truncar borraria el historico entero
   para reponer un punado de filas.

   Aqui se usa BORRAR-E-INSERTAR por clave de negocio, no MERGE.

   Por que no MERGE
   ----------------
   Cuatro de las seis tablas de hechos estan particionadas y su clave
   agrupada incluye la columna de particion: PK_FactReserva es
   (ReservaKey, FechaInicioKey). Si una reserva cambia de fecha de
   inicio, un MERGE tendria que ACTUALIZAR una columna que forma parte
   de la clave del indice agrupado y ademas mover la fila de particion.
   Borrar e insertar hace exactamente eso, de forma explicita y sin
   depender de como el motor resuelva el movimiento entre particiones.

   Ademas es idempotente: correr dos veces el mismo lote deja el mismo
   resultado. Eso importa porque etl.Marca solo avanza si la corrida
   termina bien, asi que un fallo hace que el siguiente intento reprocese
   el mismo lote a proposito.

   Los indices UQ_*_Negocio, que el Integrante 2 dejo sin alinear en
   FG_IDX, son justamente los que permiten que el DELETE haga busqueda
   en vez de recorrido completo. No tocarlos.
   ===================================================================== */
SET NOCOUNT ON;
GO
USE TurismoDW;
GO

/* =====================================================================
   1. etl.usp_CargarHechosIncremental
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_CargarHechosIncremental
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ahora datetime2(0) = SYSDATETIME();

    /* Contadores para el resumen final. */
    DECLARE @borradas TABLE (Hecho varchar(40), Filas bigint);
    DECLARE @n bigint;

    /* ---------------- FactReserva -------------------------------------
       Se borran las reservas que vienen en el lote y se reinsertan con
       su version nueva. Las que no estan en staging no se tocan.        */
    DELETE f
      FROM dw.FactReserva f
     WHERE EXISTS (SELECT 1 FROM stg.Reserva s
                    WHERE TRY_CONVERT(bigint, s.reserva_id) = f.ReservaId);
    SET @n = @@ROWCOUNT;
    INSERT INTO @borradas VALUES ('dw.FactReserva', @n);

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

    /* ---------------- FactReservaHabitacion ----------------------------
       Depende de dw.FactReserva, que acaba de actualizarse: por eso el
       orden de los bloques importa y no se pueden reordenar.            */
    DELETE f
      FROM dw.FactReservaHabitacion f
     WHERE EXISTS (SELECT 1 FROM stg.ReservaHabitacion s
                    WHERE TRY_CONVERT(bigint, s.reserva_habitacion_id) = f.ReservaHabitacionId);
    SET @n = @@ROWCOUNT;
    INSERT INTO @borradas VALUES ('dw.FactReservaHabitacion', @n);

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
    DELETE f
      FROM dw.FactReservaTour f
     WHERE EXISTS (SELECT 1 FROM stg.ReservaTour s
                    WHERE TRY_CONVERT(bigint, s.reserva_tour_id) = f.ReservaTourId);
    SET @n = @@ROWCOUNT;
    INSERT INTO @borradas VALUES ('dw.FactReservaTour', @n);

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

    /* ---------------- FactResena --------------------------------------- */
    DELETE f
      FROM dw.FactResena f
     WHERE EXISTS (SELECT 1 FROM stg.Resena s WHERE s.resena_id = f.ResenaId);
    SET @n = @@ROWCOUNT;
    INSERT INTO @borradas VALUES ('dw.FactResena', @n);

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

    /* ---------------- FactInteraccionWeb -------------------------------- */
    DELETE f
      FROM dw.FactInteraccionWeb f
     WHERE EXISTS (SELECT 1 FROM stg.InteraccionWeb s
                    WHERE s.interaccion_id = f.InteraccionId);
    SET @n = @@ROWCOUNT;
    INSERT INTO @borradas VALUES ('dw.FactInteraccionWeb', @n);

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

    /* ---------------- Resumen ------------------------------------------
       Se reportan filas reemplazadas y total resultante, para que la
       bitacora muestre que la incremental movio ordenes de magnitud
       menos filas que la completa.                                      */
    SELECT [Hecho]        = b.Hecho,
           [Reemplazadas] = b.Filas,
           [TotalActual]  = t.Filas
    FROM @borradas b
    JOIN (
        SELECT [Hecho] = 'dw.FactReserva',           [Filas] = COUNT_BIG(*) FROM dw.FactReserva
        UNION ALL SELECT 'dw.FactReservaHabitacion', COUNT_BIG(*) FROM dw.FactReservaHabitacion
        UNION ALL SELECT 'dw.FactReservaTour',       COUNT_BIG(*) FROM dw.FactReservaTour
        UNION ALL SELECT 'dw.FactResena',            COUNT_BIG(*) FROM dw.FactResena
        UNION ALL SELECT 'dw.FactInteraccionWeb',    COUNT_BIG(*) FROM dw.FactInteraccionWeb
    ) t ON t.Hecho = b.Hecho;
END
GO

/* =====================================================================
   2. etl.usp_CargarOcupacionIncremental

   La ocupacion diaria es un agregado derivado: cada fila resume un par
   (hotel, dia) sumando TODAS las reservas que se solapan con ese dia. No
   se puede actualizar fila por fila a partir del lote, porque una reserva
   nueva cambia el total de dias que ya existian.

   La estrategia es recalcular por AMBITO: se identifican los hoteles y el
   rango de fechas que el lote toca, se borran esos pares (hotel, dia) y se
   recalculan leyendo el hecho completo, no solo el lote. El resultado es
   identico al de un recalculo total, pero acotado.
   ===================================================================== */
CREATE OR ALTER PROCEDURE etl.usp_CargarOcupacionIncremental
    @EjecucionId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ahora datetime2(0) = SYSDATETIME();

    /* 1. Ambito afectado: hoteles y rango de dias que el lote toca. */
    IF OBJECT_ID('tempdb..#Ambito') IS NOT NULL DROP TABLE #Ambito;

    SELECT DISTINCT
        frh.HotelKey,
        [DesdeKey] = MIN(frh.FechaInicioKey) OVER (PARTITION BY frh.HotelKey),
        [HastaKey] = MAX(frh.FechaFinKey)    OVER (PARTITION BY frh.HotelKey)
    INTO #Ambito
    FROM dw.FactReservaHabitacion frh
    WHERE frh.EjecucionIdCarga = @EjecucionId
      AND frh.HotelKey <> -1;

    IF NOT EXISTS (SELECT 1 FROM #Ambito)
    BEGIN
        SELECT [Hecho] = 'dw.FactOcupacionDiaria',
               [Filas] = COUNT_BIG(*),
               [OcupacionPromedio] = CAST(100.0 * SUM(CAST(HabitacionesOcupadas AS bigint))
                                          / NULLIF(SUM(CAST(HabitacionesDisponibles AS bigint)), 0)
                                          AS decimal(5,2))
        FROM dw.FactOcupacionDiaria;
        RETURN;
    END

    /* 2. Se borran los pares (hotel, dia) dentro del ambito. */
    DELETE f
      FROM dw.FactOcupacionDiaria f
      JOIN #Ambito a
        ON a.HotelKey = f.HotelKey
       AND f.TiempoKey BETWEEN a.DesdeKey AND a.HastaKey;

    /* 3. Se recalculan leyendo el hecho COMPLETO dentro del ambito. */
    ;WITH Estadia AS (
        SELECT
            HotelKey     = frh.HotelKey,
            Fecha        = DATEADD(DAY, n.n - 1, dt.Fecha),
            Habitaciones = frh.CantidadHabitaciones,
            Personas     = fr.CantidadPersonas,
            Ingreso      = frh.CantidadHabitaciones * frh.TarifaAplicada,
            ReservaId    = frh.ReservaId
        FROM dw.FactReservaHabitacion frh
        JOIN #Ambito             a  ON a.HotelKey  = frh.HotelKey
                                   AND frh.FechaInicioKey BETWEEN a.DesdeKey AND a.HastaKey
        JOIN dw.FactReserva      fr ON fr.ReservaId = frh.ReservaId
        JOIN dw.DimEstadoReserva de ON de.EstadoKey = fr.EstadoKey
        JOIN dw.DimTiempo        dt ON dt.TiempoKey = frh.FechaInicioKey
        JOIN etl.Numeros          n ON n.n <= frh.Noches
        WHERE de.EsConfirmada = 1
          AND frh.Noches BETWEEN 1 AND 4000
          AND frh.HotelKey <> -1
    ),
    Capacidad AS (
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
    JOIN #Ambito a
      ON a.HotelKey = e.HotelKey
     AND etl.fn_TiempoKey(e.Fecha) BETWEEN a.DesdeKey AND a.HastaKey
    WHERE e.Fecha BETWEEN '2020-01-01' AND '2027-12-31'
    GROUP BY etl.fn_TiempoKey(e.Fecha), e.HotelKey;

    DROP TABLE #Ambito;

    SELECT [Hecho] = 'dw.FactOcupacionDiaria',
           [Filas] = COUNT_BIG(*),
           [OcupacionPromedio] = CAST(100.0 * SUM(CAST(HabitacionesOcupadas AS bigint))
                                      / NULLIF(SUM(CAST(HabitacionesDisponibles AS bigint)), 0)
                                      AS decimal(5,2))
    FROM dw.FactOcupacionDiaria;
END
GO

PRINT '>> Procedimientos incrementales creados:';
PRINT '   etl.usp_CargarHechosIncremental';
PRINT '   etl.usp_CargarOcupacionIncremental';
GO
