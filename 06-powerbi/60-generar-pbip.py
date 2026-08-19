"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

60-generar-pbip.py
==================

Genera el proyecto de Power BI en formato PBIP (Power BI Project), con el
modelo semantico escrito en TMDL.

Por que PBIP y no un .pbix
--------------------------
Un .pbix es un contenedor binario: no se puede generar por script, no se
puede revisar en un diff y no se puede versionar de forma util. PBIP es el
formato de proyecto de Power BI Desktop, donde el modelo semantico son
archivos .tmdl de texto plano. Eso permite:

  * generar el modelo completo (tablas, relaciones, jerarquias, 45 medidas
    DAX con su formato) sin armarlo a mano en la interfaz;
  * versionarlo junto al resto del entregable;
  * que otro integrante vea exactamente que cambio en una medida.

Power BI Desktop abre el .pbip directamente y permite guardar como .pbix
para la entrega final.

Requisito previo en Power BI Desktop
------------------------------------
    Archivo > Opciones > Caracteristicas de vista previa
      [x] Guardar archivos de proyecto de Power BI (.pbip)
      [x] Formato TMDL para el modelo semantico
      [x] Formato PBIR para el reporte

Uso
---
    python 60-generar-pbip.py
"""

from __future__ import annotations

import json
import shutil
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "05-etl"))

from etl import config  # noqa: E402


RAIZ = Path(__file__).resolve().parent
NOMBRE = "TurismoDW"
DIR_MODELO = RAIZ / f"{NOMBRE}.SemanticModel"
DIR_REPORTE = RAIZ / f"{NOMBRE}.Report"


# ===========================================================================
# Definicion del modelo
# ===========================================================================

# (nombre de tabla en el modelo, vista de origen, es_tabla_de_hechos)
TABLAS = [
    ("DimTiempo",             "vw_DimTiempo",             False),
    ("DimCliente",            "vw_DimCliente",            False),
    ("DimHotel",              "vw_DimHotel",              False),
    ("DimTipoHabitacion",     "vw_DimTipoHabitacion",     False),
    ("DimTour",               "vw_DimTour",               False),
    ("DimPaquete",            "vw_DimPaquete",            False),
    ("DimEstadoReserva",      "vw_DimEstadoReserva",      False),
    ("DimCanal",              "vw_DimCanal",              False),
    ("FactReserva",           "vw_FactReserva",           True),
    ("FactReservaHabitacion", "vw_FactReservaHabitacion", True),
    ("FactReservaTour",       "vw_FactReservaTour",       True),
    ("FactOcupacionDiaria",   "vw_FactOcupacionDiaria",   True),
    ("FactResena",            "vw_FactResena",            True),
    ("FactInteraccionWeb",    "vw_FactInteraccionWeb",    True),
    ("EstadoSistema",         "vw_EstadoSistema",         False),
    ("CalidadDatos",          "vw_CalidadDatos",          False),
]

# Columnas por tabla: (nombre, tipoDatos, formato, oculta, tipoResumen)
#   tipoDatos : int64 | double | string | dateTime | boolean | decimal
#   Las claves subrogadas se ocultan: son plomeria del modelo, no algo que
#   el usuario del reporte deba arrastrar a un visual.
C = lambda n, t, fmt=None, oculta=False, resumen="none": (n, t, fmt, oculta, resumen)

COLUMNAS: dict[str, list] = {
    "DimTiempo": [
        C("TiempoKey", "int64", oculta=True),
        C("Fecha", "dateTime", "General Date"),
        C("Anio", "int64"),
        C("Trimestre", "int64", oculta=True),
        C("NombreTrimestre", "string"),
        C("Mes", "int64", oculta=True),
        C("NombreMes", "string"),
        C("NombreMesCorto", "string", oculta=True),
        C("AnioMes", "int64", oculta=True),
        C("AnioMesEtiqueta", "string"),
        C("Semana", "int64", oculta=True),
        C("DiaDelMes", "int64", oculta=True),
        C("DiaDelAnio", "int64", oculta=True),
        C("DiaSemana", "int64", oculta=True),
        C("NombreDiaSemana", "string"),
        C("TipoDia", "string"),
        C("TemporadaTuristica", "string"),
        C("TipoTemporada", "string"),
        C("Semestre", "int64", oculta=True),
        C("NombreSemestre", "string"),
    ],
    "DimCliente": [
        C("ClienteKey", "int64", oculta=True),
        C("ClienteId", "int64", oculta=True),
        C("Identificacion", "string"),
        C("NombreCompleto", "string"),
        C("Correo", "string"),
        C("PaisOrigen", "string"),
        C("Edad", "int64", "#,0"),
        C("RangoEdad", "string"),
        C("Estado", "string"),
        C("FechaRegistro", "dateTime", "Short Date"),
        C("DestinosPreferidos", "string"),
        C("TipoAlojamiento", "string"),
        C("ActividadesFavoritas", "string"),
        C("PresupuestoEstimado", "decimal", "$#,0"),
        C("RangoPresupuesto", "string"),
        C("TemporadaViaje", "string"),
        C("Idioma", "string"),
        C("Dieta", "string"),
        C("GrupoViaje", "string"),
        C("SegmentoVip", "string"),
        C("FuenteDatos", "string"),
    ],
    "DimHotel": [
        C("HotelKey", "int64", oculta=True),
        C("HotelId", "int64", oculta=True),
        C("Nombre", "string"),
        C("Categoria", "string"),
        C("NumeroEstrellas", "int64"),
        C("Ciudad", "string"),
        C("Pais", "string"),
        C("PaisCiudad", "string"),
        C("Servicios", "string"),
        C("CapacidadTotal", "int64", "#,0"),
        C("RangoCapacidad", "string"),
        C("Estado", "string"),
    ],
    "DimTipoHabitacion": [
        C("TipoHabitacionKey", "int64", oculta=True),
        C("TipoHabitacionId", "int64", oculta=True),
        C("HotelKey", "int64", oculta=True),
        C("TipoHabitacion", "string"),
        C("CapacidadPersonas", "int64"),
        C("TarifaBase", "decimal", "$#,0.00"),
        C("RangoTarifa", "string"),
        C("CantidadDisponible", "int64", "#,0"),
        C("Estado", "string"),
    ],
    "DimTour": [
        C("TourKey", "int64", oculta=True),
        C("TourId", "int64", oculta=True),
        C("Nombre", "string"),
        C("Destino", "string"),
        C("TipoActividad", "string"),
        C("Proveedor", "string"),
        C("DuracionHoras", "int64"),
        C("RangoDuracion", "string"),
        C("CupoMaximo", "int64"),
        C("Precio", "decimal", "$#,0.00"),
        C("Estado", "string"),
    ],
    "DimPaquete": [
        C("PaqueteKey", "int64", oculta=True),
        C("PaqueteId", "int64", oculta=True),
        C("Nombre", "string"),
        C("TipoPaquete", "string"),
        C("DuracionDias", "int64"),
        C("RangoDuracion", "string"),
        C("PrecioTotal", "decimal", "$#,0.00"),
        C("RangoPrecio", "string"),
        C("ServiciosAdicionales", "string"),
        C("Estado", "string"),
        C("FuenteDatos", "string"),
    ],
    "DimEstadoReserva": [
        C("EstadoKey", "int64", oculta=True),
        C("Estado", "string"),
        C("Descripcion", "string"),
        C("EsConfirmada", "boolean"),
        C("EsCancelada", "boolean"),
        C("CuentaParaIngreso", "boolean"),
    ],
    "DimCanal": [
        C("CanalKey", "int64", oculta=True),
        C("Canal", "string"),
        C("Dispositivo", "string"),
        C("TipoDispositivo", "string"),
    ],
    "FactReserva": [
        C("ReservaId", "int64", oculta=True),
        C("FechaReservaKey", "int64", oculta=True),
        C("FechaInicioKey", "int64", oculta=True),
        C("FechaFinKey", "int64", oculta=True),
        C("ClienteKey", "int64", oculta=True),
        C("PaqueteKey", "int64", oculta=True),
        C("EstadoKey", "int64", oculta=True),
        C("CantidadPersonas", "int64", "#,0", False, "sum"),
        C("MontoTotal", "decimal", "$#,0.00", False, "sum"),
        C("Noches", "int64", "#,0", False, "sum"),
        C("DiasAnticipacion", "int64", "#,0", False, "sum"),
        C("MontoConfirmado", "decimal", "$#,0.00", True, "sum"),
        C("EsCancelada", "int64", oculta=True, resumen="sum"),
        C("ConteoReserva", "int64", oculta=True, resumen="sum"),
    ],
    "FactReservaHabitacion": [
        C("ReservaHabitacionId", "int64", oculta=True),
        C("ReservaId", "int64", oculta=True),
        C("FechaInicioKey", "int64", oculta=True),
        C("ClienteKey", "int64", oculta=True),
        C("HotelKey", "int64", oculta=True),
        C("TipoHabitacionKey", "int64", oculta=True),
        C("EstadoKey", "int64", oculta=True),
        C("CantidadHabitaciones", "int64", "#,0", False, "sum"),
        C("TarifaAplicada", "decimal", "$#,0.00", False, "average"),
        C("Noches", "int64", oculta=True, resumen="sum"),
        C("NochesHabitacion", "int64", "#,0", False, "sum"),
        C("IngresoAlojamiento", "decimal", "$#,0.00", True, "sum"),
    ],
    "FactReservaTour": [
        C("ReservaTourId", "int64", oculta=True),
        C("ReservaId", "int64", oculta=True),
        C("FechaInicioKey", "int64", oculta=True),
        C("ClienteKey", "int64", oculta=True),
        C("TourKey", "int64", oculta=True),
        C("EstadoKey", "int64", oculta=True),
        C("CantidadPersonas", "int64", "#,0", False, "sum"),
        C("PrecioAplicado", "decimal", "$#,0.00", False, "average"),
        C("IngresoTour", "decimal", "$#,0.00", True, "sum"),
        C("ConteoTour", "int64", oculta=True, resumen="sum"),
    ],
    "FactOcupacionDiaria": [
        C("TiempoKey", "int64", oculta=True),
        C("HotelKey", "int64", oculta=True),
        C("HabitacionesOcupadas", "int64", "#,0", True, "sum"),
        C("HabitacionesDisponibles", "int64", "#,0", True, "sum"),
        C("PersonasAlojadas", "int64", "#,0", False, "sum"),
        C("IngresoDia", "decimal", "$#,0.00", False, "sum"),
        C("ReservasActivas", "int64", "#,0", False, "sum"),
    ],
    "FactResena": [
        C("ResenaId", "string", oculta=True),
        C("TiempoKey", "int64", oculta=True),
        C("ClienteKey", "int64", oculta=True),
        C("HotelKey", "int64", oculta=True),
        C("TourKey", "int64", oculta=True),
        C("PaqueteKey", "int64", oculta=True),
        C("TipoEntidad", "string"),
        C("Calificacion", "int64", "0", False, "average"),
        C("EsPositiva", "int64", oculta=True, resumen="sum"),
        C("EsNegativa", "int64", oculta=True, resumen="sum"),
        C("EsVerificada", "int64", oculta=True, resumen="sum"),
        C("LongitudTexto", "int64", oculta=True, resumen="average"),
        C("Idioma", "string"),
        C("Satisfaccion", "string"),
        C("ConteoResena", "int64", oculta=True, resumen="sum"),
    ],
    "FactInteraccionWeb": [
        C("InteraccionId", "string", oculta=True),
        C("TiempoKey", "int64", oculta=True),
        C("ClienteKey", "int64", oculta=True),
        C("CanalKey", "int64", oculta=True),
        C("HotelKey", "int64", oculta=True),
        C("TourKey", "int64", oculta=True),
        C("TipoEvento", "string"),
        C("DestinoBuscado", "string"),
        C("DuracionSegundos", "int64", "#,0", False, "average"),
        C("EsConversion", "int64", oculta=True, resumen="sum"),
        C("ConteoEvento", "int64", oculta=True, resumen="sum"),
    ],
    "EstadoSistema": [
        C("NodoActual", "string"),
        C("Instancia", "string"),
        C("Edicion", "string"),
        C("BaseDatos", "string"),
        C("ModeloRecuperacion", "string"),
        C("RolMirroring", "string"),
        C("EstadoMirroring", "string"),
        C("Socio", "string"),
        C("Testigo", "string"),
        C("InicioInstancia", "dateTime", "General Date"),
        C("HorasEnLinea", "int64", "#,0"),
        C("UltimaCargaId", "int64"),
        C("UltimaCargaModo", "string"),
        C("UltimaCargaEstado", "string"),
        C("UltimaCargaInicio", "dateTime", "General Date"),
        C("UltimaCargaFin", "dateTime", "General Date"),
        C("UltimaCargaSegundos", "int64", "#,0"),
        C("UltimaCargaFilas", "int64", "#,0"),
        C("UltimaCargaRechazos", "int64", "#,0"),
        C("HorasDesdeUltimaCarga", "int64", "#,0"),
        C("FechaConsulta", "dateTime", "General Date"),
    ],
    "CalidadDatos": [
        C("EjecucionId", "int64"),
        C("Fuente", "string"),
        C("Objeto", "string"),
        C("Regla", "string"),
        C("Severidad", "string"),
        C("Registros", "int64", "#,0", False, "sum"),
        C("PrimeraDeteccion", "dateTime", "General Date"),
        C("UltimaDeteccion", "dateTime", "General Date"),
        C("EjemploDescripcion", "string"),
    ],
}

# Relaciones: (tabla_origen, columna, tabla_destino, columna, activa)
# Estrella pura: todas de muchos-a-uno, filtro en un solo sentido.
# Las relaciones de fecha inactivas son "role-playing": la misma DimTiempo
# sirve como fecha de reserva y como fecha de fin, y se activan con
# USERELATIONSHIP cuando el analisis lo pide.
RELACIONES = [
    ("FactReserva", "FechaInicioKey", "DimTiempo", "TiempoKey", True),
    ("FactReserva", "FechaReservaKey", "DimTiempo", "TiempoKey", False),
    ("FactReserva", "FechaFinKey", "DimTiempo", "TiempoKey", False),
    ("FactReserva", "ClienteKey", "DimCliente", "ClienteKey", True),
    ("FactReserva", "PaqueteKey", "DimPaquete", "PaqueteKey", True),
    ("FactReserva", "EstadoKey", "DimEstadoReserva", "EstadoKey", True),

    ("FactReservaHabitacion", "FechaInicioKey", "DimTiempo", "TiempoKey", True),
    ("FactReservaHabitacion", "ClienteKey", "DimCliente", "ClienteKey", True),
    ("FactReservaHabitacion", "HotelKey", "DimHotel", "HotelKey", True),
    ("FactReservaHabitacion", "TipoHabitacionKey", "DimTipoHabitacion", "TipoHabitacionKey", True),
    ("FactReservaHabitacion", "EstadoKey", "DimEstadoReserva", "EstadoKey", True),

    ("FactReservaTour", "FechaInicioKey", "DimTiempo", "TiempoKey", True),
    ("FactReservaTour", "ClienteKey", "DimCliente", "ClienteKey", True),
    ("FactReservaTour", "TourKey", "DimTour", "TourKey", True),
    ("FactReservaTour", "EstadoKey", "DimEstadoReserva", "EstadoKey", True),

    ("FactOcupacionDiaria", "TiempoKey", "DimTiempo", "TiempoKey", True),
    ("FactOcupacionDiaria", "HotelKey", "DimHotel", "HotelKey", True),

    ("FactResena", "TiempoKey", "DimTiempo", "TiempoKey", True),
    ("FactResena", "ClienteKey", "DimCliente", "ClienteKey", True),
    ("FactResena", "HotelKey", "DimHotel", "HotelKey", False),
    ("FactResena", "TourKey", "DimTour", "TourKey", False),
    ("FactResena", "PaqueteKey", "DimPaquete", "PaqueteKey", False),

    ("FactInteraccionWeb", "TiempoKey", "DimTiempo", "TiempoKey", True),
    ("FactInteraccionWeb", "ClienteKey", "DimCliente", "ClienteKey", True),
    ("FactInteraccionWeb", "CanalKey", "DimCanal", "CanalKey", True),

    ("DimTipoHabitacion", "HotelKey", "DimHotel", "HotelKey", True),
]

# Medidas: (nombre, expresion DAX, formato, carpeta)
MEDIDAS = [
    # --- Reservas -----------------------------------------------------
    ("Reservas", "SUM ( FactReserva[ConteoReserva] )", "#,0", "1 Reservas"),
    ("Reservas confirmadas",
     "CALCULATE ( [Reservas], DimEstadoReserva[EsConfirmada] = TRUE () )", "#,0", "1 Reservas"),
    ("Reservas canceladas",
     "CALCULATE ( [Reservas], DimEstadoReserva[EsCancelada] = TRUE () )", "#,0", "1 Reservas"),
    ("Personas atendidas", "SUM ( FactReserva[CantidadPersonas] )", "#,0", "1 Reservas"),
    ("Reservas alojamiento",
     "DISTINCTCOUNT ( FactReservaHabitacion[ReservaId] )", "#,0", "1 Reservas"),

    # --- Ingresos -----------------------------------------------------
    ("Ingresos confirmados", "SUM ( FactReserva[MontoConfirmado] )", "$#,0;-$#,0", "2 Ingresos"),
    ("Ingresos totales", "SUM ( FactReserva[MontoTotal] )", "$#,0;-$#,0", "2 Ingresos"),
    ("Ingresos por hotel",
     "SUM ( FactReservaHabitacion[IngresoAlojamiento] )", "$#,0;-$#,0", "2 Ingresos"),
    ("Ingresos por paquete",
     "CALCULATE ( [Ingresos confirmados], DimPaquete[PaqueteId] <> -1 )",
     "$#,0;-$#,0", "2 Ingresos"),
    ("Ticket promedio",
     "DIVIDE ( [Ingresos confirmados], [Reservas confirmadas] )", "$#,0.00", "2 Ingresos"),

    # --- Ocupacion ----------------------------------------------------
    ("Habitaciones ocupadas",
     "SUM ( FactOcupacionDiaria[HabitacionesOcupadas] )", "#,0", "3 Ocupacion"),
    ("Habitaciones disponibles",
     "SUM ( FactOcupacionDiaria[HabitacionesDisponibles] )", "#,0", "3 Ocupacion"),
    ("% Ocupacion hotelera",
     "DIVIDE ( [Habitaciones ocupadas], [Habitaciones disponibles] )", "0.0%", "3 Ocupacion"),
    ("% Ocupacion mes anterior",
     "CALCULATE ( [% Ocupacion hotelera], DATEADD ( DimTiempo[Fecha], -1, MONTH ) )",
     "0.0%", "3 Ocupacion"),
    ("Variacion de ocupacion",
     "[% Ocupacion hotelera] - [% Ocupacion mes anterior]", "0.0%", "3 Ocupacion"),

    # --- Estadia ------------------------------------------------------
    ("Promedio de estadia (noches)",
     "DIVIDE ( SUM ( FactReserva[Noches] ), [Reservas] )", "0.00", "4 Comportamiento"),
    ("Dias de anticipacion promedio",
     "DIVIDE ( SUM ( FactReserva[DiasAnticipacion] ), [Reservas] )", "0.00", "4 Comportamiento"),
    ("Tasa de cancelacion",
     "DIVIDE ( [Reservas canceladas], [Reservas] )", "0.0%", "4 Comportamiento"),
    ("Personas por reserva",
     "DIVIDE ( [Personas atendidas], [Reservas] )", "0.00", "4 Comportamiento"),

    # --- Temporadas y destinos ----------------------------------------
    ("Reservas en temporada alta",
     'CALCULATE ( [Reservas], DimTiempo[TipoTemporada] = "Temporada alta" )',
     "#,0", "5 Temporadas"),
    ("Reservas en temporada verde",
     'CALCULATE ( [Reservas], DimTiempo[TipoTemporada] = "Temporada verde" )',
     "#,0", "5 Temporadas"),
    ("Concentracion en temporada alta",
     "DIVIDE ( [Reservas en temporada alta], [Reservas] )", "0.0%", "5 Temporadas"),
    ("Destinos visitados", "DISTINCTCOUNT ( DimHotel[Ciudad] )", "#,0", "5 Temporadas"),

    # --- Tours --------------------------------------------------------
    ("Tours solicitados", "SUM ( FactReservaTour[ConteoTour] )", "#,0", "6 Tours"),
    ("Ingresos por tour", "SUM ( FactReservaTour[IngresoTour] )", "$#,0;-$#,0", "6 Tours"),
    ("Personas en tours", "SUM ( FactReservaTour[CantidadPersonas] )", "#,0", "6 Tours"),

    # --- Satisfaccion -------------------------------------------------
    ("Resenas", "SUM ( FactResena[ConteoResena] )", "#,0", "7 Satisfaccion"),
    ("Calificacion promedio",
     "DIVIDE ( SUMX ( FactResena, FactResena[Calificacion] ), [Resenas] )",
     "0.00", "7 Satisfaccion"),
    ("Resenas positivas", "SUM ( FactResena[EsPositiva] )", "#,0", "7 Satisfaccion"),
    ("Resenas negativas", "SUM ( FactResena[EsNegativa] )", "#,0", "7 Satisfaccion"),
    ("Indice de satisfaccion",
     "DIVIDE ( [Resenas positivas], [Resenas] )", "0.0%", "7 Satisfaccion"),
    ("NPS aproximado",
     "DIVIDE ( [Resenas positivas] - [Resenas negativas], [Resenas] )",
     "0.0%", "7 Satisfaccion"),
    ("% Resenas verificadas",
     "DIVIDE ( SUM ( FactResena[EsVerificada] ), [Resenas] )", "0.0%", "7 Satisfaccion"),

    # --- Comportamiento web -------------------------------------------
    ("Interacciones", "SUM ( FactInteraccionWeb[ConteoEvento] )", "#,0", "8 Web"),
    ("Conversiones", "SUM ( FactInteraccionWeb[EsConversion] )", "#,0", "8 Web"),
    ("Tasa de conversion web", "DIVIDE ( [Conversiones], [Interacciones] )", "0.0%", "8 Web"),
    ("Duracion media de sesion (seg)",
     "DIVIDE ( SUM ( FactInteraccionWeb[DuracionSegundos] ), [Interacciones] )",
     "#,0", "8 Web"),
    ("Busquedas",
     'CALCULATE ( [Interacciones], FactInteraccionWeb[TipoEvento] = "busqueda" )',
     "#,0", "8 Web"),
    ("Abandonos de carrito",
     'CALCULATE ( [Interacciones], FactInteraccionWeb[TipoEvento] = "abandono_carrito" )',
     "#,0", "8 Web"),

    # --- Perfil del visitante -----------------------------------------
    ("Clientes activos",
     'CALCULATE ( DISTINCTCOUNT ( DimCliente[ClienteId] ), DimCliente[Estado] = "Activo" )',
     "#,0", "9 Visitantes"),
    ("Clientes con reserva",
     "DISTINCTCOUNT ( FactReserva[ClienteKey] )", "#,0", "9 Visitantes"),
    ("Presupuesto promedio declarado",
     "AVERAGE ( DimCliente[PresupuestoEstimado] )", "$#,0.00", "9 Visitantes"),
    ("Brecha presupuesto vs gasto",
     "[Ticket promedio] - [Presupuesto promedio declarado]", "$#,0.00", "9 Visitantes"),

    # --- Comparativos temporales --------------------------------------
    ("Reservas ano anterior",
     "CALCULATE ( [Reservas], SAMEPERIODLASTYEAR ( DimTiempo[Fecha] ) )", "#,0", "A Tendencias"),
    ("Ingresos ano anterior",
     "CALCULATE ( [Ingresos confirmados], SAMEPERIODLASTYEAR ( DimTiempo[Fecha] ) )",
     "$#,0;-$#,0", "A Tendencias"),
    ("Crecimiento de ingresos YoY",
     "DIVIDE ( [Ingresos confirmados] - [Ingresos ano anterior], [Ingresos ano anterior] )",
     "0.0%", "A Tendencias"),
    ("Ingresos acumulados del ano",
     "TOTALYTD ( [Ingresos confirmados], DimTiempo[Fecha] )", "$#,0;-$#,0", "A Tendencias"),

    # --- Estado del sistema -------------------------------------------
    ("Nodo activo", "SELECTEDVALUE ( EstadoSistema[NodoActual] )", None, "B Sistema"),
    ("Estado del mirroring",
     "SELECTEDVALUE ( EstadoSistema[EstadoMirroring] )", None, "B Sistema"),
    ("Ultima carga", "SELECTEDVALUE ( EstadoSistema[UltimaCargaFin] )", None, "B Sistema"),
    ("Registros rechazados en la ultima carga",
     "SELECTEDVALUE ( EstadoSistema[UltimaCargaRechazos] )", "#,0", "B Sistema"),
    ("Semaforo de frescura",
     'VAR Horas = SELECTEDVALUE ( EstadoSistema[HorasDesdeUltimaCarga] )\n'
     'RETURN\n'
     '    SWITCH (\n'
     '        TRUE (),\n'
     '        ISBLANK ( Horas ), "Sin cargas registradas",\n'
     '        Horas <= 24, "Datos al dia",\n'
     '        Horas <= 72, "Datos con retraso",\n'
     '        "Datos desactualizados"\n'
     '    )', None, "B Sistema"),
]


# ===========================================================================
# Generacion de TMDL
# ===========================================================================
def tmdl_columna(col) -> list[str]:
    nombre, tipo, formato, oculta, resumen = col
    lineas = [f"\tcolumn '{nombre}'", f"\t\tdataType: {tipo}"]
    if formato:
        lineas.append(f"\t\tformatString: {formato}")
    if oculta:
        lineas.append("\t\tisHidden")
    lineas.append(f"\t\tsummarizeBy: {resumen}")
    lineas.append(f"\t\tsourceColumn: {nombre}")
    lineas.append("")
    lineas.append(f"\t\tannotation SummarizationSetBy = Automatic")
    lineas.append("")
    return lineas


def tmdl_tabla(nombre: str, vista: str, es_hecho: bool) -> str:
    lineas = [f"table {nombre}", ""]

    # Las tablas de hechos se ocultan del panel de campos: el usuario del
    # reporte debe usar medidas, no arrastrar columnas numericas sueltas.
    if es_hecho:
        lineas += ["\tisHidden", ""]

    if nombre == "DimTiempo":
        # Marcar como tabla de fechas es obligatorio para que las funciones
        # de inteligencia de tiempo (SAMEPERIODLASTYEAR, TOTALYTD) den
        # resultados correctos en lugar de numeros silenciosamente mal.
        lineas += ["\tdataCategory: Time", ""]

    for col in COLUMNAS.get(nombre, []):
        lineas += tmdl_columna(col)

    if nombre == "DimTiempo":
        lineas += [
            "\thierarchy 'Calendario'",
            "\t\tlevel Anio",
            "\t\t\tcolumn: Anio",
            "\t\tlevel Trimestre",
            "\t\t\tcolumn: NombreTrimestre",
            "\t\tlevel Mes",
            "\t\t\tcolumn: NombreMes",
            "\t\tlevel Dia",
            "\t\t\tcolumn: DiaDelMes",
            "",
        ]
    if nombre == "DimHotel":
        lineas += [
            "\thierarchy 'Geografia'",
            "\t\tlevel Pais",
            "\t\t\tcolumn: Pais",
            "\t\tlevel Ciudad",
            "\t\t\tcolumn: Ciudad",
            "\t\tlevel Hotel",
            "\t\t\tcolumn: Nombre",
            "",
        ]

    # Particion: la consulta M que trae los datos. El origen es el ALIAS
    # TURISMODW, no un nombre de servidor fisico: tras el failover se
    # repunta el alias y este archivo no se toca.
    lineas += [
        f"\tpartition {nombre} = m",
        "\t\tmode: import",
        "\t\tsource =",
        "\t\t\t\tlet",
        f'\t\t\t\t    Origen = Sql.Database("{config.SQL_SERVIDOR}", "{config.SQL_BASE}"),',
        f'\t\t\t\t    Datos = Origen{{[Schema="dw",Item="{vista}"]}}[Data]',
        "\t\t\t\tin",
        "\t\t\t\t    Datos",
        "",
        "\tannotation PBI_ResultType = Table",
        "",
    ]
    return "\n".join(lineas)


def tmdl_medidas() -> str:
    lineas = ["table _Medidas", "", "\tlineageTag: " + str(uuid.uuid4()), ""]

    # Columna tecnica obligatoria: una tabla no puede estar vacia. Se oculta.
    lineas += [
        "\tcolumn Marcador",
        "\t\tdataType: string",
        "\t\tisHidden",
        "\t\tsummarizeBy: none",
        "\t\tsourceColumn: Marcador",
        "",
    ]

    for nombre, expresion, formato, carpeta in MEDIDAS:
        lineas.append(f"\tmeasure '{nombre}' =")
        for linea in expresion.split("\n"):
            lineas.append(f"\t\t\t{linea}")
        if formato:
            lineas.append(f"\t\tformatString: {formato}")
        lineas.append(f"\t\tdisplayFolder: {carpeta}")
        lineas.append(f"\t\tlineageTag: {uuid.uuid4()}")
        lineas.append("")

    lineas += [
        "\tpartition _Medidas = m",
        "\t\tmode: import",
        "\t\tsource =",
        "\t\t\t\tlet",
        '\t\t\t\t    Origen = #table({"Marcador"}, {{"x"}})',
        "\t\t\t\tin",
        "\t\t\t\t    Origen",
        "",
    ]
    return "\n".join(lineas)


def tmdl_relaciones() -> str:
    lineas = []
    for i, (t1, c1, t2, c2, activa) in enumerate(RELACIONES, start=1):
        lineas.append(f"relationship rel_{i:02d}_{t1}_{t2}_{c1}")
        if not activa:
            lineas.append("\tisActive: false")
        lineas.append(f"\tfromColumn: {t1}.{c1}")
        lineas.append(f"\ttoColumn: {t2}.{c2}")
        lineas.append("")
    return "\n".join(lineas)


def tmdl_modelo() -> str:
    referencias = "\n".join(
        [f"ref table {n}" for n, _, _ in TABLAS] + ["ref table _Medidas"]
    )
    return f"""model Model
