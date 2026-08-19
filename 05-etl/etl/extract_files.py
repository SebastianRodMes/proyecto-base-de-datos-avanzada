"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Extraccion de las fuentes basadas en archivos:

    RF-10  archivos JSON con preferencias de visitantes
    RF-11  documentos XML con paquetes turisticos

Ambos formatos se aplanan a filas y se conserva el registro original
completo en la columna payload_original. Esa copia es lo que permite que
etl.Error muestre el dato tal como venia cuando la validacion lo rechaza:
sin ella, la bitacora diria "presupuesto invalido" sin poder mostrar cual.

El XML se recorre con iterparse y se liberan los elementos ya procesados.
Con documentos pequenos como los de este proyecto daria igual, pero es el
patron correcto para un catalogo de mayorista de varios cientos de MB, que
es el caso real que el escenario describe.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from lxml import etree

from . import config
from .comun import escribir_lote, formato_duracion, formato_filas, log, ruta_trabajo


# ---------------------------------------------------------------------------
# RF-10 : preferencias en JSON
# ---------------------------------------------------------------------------
def _leer_preferencias(ejecucion_id: int, destino: Path) -> tuple[int, list[str]]:
    """Orden de columnas (igual que stg.PreferenciaArchivo):
        archivo_origen, numero_registro, identificacion, correo,
        destinos_preferidos, tipo_alojamiento, presupuesto_estimado,
        temporada_viaje, idioma, grupo_viaje, payload_original, EjecucionId
    """
    archivos = sorted(config.DIR_ARCHIVOS_ENTRADA.glob("preferencias_*.json"))
    procesados: list[str] = []

    def filas():
        for ruta in archivos:
            contenido = json.loads(ruta.read_text(encoding="utf-8"))
            registros = contenido.get("preferencias", [])
            procesados.append(f"{ruta.name} ({len(registros)})")

            for n, reg in enumerate(registros, start=1):
                pref = reg.get("preferencias") or {}
                perfil = reg.get("perfil") or {}
                yield (
                    ruta.name,
                    reg.get("numero_registro", n),
                    reg.get("identificacion"),
                    reg.get("correo"),
                    pref.get("destinos_preferidos"),
                    pref.get("tipo_alojamiento"),
                    pref.get("presupuesto_estimado"),
                    pref.get("temporada_viaje"),
                    perfil.get("idioma"),
                    perfil.get("grupo_viaje"),
                    json.dumps(reg, ensure_ascii=False),
                    ejecucion_id,
                )

    with open(destino, "w", encoding="utf-8", newline="") as fh:
        total = escribir_lote(fh, filas())

    return total, procesados


# ---------------------------------------------------------------------------
# RF-11 : paquetes en XML
# ---------------------------------------------------------------------------
def _texto(elemento, ruta: str) -> str | None:
    hijo = elemento.find(ruta)
    return hijo.text if hijo is not None else None


def _leer_paquetes(ejecucion_id: int, destino: Path) -> tuple[int, list[str]]:
    """Orden de columnas (igual que stg.PaqueteArchivo):
        archivo_origen, numero_registro, codigo_paquete, nombre, destino, pais,
        duracion_dias, precio_total, moneda, actividades, servicios_adicionales,
        temporada, payload_original, EjecucionId
    """
    archivos = sorted(config.DIR_ARCHIVOS_ENTRADA.glob("paquetes_*.xml"))
    procesados: list[str] = []

    def filas():
        for ruta in archivos:
            n_archivo = 0
            contexto = etree.iterparse(str(ruta), events=("end",), tag="Paquete")

            for _, elem in contexto:
                n_archivo += 1

                precio_elem = elem.find("PrecioTotal")
                moneda = precio_elem.get("moneda") if precio_elem is not None else None
                precio = precio_elem.text if precio_elem is not None else None

                actividades = [
                    a.text for a in elem.findall("Actividades/Actividad") if a.text
                ]

                yield (
                    ruta.name,
                    elem.get("numeroRegistro") or n_archivo,
                    elem.get("codigo"),
                    _texto(elem, "Nombre"),
                    _texto(elem, "Destino/Ciudad"),
                    _texto(elem, "Destino/Pais"),
                    _texto(elem, "DuracionDias"),
                    precio,
                    moneda,
                    ", ".join(actividades),
                    _texto(elem, "ServiciosAdicionales"),
                    _texto(elem, "Temporada"),
                    etree.tostring(elem, encoding="unicode").strip(),
                    ejecucion_id,
                )

                # Se libera el nodo y sus hermanos ya leidos: mantiene el uso
                # de memoria constante sin importar el tamano del documento.
                elem.clear()
                while elem.getprevious() is not None:
                    del elem.getparent()[0]

            procesados.append(f"{ruta.name} ({n_archivo})")

    with open(destino, "w", encoding="utf-8", newline="") as fh:
        total = escribir_lote(fh, filas())

    return total, procesados


# ---------------------------------------------------------------------------
def extraer_todo(ejecucion_id: int) -> list[tuple[str, Path, int, float]]:
    """Devuelve (tabla_staging, ruta, filas, segundos) por tipo de archivo."""
    resultados = []

    if not config.DIR_ARCHIVOS_ENTRADA.is_dir():
        log(f"  No existe {config.DIR_ARCHIVOS_ENTRADA}; se omiten JSON y XML.", "AVISO")
        return resultados

    for tabla, archivo, funcion in (
        ("stg.PreferenciaArchivo", "preferencia_archivo.dat", _leer_preferencias),
        ("stg.PaqueteArchivo", "paquete_archivo.dat", _leer_paquetes),
    ):
        inicio = time.time()
        ruta = ruta_trabajo(archivo)
        filas, detalle = funcion(ejecucion_id, ruta)
        transcurrido = time.time() - inicio

        if filas == 0:
            log(f"  {tabla:<26} sin archivos de entrada", "AVISO")
            continue

        log(
            f"  {tabla:<26} {formato_filas(filas):>12} filas  "
            f"{formato_duracion(transcurrido):>8}  [{'; '.join(detalle)}]"
        )
        resultados.append((tabla, ruta, filas, transcurrido))

    return resultados
