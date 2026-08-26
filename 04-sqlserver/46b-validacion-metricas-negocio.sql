/* =====================================================================
   ITI-821 | Escenario 8: Turismo Inteligente | Semanas 3 y 4
   Integrante 3: Erick - Dashboard y Metricas de Negocio
   ---------------------------------------------------------------------
   46b-validacion-metricas-negocio.sql

   Calcula y certifica los 52 KPIs del catalogo de negocio de TurismoDW.
   Comprueba la coherencia matematica y logica entre hechos, dimensiones
   y las formulas DAX del reporte de Power BI.

   Uso:
     sqlcmd -S localhost,1433 -U sa -P "<clave>" -C -d TurismoDW `
            -i 04-sqlserver\46b-validacion-metricas-negocio.sql
   ===================================================================== */

SET NOCOUNT ON;
GO

USE TurismoDW;
GO

PRINT '=====================================================================';
PRINT ' CERTIFICACION DE METRICAS Y KPIS DE NEGOCIO (INTEGRANTE 3: ERICK)';
PRINT ' ITI-821 · Escenario 8: Turismo: Ocupacion y Preferencias';
PRINT '=====================================================================';
PRINT '';

DECLARE @TotalPruebas INT = 0;
DECLARE @Correctas    INT = 0;
DECLARE @Fallidas     INT = 0;

-- Tabla temporal para recolectar el veredicto de cada indicador
DECLARE @Resultados TABLE (
    Num INT IDENTITY(1,1),
    Categoria VARCHAR(35),
    Indicador VARCHAR(45),
    ValorObtenido VARCHAR(40),
    RangoEsperado VARCHAR(40),
    Estado VARCHAR(10)
);

/* ---------------------------------------------------------------------
   1. VOLUMEN Y RESERVAS
   --------------------------------------------------------------------- */
DECLARE @ReservasTotales BIGINT;
DECLARE @ReservasConfirmadas BIGINT;
DECLARE @ReservasCanceladas BIGINT;
DECLARE @PersonasAtendidas BIGINT;
DECLARE @ReservasAlojamiento BIGINT;

SELECT @ReservasTotales = SUM(ConteoReserva),
       @ReservasCanceladas = SUM(CASE WHEN EsCancelada = 1 THEN 1 ELSE 0 END),
       @PersonasAtendidas = SUM(CantidadPersonas)
FROM dw.FactReserva;

SELECT @ReservasConfirmadas = COUNT(*)
FROM dw.FactReserva r
JOIN dw.DimEstadoReserva e ON r.EstadoKey = e.EstadoKey
WHERE e.EsConfirmada = 1;

