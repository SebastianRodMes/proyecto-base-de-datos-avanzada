"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Utilidades compartidas por las etapas del ETL: escritura de los archivos
planos que consume bcp, formato de valores y registro en consola.
"""

from __future__ import annotations

import time
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable, Sequence

from . import config


# ---------------------------------------------------------------------------
# Consola
# ---------------------------------------------------------------------------
def log(mensaje: str, nivel: str = "INFO") -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {nivel:<5} {mensaje}", flush=True)


def log_etapa(titulo: str) -> None:
    print("", flush=True)
    log(f"--- {titulo} ---")


# ---------------------------------------------------------------------------
# Serializacion de valores hacia el archivo plano
# ---------------------------------------------------------------------------
# Se sustituyen los delimitadores si aparecieran dentro de un dato. Con
# separadores de tres caracteres es practicamente imposible, pero un solo
# caso arruinaria el alineamiento de todas las filas siguientes, asi que la
# comprobacion se hace igual.
_SEP_CAMPO = config.BCP_SEP_CAMPO


def formatear(valor: Any) -> str:
    """Convierte un valor de Python al texto que espera bcp.

    NULL se representa como cadena vacia: todas las columnas de staging son
    nvarchar y la conversion real ocurre despues con TRY_CONVERT dentro del
    motor, donde un valor no convertible se vuelve NULL en lugar de abortar
    el lote completo.
    """
    if valor is None:
        return ""
    if isinstance(valor, bool):
        return "true" if valor else "false"
    if isinstance(valor, (int, Decimal, float)):
        return str(valor)
    if isinstance(valor, datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(valor, date):
        return valor.strftime("%Y-%m-%d")
    if isinstance(valor, (dict, list)):
        import json

        valor = json.dumps(valor, ensure_ascii=False)

    texto = str(valor)

    # Un salto de linea dentro de un campo desalinearia todas las filas
    # siguientes, porque el terminador de fila de bcp es justamente el salto
    # de linea. Ningun atributo del modelo necesita conservarlos.
    if "\n" in texto or "\r" in texto:
        texto = texto.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")

    # Misma proteccion para el separador de campo. Con tres caracteres es
    # practicamente imposible que aparezca, pero un solo caso arruinaria el
    # alineamiento del resto del archivo.
    if _SEP_CAMPO in texto:
        texto = texto.replace(_SEP_CAMPO, " ")

    return texto


def escribir_lote(manejador, filas: Iterable[Sequence[Any]]) -> int:
    """Escribe filas en el archivo plano y devuelve cuantas escribio."""
    n = 0
    buffer: list[str] = []
    for fila in filas:
        buffer.append(_SEP_CAMPO.join(formatear(v) for v in fila))
        buffer.append(config.BCP_SEP_FILA)
        n += 1
        # Volcado cada 50 000 filas para acotar la memoria del buffer.
        if n % 50_000 == 0:
            manejador.write("".join(buffer))
            buffer.clear()
    if buffer:
        manejador.write("".join(buffer))
    return n


def ruta_trabajo(nombre: str) -> Path:
    """Ruta de un archivo intermedio dentro del directorio de trabajo."""
    config.DIR_TRABAJO.mkdir(parents=True, exist_ok=True)
    return config.DIR_TRABAJO / nombre


def formato_duracion(segundos: float) -> str:
    if segundos < 60:
        return f"{segundos:.1f}s"
    m, s = divmod(int(segundos), 60)
    return f"{m}m {s:02d}s"


def formato_filas(n: int) -> str:
    return f"{n:,}".replace(",", " ")
