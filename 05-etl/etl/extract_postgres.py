"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Extraccion desde PostgreSQL (base operacional 'turismo') hacia archivos
planos que despues carga bcp.

Por que pasar por archivo en lugar de INSERT directo
----------------------------------------------------
La tabla reserva tiene 2 millones de filas. Un INSERT por fila desde Python
tardaria mas de una hora; incluso con executemany por lotes, cada fila viaja
como parametro por la red ODBC. bcp usa la ruta de carga masiva del motor,
que salta el procesamiento fila a fila y registra minimamente en el log.
El costo es un archivo temporal en disco, que es barato.

La lectura usa cursor del lado del servidor (named cursor de psycopg2): sin
el, psycopg2 traeria los 2 millones de filas a memoria de Python de golpe.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

import psycopg2
import psycopg2.extras

from . import config
from .comun import escribir_lote, formato_duracion, formato_filas, log, ruta_trabajo


@dataclass(frozen=True)
class Extraccion:
    """Define que se extrae y a que tabla de staging va."""
    tabla_staging: str
    archivo: str
    consulta: str


# El orden de las columnas de cada SELECT debe coincidir exactamente con el
# orden de las columnas de la tabla de staging: bcp carga por posicion, no
# por nombre. La ultima columna siempre es EjecucionId.
EXTRACCIONES: tuple[Extraccion, ...] = (
    Extraccion(
        "stg.Cliente", "cliente.dat",
        """SELECT cliente_id, identificacion, nombre, apellidos, correo, telefono,
                  pais_origen, fecha_nacimiento, activo, fecha_registro
             FROM cliente ORDER BY cliente_id""",
    ),
    Extraccion(
        "stg.PreferenciaCliente", "preferencia_cliente.dat",
        """SELECT preferencia_id, cliente_id, destinos_preferidos, tipo_alojamiento,
                  actividades_favoritas, presupuesto_estimado, temporada_viaje,
                  datos_adicionales, fecha_actualizacion
             FROM preferencia_cliente ORDER BY preferencia_id""",
    ),
    Extraccion(
        "stg.Hotel", "hotel.dat",
        """SELECT hotel_id, nombre, categoria, direccion, ciudad, pais, servicios,
                  capacidad_total, activo
             FROM hotel ORDER BY hotel_id""",
    ),
    Extraccion(
        "stg.TipoHabitacion", "tipo_habitacion.dat",
        """SELECT tipo_habitacion_id, hotel_id, nombre, descripcion, capacidad_personas,
                  tarifa_base, cantidad_disponible, activo
             FROM tipo_habitacion ORDER BY tipo_habitacion_id""",
    ),
    Extraccion(
        "stg.Tour", "tour.dat",
        """SELECT tour_id, nombre, destino, descripcion, fecha_inicio, fecha_fin,
                  duracion_horas, cupo_maximo, precio, proveedor, activo
             FROM tour ORDER BY tour_id""",
    ),
    Extraccion(
        "stg.PaqueteTuristico", "paquete_turistico.dat",
        """SELECT paquete_id, nombre, descripcion, fecha_inicio, fecha_fin,
                  duracion_dias, precio_total, servicios_adicionales, activo
             FROM paquete_turistico ORDER BY paquete_id""",
    ),
    Extraccion(
        "stg.PaqueteHotel", "paquete_hotel.dat",
        """SELECT paquete_hotel_id, paquete_id, hotel_id, noches_incluidas
             FROM paquete_hotel ORDER BY paquete_hotel_id""",
    ),
    Extraccion(
        "stg.PaqueteTour", "paquete_tour.dat",
        """SELECT paquete_tour_id, paquete_id, tour_id
             FROM paquete_tour ORDER BY paquete_tour_id""",
    ),
    Extraccion(
        "stg.Reserva", "reserva.dat",
        """SELECT reserva_id, cliente_id, paquete_id, fecha_reserva, fecha_inicio,
                  fecha_fin, cantidad_personas, estado, monto_total,
                  motivo_cancelacion, fecha_actualizacion
             FROM reserva ORDER BY reserva_id""",
    ),
    Extraccion(
        "stg.ReservaHabitacion", "reserva_habitacion.dat",
        """SELECT reserva_habitacion_id, reserva_id, tipo_habitacion_id,
                  cantidad_habitaciones, tarifa_aplicada
             FROM reserva_habitacion ORDER BY reserva_habitacion_id""",
    ),
    Extraccion(
        "stg.ReservaTour", "reserva_tour.dat",
        """SELECT reserva_tour_id, reserva_id, tour_id, cantidad_personas,
                  precio_aplicado
             FROM reserva_tour ORDER BY reserva_tour_id""",
    ),
)


def _conectar():
    return psycopg2.connect(**config.PG)


def contar_origen() -> dict[str, int]:
    """Conteos por tabla del origen. Son la referencia contra la que se
    reconcilia el DW en 46-validacion-consistencia.sql."""
    tablas = [
        "cliente", "preferencia_cliente", "hotel", "tipo_habitacion", "tour",
        "paquete_turistico", "paquete_hotel", "paquete_tour", "reserva",
        "reserva_habitacion", "reserva_tour",
    ]
    conteos: dict[str, int] = {}
    with _conectar() as cn, cn.cursor() as cur:
        for t in tablas:
            cur.execute(f"SELECT COUNT(*) FROM {t}")
            conteos[t] = cur.fetchone()[0]
    return conteos


def extraer_todo(ejecucion_id: int) -> list[tuple[Extraccion, Path, int, float]]:
    """Vuelca cada tabla del origen a un archivo plano.

    Devuelve (definicion, ruta, filas, segundos) por extraccion, para que el
    orquestador lo registre en etl.Etapa.
    """
    resultados = []

    with _conectar() as cn:
        for ext in EXTRACCIONES:
            inicio = time.time()
            destino = ruta_trabajo(ext.archivo)

            # Cursor con nombre => cursor del lado del servidor: PostgreSQL
            # entrega de a PG_TAMANO_LOTE filas en lugar de materializar todo.
            nombre_cursor = f"cur_{ext.archivo.replace('.', '_')}"
            with cn.cursor(name=nombre_cursor) as cur:
                cur.itersize = config.PG_TAMANO_LOTE
                cur.execute(ext.consulta)

                filas = 0
                with open(destino, "w", encoding="utf-8", newline="") as fh:
                    while True:
                        lote = cur.fetchmany(config.PG_TAMANO_LOTE)
                        if not lote:
                            break
                        # Se agrega EjecucionId como ultima columna de cada fila.
                        filas += escribir_lote(
                            fh, (tuple(f) + (ejecucion_id,) for f in lote)
                        )

            transcurrido = time.time() - inicio
            mb = destino.stat().st_size / 1024 / 1024
            log(
                f"  {ext.tabla_staging:<26} {formato_filas(filas):>12} filas  "
                f"{mb:7.1f} MB  {formato_duracion(transcurrido)}"
            )
            resultados.append((ext, destino, filas, transcurrido))

    return resultados