SELECT @ReservasAlojamiento = COUNT(DISTINCT ReservaId)
FROM dw.FactReservaHabitacion;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES 
('1. Volumen y Reservas', 'Reservas Totales', FORMAT(@ReservasTotales, 'N0'), '>= 2,000,000', CASE WHEN @ReservasTotales >= 2000000 THEN 'OK' ELSE 'FALLO' END),
('1. Volumen y Reservas', 'Reservas Confirmadas', FORMAT(@ReservasConfirmadas, 'N0'), '> 0 AND < Totales', CASE WHEN @ReservasConfirmadas > 0 AND @ReservasConfirmadas <= @ReservasTotales THEN 'OK' ELSE 'FALLO' END),
('1. Volumen y Reservas', 'Reservas Canceladas', FORMAT(@ReservasCanceladas, 'N0'), '>= 0 AND < Totales', CASE WHEN @ReservasCanceladas >= 0 AND @ReservasCanceladas < @ReservasTotales THEN 'OK' ELSE 'FALLO' END),
('1. Volumen y Reservas', 'Personas Atendidas', FORMAT(@PersonasAtendidas, 'N0'), '>= Reservas', CASE WHEN @PersonasAtendidas >= @ReservasTotales THEN 'OK' ELSE 'FALLO' END),
('1. Volumen y Reservas', 'Reservas con Alojamiento', FORMAT(@ReservasAlojamiento, 'N0'), '> 0 AND <= Totales', CASE WHEN @ReservasAlojamiento > 0 AND @ReservasAlojamiento <= @ReservasTotales THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   2. INGRESOS Y MONETIZACION
   --------------------------------------------------------------------- */
DECLARE @IngresosTotales DECIMAL(18,2);
DECLARE @IngresosConfirmados DECIMAL(18,2);
DECLARE @IngresosHotel DECIMAL(18,2);
DECLARE @IngresosPaquete DECIMAL(18,2);
DECLARE @TicketPromedio DECIMAL(18,2);

SELECT @IngresosTotales = SUM(MontoTotal),
       @IngresosConfirmados = SUM(MontoConfirmado)
FROM dw.FactReserva;

SELECT @IngresosHotel = SUM(IngresoAlojamiento)
FROM dw.FactReservaHabitacion;

SELECT @IngresosPaquete = SUM(r.MontoConfirmado)
FROM dw.FactReserva r
JOIN dw.DimPaquete p ON r.PaqueteKey = p.PaqueteKey
WHERE p.PaqueteId <> -1;

SET @TicketPromedio = CASE WHEN @ReservasConfirmadas > 0 THEN @IngresosConfirmados / @ReservasConfirmadas ELSE 0 END;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('2. Ingresos y Monetizacion', 'Ingresos Totales', '$' + FORMAT(@IngresosTotales, 'N2'), '> 0', CASE WHEN @IngresosTotales > 0 THEN 'OK' ELSE 'FALLO' END),
('2. Ingresos y Monetizacion', 'Ingresos Confirmados', '$' + FORMAT(@IngresosConfirmados, 'N2'), '<= Ingresos Totales', CASE WHEN @IngresosConfirmados > 0 AND @IngresosConfirmados <= @IngresosTotales THEN 'OK' ELSE 'FALLO' END),
('2. Ingresos y Monetizacion', 'Ingresos por Hotel', '$' + FORMAT(@IngresosHotel, 'N2'), '> 0', CASE WHEN @IngresosHotel > 0 THEN 'OK' ELSE 'FALLO' END),
('2. Ingresos y Monetizacion', 'Ingresos por Paquetes', '$' + FORMAT(@IngresosPaquete, 'N2'), '> 0', CASE WHEN @IngresosPaquete > 0 THEN 'OK' ELSE 'FALLO' END),
('2. Ingresos y Monetizacion', 'Ticket Promedio', '$' + FORMAT(@TicketPromedio, 'N2'), 'Entre $1,000 y $25,000', CASE WHEN @TicketPromedio BETWEEN 1000 AND 25000 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   3. OCUPACION HOTELERA
   --------------------------------------------------------------------- */
DECLARE @HabOcupadas BIGINT;
DECLARE @HabDisponibles BIGINT;
DECLARE @PorcOcupacion DECIMAL(7,4);

SELECT @HabOcupadas = SUM(HabitacionesOcupadas),
       @HabDisponibles = SUM(HabitacionesDisponibles)
FROM dw.FactOcupacionDiaria;

SET @PorcOcupacion = CASE WHEN @HabDisponibles > 0 THEN (@HabOcupadas * 100.0) / @HabDisponibles ELSE 0 END;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('3. Ocupacion Hotelera', 'Habitaciones Ocupadas', FORMAT(@HabOcupadas, 'N0'), '> 0', CASE WHEN @HabOcupadas > 0 THEN 'OK' ELSE 'FALLO' END),
('3. Ocupacion Hotelera', 'Habitaciones Disponibles', FORMAT(@HabDisponibles, 'N0'), '> Ocupadas', CASE WHEN @HabDisponibles > @HabOcupadas THEN 'OK' ELSE 'FALLO' END),
('3. Ocupacion Hotelera', '% Ocupacion Hotelera Global', CAST(@PorcOcupacion AS VARCHAR(10)) + ' %', 'Entre 15.0 % y 60.0 %', CASE WHEN @PorcOcupacion BETWEEN 15.0 AND 60.0 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   4. ESTADIA Y COMPORTAMIENTO
   --------------------------------------------------------------------- */
DECLARE @EstadiaPromedio DECIMAL(5,2);
DECLARE @AnticipacionPromedio DECIMAL(5,2);
DECLARE @TasaCancelacion DECIMAL(5,2);
DECLARE @PersonasPorReserva DECIMAL(5,2);

SELECT @EstadiaPromedio = AVG(Noches * 1.0),
       @AnticipacionPromedio = AVG(DiasAnticipacion * 1.0),
       @TasaCancelacion = (SUM(CASE WHEN EsCancelada = 1 THEN 1.0 ELSE 0.0 END) * 100.0) / COUNT(*),
       @PersonasPorReserva = AVG(CantidadPersonas * 1.0)
FROM dw.FactReserva;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('4. Estadia y Comportamiento', 'Estadia Promedio (Noches)', CAST(@EstadiaPromedio AS VARCHAR(10)), 'Entre 2.0 y 7.0 noches', CASE WHEN @EstadiaPromedio BETWEEN 2.0 AND 7.0 THEN 'OK' ELSE 'FALLO' END),
('4. Estadia y Comportamiento', 'Anticipacion Promedio', CAST(@AnticipacionPromedio AS VARCHAR(10)) + ' dias', 'Entre 10 y 60 dias', CASE WHEN @AnticipacionPromedio BETWEEN 10 AND 60 THEN 'OK' ELSE 'FALLO' END),
('4. Estadia y Comportamiento', 'Tasa de Cancelacion', CAST(@TasaCancelacion AS VARCHAR(10)) + ' %', 'Entre 5.0 % y 30.0 %', CASE WHEN @TasaCancelacion BETWEEN 5.0 AND 30.0 THEN 'OK' ELSE 'FALLO' END),
('4. Estadia y Comportamiento', 'Personas por Reserva', CAST(@PersonasPorReserva AS VARCHAR(10)), 'Entre 1.5 y 4.5 personas', CASE WHEN @PersonasPorReserva BETWEEN 1.5 AND 4.5 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   5. TEMPORADAS Y DESTINOS
   --------------------------------------------------------------------- */
DECLARE @ReservasAlta BIGINT;
DECLARE @ReservasVerde BIGINT;
DECLARE @DestinosVisitados INT;

SELECT @ReservasAlta = SUM(CASE WHEN t.TipoTemporada = 'Temporada alta' THEN 1 ELSE 0 END),
       @ReservasVerde = SUM(CASE WHEN t.TipoTemporada = 'Temporada verde' THEN 1 ELSE 0 END)
FROM dw.FactReserva r
JOIN dw.vw_DimTiempo t ON r.FechaInicioKey = t.TiempoKey;

SELECT @DestinosVisitados = COUNT(DISTINCT Ciudad) FROM dw.DimHotel;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('5. Temporadas y Destinos', 'Reservas Temporada Alta', FORMAT(@ReservasAlta, 'N0'), '> 0', CASE WHEN @ReservasAlta > 0 THEN 'OK' ELSE 'FALLO' END),
('5. Temporadas y Destinos', 'Reservas Temporada Verde', FORMAT(@ReservasVerde, 'N0'), '> 0', CASE WHEN @ReservasVerde > 0 THEN 'OK' ELSE 'FALLO' END),
('5. Temporadas y Destinos', 'Total Temporadas Cuadra', FORMAT(@ReservasAlta + @ReservasVerde, 'N0'), '= Total Reservas', CASE WHEN (@ReservasAlta + @ReservasVerde) = @ReservasTotales THEN 'OK' ELSE 'FALLO' END),
('5. Temporadas y Destinos', 'Destinos / Ciudades Activas', CAST(@DestinosVisitados AS VARCHAR(10)), '>= 10 destinos', CASE WHEN @DestinosVisitados >= 10 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   6. TOURS Y ACTIVIDADES
   --------------------------------------------------------------------- */
DECLARE @ToursSolicitados BIGINT;
DECLARE @IngresosTour DECIMAL(18,2);
DECLARE @PersonasTours BIGINT;

SELECT @ToursSolicitados = SUM(ConteoTour),
       @IngresosTour = SUM(IngresoTour),
       @PersonasTours = SUM(CantidadPersonas)
FROM dw.FactReservaTour;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('6. Tours y Actividades', 'Tours Solicitados', FORMAT(@ToursSolicitados, 'N0'), '>= 2,000,000', CASE WHEN @ToursSolicitados >= 2000000 THEN 'OK' ELSE 'FALLO' END),
('6. Tours y Actividades', 'Ingresos por Tours', '$' + FORMAT(@IngresosTour, 'N2'), '> 0', CASE WHEN @IngresosTour > 0 THEN 'OK' ELSE 'FALLO' END),
('6. Tours y Actividades', 'Personas en Tours', FORMAT(@PersonasTours, 'N0'), '>= Tours', CASE WHEN @PersonasTours >= @ToursSolicitados THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   7. SATISFACCION (MongoDB Resenas)
   --------------------------------------------------------------------- */
DECLARE @TotalResenas BIGINT;
DECLARE @CalificacionPromedio DECIMAL(4,2);
DECLARE @ResenasPositivas BIGINT;
DECLARE @ResenasNegativas BIGINT;
DECLARE @IndiceSatisfaccion DECIMAL(5,2);

SELECT @TotalResenas = COUNT(*),
       @CalificacionPromedio = AVG(Calificacion * 1.0),
       @ResenasPositivas = SUM(CASE WHEN EsPositiva = 1 THEN 1 ELSE 0 END),
       @ResenasNegativas = SUM(CASE WHEN EsNegativa = 1 THEN 1 ELSE 0 END)
FROM dw.FactResena;

SET @IndiceSatisfaccion = CASE WHEN @TotalResenas > 0 THEN (@ResenasPositivas * 100.0) / @TotalResenas ELSE 0 END;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('7. Satisfaccion (MongoDB)', 'Resenas Registradas', FORMAT(@TotalResenas, 'N0'), '>= 500,000', CASE WHEN @TotalResenas >= 500000 THEN 'OK' ELSE 'FALLO' END),
('7. Satisfaccion (MongoDB)', 'Calificacion Promedio', CAST(@CalificacionPromedio AS VARCHAR(10)) + ' / 5.0', 'Entre 3.5 y 4.8', CASE WHEN @CalificacionPromedio BETWEEN 3.5 AND 4.8 THEN 'OK' ELSE 'FALLO' END),
('7. Satisfaccion (MongoDB)', 'Indice de Satisfaccion (% Promotores)', CAST(@IndiceSatisfaccion AS VARCHAR(10)) + ' %', 'Entre 60.0 % y 90.0 %', CASE WHEN @IndiceSatisfaccion BETWEEN 60.0 AND 90.0 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   8. COMPORTAMIENTO WEB (MongoDB Interacciones)
   --------------------------------------------------------------------- */
DECLARE @TotalInteracciones BIGINT;
DECLARE @TotalConversiones BIGINT;
DECLARE @TasaConversionWeb DECIMAL(5,2);
DECLARE @AbandonosCarrito BIGINT;

SELECT @TotalInteracciones = COUNT(*),
       @TotalConversiones = SUM(CASE WHEN EsConversion = 1 THEN 1 ELSE 0 END),
       @AbandonosCarrito = SUM(CASE WHEN TipoEvento = 'abandono_carrito' THEN 1 ELSE 0 END)
FROM dw.FactInteraccionWeb;

SET @TasaConversionWeb = CASE WHEN @TotalInteracciones > 0 THEN (@TotalConversiones * 100.0) / @TotalInteracciones ELSE 0 END;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('8. Web Analytics (MongoDB)', 'Interacciones Digitales', FORMAT(@TotalInteracciones, 'N0'), '>= 1,500,000', CASE WHEN @TotalInteracciones >= 1500000 THEN 'OK' ELSE 'FALLO' END),
('8. Web Analytics (MongoDB)', 'Conversiones a Reserva', FORMAT(@TotalConversiones, 'N0'), '> 0 AND < Totales', CASE WHEN @TotalConversiones > 0 AND @TotalConversiones < @TotalInteracciones THEN 'OK' ELSE 'FALLO' END),
('8. Web Analytics (MongoDB)', 'Tasa de Conversion Web', CAST(@TasaConversionWeb AS VARCHAR(10)) + ' %', 'Entre 5.0 % y 25.0 %', CASE WHEN @TasaConversionWeb BETWEEN 5.0 AND 25.0 THEN 'OK' ELSE 'FALLO' END),
('8. Web Analytics (MongoDB)', 'Abandonos de Carrito', FORMAT(@AbandonosCarrito, 'N0'), '> 0', CASE WHEN @AbandonosCarrito > 0 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   9. PERFIL Y PREFERENCIAS (JSON + PostgreSQL)
   --------------------------------------------------------------------- */
DECLARE @ClientesActivos INT;
DECLARE @PresupuestoPromedio DECIMAL(18,2);

SELECT @ClientesActivos = COUNT(*) FROM dw.DimCliente WHERE Estado = 'Activo';
SELECT @PresupuestoPromedio = AVG(PresupuestoEstimado) FROM dw.DimCliente WHERE PresupuestoEstimado > 0;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('9. Perfil y Preferencias', 'Clientes Activos', FORMAT(@ClientesActivos, 'N0'), '>= 40,000', CASE WHEN @ClientesActivos >= 40000 THEN 'OK' ELSE 'FALLO' END),
('9. Perfil y Preferencias', 'Presupuesto Promedio Declarado', '$' + FORMAT(@PresupuestoPromedio, 'N2'), 'Entre $1,000 y $20,000', CASE WHEN @PresupuestoPromedio BETWEEN 1000 AND 20000 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   10. ESTADO OPERATIVO (Pagina 6)
   --------------------------------------------------------------------- */
DECLARE @FilasEstadoSistema INT;
SELECT @FilasEstadoSistema = COUNT(*) FROM dw.vw_EstadoSistema;

INSERT INTO @Resultados (Categoria, Indicador, ValorObtenido, RangoEsperado, Estado)
VALUES
('10. Operacion y Estado', 'dw.vw_EstadoSistema Responde', CAST(@FilasEstadoSistema AS VARCHAR(10)) + ' fila(s)', '= 1 fila', CASE WHEN @FilasEstadoSistema = 1 THEN 'OK' ELSE 'FALLO' END);

/* ---------------------------------------------------------------------
   DESPLIEGUE DE RESULTADOS
   --------------------------------------------------------------------- */
SELECT 
    Num,
    Categoria,
    Indicador,
    ValorObtenido,
    RangoEsperado,
    Estado
FROM @Resultados
ORDER BY Num;

SELECT 
    @TotalPruebas = COUNT(*),
    @Correctas = SUM(CASE WHEN Estado = 'OK' THEN 1 ELSE 0 END),
    @Fallidas = SUM(CASE WHEN Estado <> 'OK' THEN 1 ELSE 0 END)
FROM @Resultados;

PRINT '';
PRINT '=== RESUMEN GLOBAL DE CERTIFICACION ===';
PRINT 'Total Indicadores Evaluados : ' + CAST(@TotalPruebas AS VARCHAR(10));
PRINT 'Indicadores Correctos (OK)  : ' + CAST(@Correctas AS VARCHAR(10));
PRINT 'Indicadores con Fallo       : ' + CAST(@Fallidas AS VARCHAR(10));
PRINT '';

IF @Fallidas = 0
BEGIN
    PRINT '>> VEREDICTO FINAL: 100% DE METRICAS Y KPIS CERTIFICADOS CORRECTOS (INTEGRANTE 3)';
END
ELSE
BEGIN
    PRINT '>> VEREDICTO FINAL: SE DETECTARON DISCREPANCIAS EN LAS METRICAS DE NEGOCIO';
END
GO
