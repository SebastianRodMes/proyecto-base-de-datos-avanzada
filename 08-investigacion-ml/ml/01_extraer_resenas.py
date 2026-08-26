"""Paso 1 - Extraccion.

Lee las resenas desde MongoDB Atlas (turismo_nosql.resenas) y las guarda en un
CSV local para entrenar sin depender de la red. Solo trae los campos utiles y
descarta datos personales (cliente_id no se usa como feature).
"""
import csv
import sys
from datetime import datetime

from pymongo import MongoClient

import config

CAMPOS = {
    "_id": 0,
    "titulo": 1,
    "comentario": 1,
    "calificacion": 1,
    "idioma": 1,
    "verificada": 1,
    "tipo_entidad": 1,
    "origen_canal": 1,
    "util_votos": 1,
    "etiquetas": 1,
}


def main() -> int:
    config.DIR_DATA.mkdir(parents=True, exist_ok=True)
    uri = config.leer_atlas_uri()

    print("Conectando a Atlas...", flush=True)
    cli = MongoClient(uri, serverSelectionTimeoutMS=10000)
    cli.admin.command("ping")
    col = cli[config.ATLAS_DB][config.ATLAS_COL_RESENAS]
    total = col.estimated_document_count()
    print(f"Colección {config.ATLAS_DB}.{config.ATLAS_COL_RESENAS}: {total:,} documentos")

    columnas = [
        "calificacion", "titulo", "comentario", "idioma",
        "verificada", "tipo_entidad", "origen_canal", "util_votos", "n_etiquetas",
    ]
    escritas = 0
    sin_texto = 0
    inicio = datetime.now()

    with open(config.ARCHIVO_DATASET, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=columnas)
        w.writeheader()
        for d in col.find({}, CAMPOS, batch_size=2000):
            comentario = (d.get("comentario") or "").strip()
            titulo = (d.get("titulo") or "").strip()
            if not comentario and not titulo:
                sin_texto += 1
                continue
            w.writerow({
                "calificacion": d.get("calificacion"),
                "titulo": titulo,
                "comentario": comentario,
                "idioma": d.get("idioma"),
                "verificada": int(bool(d.get("verificada"))),
                "tipo_entidad": d.get("tipo_entidad"),
                "origen_canal": d.get("origen_canal"),
                "util_votos": d.get("util_votos") or 0,
                "n_etiquetas": len(d.get("etiquetas") or []),
            })
            escritas += 1
            if escritas % 50000 == 0:
                print(f"  {escritas:,} escritas...", flush=True)

    seg = (datetime.now() - inicio).total_seconds()
    print(f"\nListo: {escritas:,} filas -> {config.ARCHIVO_DATASET}")
    print(f"Descartadas sin texto: {sin_texto:,}")
    print(f"Tiempo: {seg:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