\tculture: es-CR
\tdefaultPowerBIDataSourceVersion: powerBI_V3
\tsourceQueryCulture: es-CR
\tdataAccessOptions
\t\tlegacyRedirects
\t\treturnErrorValuesAsNull

annotation PBI_QueryOrder = {json.dumps([n for n, _, _ in TABLAS] + ["_Medidas"])}

annotation __PBI_TimeIntelligenceEnabled = 0

{referencias}
"""


# ===========================================================================
# Escritura
# ===========================================================================
def escribir(ruta: Path, contenido: str) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_text(contenido, encoding="utf-8")


def plataforma(nombre: str, tipo: str) -> str:
    return json.dumps(
        {
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
            "metadata": {"type": tipo, "displayName": nombre},
            "config": {"version": "2.0", "logicalId": str(uuid.uuid4())},
        },
        indent=2,
    )


def generar() -> None:
    print("Generando proyecto PBIP...")

    for d in (DIR_MODELO, DIR_REPORTE):
        if d.exists():
            shutil.rmtree(d)

    # --- archivo raiz .pbip -------------------------------------------
    escribir(
        RAIZ / f"{NOMBRE}.pbip",
        json.dumps(
            {
                "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/pbip/definitionProperties/1.0.0/schema.json",
                "version": "1.0",
                "artifacts": [{"report": {"path": f"{NOMBRE}.Report"}}],
                "settings": {"enableAutoRecovery": True},
            },
            indent=2,
        ),
    )

    # --- modelo semantico ---------------------------------------------
    escribir(DIR_MODELO / ".platform", plataforma(NOMBRE, "SemanticModel"))
    escribir(
        DIR_MODELO / "definition.pbism",
        json.dumps(
            {
                "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json",
                "version": "4.2",
                "settings": {},
            },
            indent=2,
        ),
    )
    escribir(
        DIR_MODELO / "definition" / "database.tmdl",
        "database\n\tcompatibilityLevel: 1567\n",
    )
    escribir(DIR_MODELO / "definition" / "model.tmdl", tmdl_modelo())
    escribir(DIR_MODELO / "definition" / "relationships.tmdl", tmdl_relaciones())

    for nombre, vista, es_hecho in TABLAS:
        escribir(
            DIR_MODELO / "definition" / "tables" / f"{nombre}.tmdl",
            tmdl_tabla(nombre, vista, es_hecho),
        )
        print(f"  tabla  {nombre:<24} <- dw.{vista}")

    escribir(DIR_MODELO / "definition" / "tables" / "_Medidas.tmdl", tmdl_medidas())
    print(f"  tabla  {'_Medidas':<24} <- {len(MEDIDAS)} medidas DAX")

    # --- reporte -------------------------------------------------------
    escribir(DIR_REPORTE / ".platform", plataforma(NOMBRE, "Report"))
    escribir(
        DIR_REPORTE / "definition.pbir",
        json.dumps(
            {
                "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/1.0.0/schema.json",
                "version": "4.0",
                "datasetReference": {
                    "byPath": {"path": f"../{NOMBRE}.SemanticModel"}
                },
            },
            indent=2,
        ),
    )
    # El lienzo se deja vacio a proposito: los visuales se arman en Power BI
    # Desktop siguiendo 00-docs/04-guia-powerbi.md. Generar JSON de visuales
    # a mano es fragil entre versiones y no aporta al entregable.
    escribir(
        DIR_REPORTE / "report.json",
        json.dumps(
            {
                "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/1.0.0/schema.json",
                "themeCollection": {"baseTheme": {"name": "CY24SU10"}},
                "layoutOptimization": "None",
                "resourcePackages": [],
            },
            indent=2,
        ),
    )

    print("")
    print(f"  Proyecto: {RAIZ / (NOMBRE + '.pbip')}")
    print(f"  Tablas  : {len(TABLAS) + 1}")
    print(f"  Medidas : {len(MEDIDAS)}")
    print(f"  Relaciones: {len(RELACIONES)}")
    print("")
    print("  Abrir con Power BI Desktop y activar antes, en Opciones >")
    print("  Caracteristicas de vista previa: proyectos .pbip, formato TMDL y PBIR.")


if __name__ == "__main__":
    generar()
