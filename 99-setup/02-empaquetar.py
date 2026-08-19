"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

02-empaquetar.py
================

Empaqueta el entregable en un .zip listo para compartir con el equipo.

Que se excluye y por que
------------------------
    .env                 lleva credenciales de la maquina local. Se incluye
                         .env.example, que es la plantilla que cada quien copia.
    __pycache__, *.pyc   bytecode de Python, se regenera solo.
    *.dat, *.err         archivos intermedios del ETL, cientos de megabytes
                         que se vuelven a generar en cada corrida.
    *.bak, *.trn         respaldos de SQL Server.

El zip queda con una carpeta raiz propia, de modo que al descomprimirlo no
desparrame archivos en el directorio actual.

Uso:
    python 99-setup/02-empaquetar.py
    python 99-setup/02-empaquetar.py --destino D:\\Entregas
"""

from __future__ import annotations

import argparse
import fnmatch
import zipfile
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
NOMBRE_BASE = "Semana3-Integrante1-AlexHerrera"

EXCLUIR_DIRS = {"__pycache__", ".git", ".idea", ".vscode", "node_modules"}
EXCLUIR_ARCHIVOS = [
    ".env",
    "*.pyc", "*.pyo",
    "*.dat", "*.err",
    "*.bak", "*.trn", "*.mdf", "*.ndf", "*.ldf",
    "*.zip",
    "Thumbs.db", "desktop.ini", ".DS_Store",
]


def excluido(ruta: Path) -> bool:
    if any(parte in EXCLUIR_DIRS for parte in ruta.parts):
        return True
    return any(fnmatch.fnmatch(ruta.name, patron) for patron in EXCLUIR_ARCHIVOS)


def main() -> int:
    p = argparse.ArgumentParser(description="Empaqueta el entregable de la Semana 3.")
    p.add_argument("--destino", default=str(RAIZ.parent),
                   help="Carpeta donde dejar el .zip (por omision, junto al proyecto).")
    args = p.parse_args()

    destino = Path(args.destino)
    destino.mkdir(parents=True, exist_ok=True)
    salida = destino / f"{NOMBRE_BASE}.zip"

    incluidos, omitidos, bytes_totales = 0, 0, 0

    with zipfile.ZipFile(salida, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for ruta in sorted(RAIZ.rglob("*")):
            if not ruta.is_file():
                continue
            relativa = ruta.relative_to(RAIZ)
            if excluido(relativa):
                omitidos += 1
                continue
            z.write(ruta, Path(NOMBRE_BASE) / relativa)
            incluidos += 1
            bytes_totales += ruta.stat().st_size

    comprimido = salida.stat().st_size

    print(f"  Archivo   : {salida}")
    print(f"  Incluidos : {incluidos} archivos ({bytes_totales / 1024 / 1024:.1f} MB)")
    print(f"  Omitidos  : {omitidos}")
    print(f"  Tamano    : {comprimido / 1024 / 1024:.2f} MB "
          f"({100 * comprimido / max(bytes_totales, 1):.0f} % del original)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
