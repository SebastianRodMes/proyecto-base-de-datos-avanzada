"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Extraccion desde MongoDB (base 'turismo_nosql') hacia archivos planos.

El reto aqui no es el volumen sino la forma: los documentos son anidados y
de esquema variable, mientras que el modelo estrella necesita filas de ancho
fijo. Este modulo aplana:

    resenas.etiquetas  ->  cadena separada por comas
    campos ausentes    ->  cadena vacia (que TRY_CONVERT vuelve NULL)
    ObjectId           ->  su representacion hexadecimal, que se conserva
                           como clave de negocio para la trazabilidad

Se usa una proyeccion explicita en el find() para no traer campos que el
modelo no necesita (comentario completo, votos de utilidad), lo que reduce
de forma notable el trafico con 2 millones de documentos.
"""

from __future__ import annotations

import time
from pathlib import Path

from pymongo import MongoClient

from . import config
from .comun import escribir_lote, formato_duracion, formato_filas, log, ruta_trabajo


def _cliente() -> MongoClient:
    return MongoClient(config.MONGO_URI)


def contar_origen() -> dict[str, int]:
    cli = _cliente()
    try:
        db = cli[config.MONGO_DB]
        return {
            config.COLECCION_RESENAS: db[config.COLECCION_RESENAS].count_documents({}),
            config.COLECCION_INTERACCIONES: db[config.COLECCION_INTERACCIONES].count_documents({}),
        }
    finally:
        cli.close()


def _extraer_resenas(db, ejecucion_id: int, destino: Path) -> int:
    """Aplana resenas al ancho de stg.Resena.

    Orden de columnas (posicional, igual que la tabla de staging):
        resena_id, cliente_id, tipo_entidad, entidad_id, calificacion, titulo,
        comentario, idioma, fecha, verificada, etiquetas, origen_canal,
        EjecucionId
    """
    proyeccion = {
        "cliente_id": 1, "tipo_entidad": 1, "entidad_id": 1, "calificacion": 1,
        "titulo": 1, "comentario": 1, "idioma": 1, "fecha": 1, "verificada": 1,
        "etiquetas": 1, "origen_canal": 1,
    }
    cursor = db[config.COLECCION_RESENAS].find({}, proyeccion).batch_size(
        config.MONGO_TAMANO_LOTE
    )

    def filas():
        for d in cursor:
            etiquetas = d.get("etiquetas") or []
            yield (
                str(d["_id"]),
                d.get("cliente_id"),
                d.get("tipo_entidad"),
                d.get("entidad_id"),
                d.get("calificacion"),
                d.get("titulo"),
                d.get("comentario"),
                d.get("idioma"),
                d.get("fecha"),
                d.get("verificada"),
                ", ".join(str(e) for e in etiquetas),
                d.get("origen_canal"),
                ejecucion_id,
            )

    with open(destino, "w", encoding="utf-8", newline="") as fh:
        return escribir_lote(fh, filas())


def _extraer_interacciones(db, ejecucion_id: int, destino: Path) -> int:
    """Aplana interacciones web al ancho de stg.InteraccionWeb.

    Orden de columnas:
        interaccion_id, cliente_id, sesion_id, tipo_evento, destino_buscado,
        entidad_tipo, entidad_id, dispositivo, canal, pais_visitante,
        fecha_evento, duracion_seg, convirtio, EjecucionId
    """
    proyeccion = {
        "cliente_id": 1, "sesion_id": 1, "tipo_evento": 1, "destino_buscado": 1,
        "entidad_tipo": 1, "entidad_id": 1, "dispositivo": 1, "canal": 1,
        "pais_visitante": 1, "fecha_evento": 1, "duracion_seg": 1, "convirtio": 1,
    }
    cursor = db[config.COLECCION_INTERACCIONES].find({}, proyeccion).batch_size(
        config.MONGO_TAMANO_LOTE
    )

    def filas():
        for d in cursor:
            yield (
                str(d["_id"]),
                d.get("cliente_id"),
                d.get("sesion_id"),
                d.get("tipo_evento"),
                d.get("destino_buscado"),
                d.get("entidad_tipo"),
                d.get("entidad_id"),
                d.get("dispositivo"),
                d.get("canal"),
                d.get("pais_visitante"),
                d.get("fecha_evento"),
                d.get("duracion_seg"),
                d.get("convirtio"),
                ejecucion_id,
            )

    with open(destino, "w", encoding="utf-8", newline="") as fh:
        return escribir_lote(fh, filas())


def extraer_todo(ejecucion_id: int) -> list[tuple[str, Path, int, float]]:
    """Devuelve (tabla_staging, ruta, filas, segundos) por coleccion."""
    resultados = []
    cli = _cliente()
    try:
        db = cli[config.MONGO_DB]

        for tabla, archivo, funcion in (
            ("stg.Resena", "resena.dat", _extraer_resenas),
            ("stg.InteraccionWeb", "interaccion_web.dat", _extraer_interacciones),
        ):
            inicio = time.time()
            destino = ruta_trabajo(archivo)
            filas = funcion(db, ejecucion_id, destino)
            transcurrido = time.time() - inicio
            mb = destino.stat().st_size / 1024 / 1024
            log(
                f"  {tabla:<26} {formato_filas(filas):>12} filas  "
                f"{mb:7.1f} MB  {formato_duracion(transcurrido)}"
            )
            resultados.append((tabla, destino, filas, transcurrido))
    finally:
        cli.close()

    return resultados
