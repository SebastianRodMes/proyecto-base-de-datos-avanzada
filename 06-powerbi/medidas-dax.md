# Medidas DAX del reporte TurismoDW

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Estas medidas ya vienen incluidas en el modelo semántico TMDL de `TurismoDW.pbip`. Este documento existe para que se puedan revisar, discutir y, si hace falta, reescribir a mano en Power BI Desktop sin abrir el proyecto.

Los ocho KPIs que exige el escenario están marcados con **★**.

---

## Tabla de medidas

Todas viven en una tabla vacía llamada `_Medidas`, para que no queden dispersas entre las tablas de datos. Es la convención estándar y hace que el panel de campos sea legible.

---

## 1. Reservas y volumen

```dax
Reservas =
SUM ( FactReserva[ConteoReserva] )
```
> Se suma una columna de unos en lugar de usar `COUNTROWS`. Con 2 millones de filas, `SUM` sobre una columna `tinyint` es más rápido que contar filas, porque el motor VertiPaq comprime esa columna a casi nada.

```dax
Reservas confirmadas =
CALCULATE ( [Reservas], DimEstadoReserva[EsConfirmada] = TRUE () )
```

```dax
Reservas canceladas =
CALCULATE ( [Reservas], DimEstadoReserva[EsCancelada] = TRUE () )
```

```dax
Personas atendidas =
SUM ( FactReserva[CantidadPersonas] )
```

---

## 2. ★ Ingresos

```dax
Ingresos confirmados =
SUM ( FactReserva[MontoConfirmado] )
```
> `MontoConfirmado` ya viene en 0 para las reservas no confirmadas, calculado en el ETL. Evita un `CALCULATE` con filtro en cada visual.

```dax
Ingresos totales =
SUM ( FactReserva[MontoTotal] )
```

```dax
★ Ingresos por hotel =
SUM ( FactReservaHabitacion[IngresoAlojamiento] )
```

```dax
★ Ingresos por paquete =
CALCULATE ( [Ingresos confirmados], DimPaquete[PaqueteId] <> -1 )
```

```dax
Ticket promedio =
DIVIDE ( [Ingresos confirmados], [Reservas confirmadas] )
```
> Siempre `DIVIDE` y nunca `/`: devuelve blanco en lugar de error cuando el denominador es cero, que ocurre en cualquier celda de la matriz sin reservas.

---

## 3. ★ Ocupación hotelera

```dax
Habitaciones ocupadas =
SUM ( FactOcupacionDiaria[HabitacionesOcupadas] )
```

```dax
Habitaciones disponibles =
SUM ( FactOcupacionDiaria[HabitacionesDisponibles] )
```

```dax
★ % Ocupación hotelera =
DIVIDE ( [Habitaciones ocupadas], [Habitaciones disponibles] )
```
> **La razón por la que el ETL guarda numerador y denominador separados.** Si se hubiera almacenado el porcentaje por día y hotel, al agregar por mes o por país habría que promediar porcentajes —lo cual es incorrecto, porque cada día pesa distinto—. Sumando numerador y denominador por separado y dividiendo al final, el resultado es correcto en cualquier nivel de agregación.

```dax
% Ocupación mes anterior =
CALCULATE ( [% Ocupación hotelera], DATEADD ( DimTiempo[Fecha], -1, MONTH ) )
```

```dax
Variación de ocupación =
[% Ocupación hotelera] - [% Ocupación mes anterior]
```

---

## 4. ★ Estadía y comportamiento

```dax
★ Promedio de estadía (noches) =
DIVIDE ( SUM ( FactReserva[Noches] ), [Reservas] )
```
> `DIVIDE(SUM, COUNT)` en lugar de `AVERAGE`: da el mismo número pero se filtra de forma predecible y no se rompe si hay filas sin valor.

```dax
Días de anticipación promedio =
DIVIDE ( SUM ( FactReserva[DiasAnticipacion] ), [Reservas] )
```

```dax
Tasa de cancelación =
DIVIDE ( [Reservas canceladas], [Reservas] )
```

```dax
Personas por reserva =
DIVIDE ( [Personas atendidas], [Reservas] )
```

---

## 5. ★ Temporadas y destinos

```dax
★ Reservas en temporada alta =
CALCULATE ( [Reservas], DimTiempo[TipoTemporada] = "Temporada alta" )
```

```dax
Reservas en temporada verde =
CALCULATE ( [Reservas], DimTiempo[TipoTemporada] = "Temporada verde" )
```

```dax
Concentración en temporada alta =
DIVIDE ( [Reservas en temporada alta], [Reservas] )
```

```dax
★ Destinos visitados =
DISTINCTCOUNT ( DimHotel[Ciudad] )
```

```dax
Destino líder =
VAR Ranking =
    TOPN (
        1,
        SUMMARIZE ( DimHotel, DimHotel[Ciudad], "@r", [Reservas alojamiento] ),
        [@r], DESC
    )
RETURN
    MAXX ( Ranking, DimHotel[Ciudad] )
```

```dax
Reservas alojamiento =
DISTINCTCOUNT ( FactReservaHabitacion[ReservaId] )
```
> Grano distinto: una reserva puede tener varias líneas de habitación, así que contar filas inflaría el número. `DISTINCTCOUNT` sobre la clave de negocio da el conteo real de reservas.

---

## 6. ★ Tours

```dax
★ Tours solicitados =
SUM ( FactReservaTour[ConteoTour] )
```

```dax
Ingresos por tour =
SUM ( FactReservaTour[IngresoTour] )
```

```dax
Personas en tours =
SUM ( FactReservaTour[CantidadPersonas] )
```

```dax
Tour líder =
VAR Ranking =
    TOPN (
        1,
        SUMMARIZE ( DimTour, DimTour[Nombre], "@r", [Tours solicitados] ),
        [@r], DESC
    )
RETURN
    MAXX ( Ranking, DimTour[Nombre] )
```

---

## 7. ★ Satisfacción (origen MongoDB)

```dax
Reseñas =
SUM ( FactResena[ConteoResena] )
```

```dax
Calificación promedio =
DIVIDE ( SUMX ( FactResena, FactResena[Calificacion] ), [Reseñas] )
```

```dax
Reseñas positivas =
SUM ( FactResena[EsPositiva] )
```

```dax
Reseñas negativas =
SUM ( FactResena[EsNegativa] )
```

```dax
★ Índice de satisfacción =
DIVIDE ( [Reseñas positivas], [Reseñas] )
```
> Proporción de promotores (4–5 estrellas) sobre el total. Se eligió esta forma y no el NPS clásico (promotores − detractores) porque la escala del escenario es de 1 a 5, no de 0 a 10, y el porcentaje de promotores es directamente interpretable en una tarjeta.

```dax
NPS aproximado =
DIVIDE ( [Reseñas positivas] - [Reseñas negativas], [Reseñas] )
```

```dax
% Reseñas verificadas =
DIVIDE ( SUM ( FactResena[EsVerificada] ), [Reseñas] )
```

---

## 8. Comportamiento web (origen MongoDB)

```dax
Interacciones =
SUM ( FactInteraccionWeb[ConteoEvento] )
```

```dax
Conversiones =
SUM ( FactInteraccionWeb[EsConversion] )
```

```dax
Tasa de conversión web =
DIVIDE ( [Conversiones], [Interacciones] )
```

```dax
Duración media de sesión (seg) =
DIVIDE ( SUM ( FactInteraccionWeb[DuracionSegundos] ), [Interacciones] )
```

```dax
Búsquedas =
CALCULATE ( [Interacciones], FactInteraccionWeb[TipoEvento] = "busqueda" )
```

```dax
Abandonos de carrito =
CALCULATE ( [Interacciones], FactInteraccionWeb[TipoEvento] = "abandono_carrito" )
```

---

## 9. Perfil del visitante

```dax
Clientes activos =
CALCULATE ( DISTINCTCOUNT ( DimCliente[ClienteId] ), DimCliente[Estado] = "Activo" )
```

```dax
Clientes con reserva =
DISTINCTCOUNT ( FactReserva[ClienteKey] )
```

```dax
Presupuesto promedio declarado =
AVERAGE ( DimCliente[PresupuestoEstimado] )
```

```dax
Brecha presupuesto vs gasto =
[Ticket promedio] - [Presupuesto promedio declarado]
```
> Compara lo que el visitante dijo que gastaría (preferencias, RF-09/RF-10) contra lo que gastó de verdad. Es el tipo de cruce que justifica haber traído las preferencias al modelo.

---

## 10. Comparativos temporales

```dax
Reservas año anterior =
CALCULATE ( [Reservas], SAMEPERIODLASTYEAR ( DimTiempo[Fecha] ) )
```

```dax
Ingresos año anterior =
CALCULATE ( [Ingresos confirmados], SAMEPERIODLASTYEAR ( DimTiempo[Fecha] ) )
```

```dax
Crecimiento de ingresos YoY =
DIVIDE ( [Ingresos confirmados] - [Ingresos año anterior], [Ingresos año anterior] )
```

```dax
Ingresos acumulados del año =
TOTALYTD ( [Ingresos confirmados], DimTiempo[Fecha] )
```

> Las cuatro dependen de que `DimTiempo` esté **marcada como tabla de fechas** en Power BI. Sin esa marca, las funciones de inteligencia de tiempo devuelven resultados erróneos de forma silenciosa: no dan error, dan números mal.

---

## 11. Estado del sistema (página 6)

```dax
Nodo activo =
SELECTEDVALUE ( EstadoSistema[NodoActual] )
```

```dax
Estado del mirroring =
SELECTEDVALUE ( EstadoSistema[EstadoMirroring] )
```

```dax
Última carga =
SELECTEDVALUE ( EstadoSistema[UltimaCargaFin] )
```

```dax
Registros rechazados en la última carga =
SELECTEDVALUE ( EstadoSistema[UltimaCargaRechazos] )
```

```dax
Semáforo de frescura =
VAR Horas = SELECTEDVALUE ( EstadoSistema[HorasDesdeUltimaCarga] )
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Horas ),  "Sin cargas registradas",
        Horas <= 24,        "Datos al día",
        Horas <= 72,        "Datos con retraso",
                            "Datos desactualizados"
    )
```

---

## Formato

| Medidas | Formato |
|---|---|
| `% Ocupación hotelera`, `Tasa de cancelación`, `Índice de satisfacción`, `Tasa de conversión web`, `Crecimiento de ingresos YoY`, `Concentración en temporada alta`, `% Reseñas verificadas`, `NPS aproximado` | `0.0%` |
| `Ingresos *`, `Ticket promedio`, `Presupuesto promedio declarado`, `Brecha presupuesto vs gasto` | `$#,0;-$#,0` |
| `Reservas`, `Personas *`, `Reseñas`, `Interacciones`, `Tours solicitados` | `#,0` |
| `Promedio de estadía (noches)`, `Días de anticipación promedio`, `Calificación promedio`, `Personas por reserva` | `0.00` |
