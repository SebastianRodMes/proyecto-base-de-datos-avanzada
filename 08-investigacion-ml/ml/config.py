"""Configuracion compartida del prototipo de ML.

Lee la cadena de conexion de MongoDB Atlas desde `.secrets/turismodw-cloud.env`
(la misma que usa la migracion cloud). Nunca se imprime la credencial completa.
"""
from pathlib import Path

# Raiz del repo: .../08-investigacion-ml/ml/config.py -> subir 2 niveles
RAIZ = Path(__file__).resolve().parents[2]

SECRETS_ENV = RAIZ / ".secrets" / "turismodw-cloud.env"

# Base y coleccion de origen en Atlas
ATLAS_DB = "turismo_nosql"
ATLAS_COL_RESENAS = "resenas"

# Rutas de salida del prototipo
DIR_ML = RAIZ / "08-investigacion-ml"
DIR_DATA = DIR_ML / "data"
DIR_MODELOS = DIR_ML / "modelos"
DIR_EVIDENCIAS = DIR_ML / "evidencias"

ARCHIVO_DATASET = DIR_DATA / "resenas.csv"
ARCHIVO_MODELO = DIR_MODELOS / "modelo_sentimiento.joblib"
ARCHIVO_METRICAS = DIR_EVIDENCIAS / "metricas.txt"
ARCHIVO_MATRIZ = DIR_EVIDENCIAS / "matriz-confusion.png"


def leer_atlas_uri() -> str:
    """Devuelve el ATLAS_URI del archivo de secretos, o lanza un error claro."""
    if not SECRETS_ENV.exists():
        raise FileNotFoundError(
            f"No se encontro {SECRETS_ENV}. Se necesita el archivo de secretos "
            "con la linea ATLAS_URI=... para conectarse a Atlas."
        )
    for linea in SECRETS_ENV.read_text(encoding="utf-8").splitlines():
        if linea.startswith("ATLAS_URI="):
            uri = linea.split("=", 1)[1].strip()
            if uri:
                return uri
    raise ValueError("ATLAS_URI esta vacio o ausente en el archivo de secretos.")


def etiqueta_sentimiento(calificacion: int) -> str:
    """Mapa de calificacion (1..5) a clase de sentimiento.

    Alineado con dw.FactResena: EsNegativa (<=2), EsPositiva (>=4).
    """
    if calificacion <= 2:
        return "negativa"
    if calificacion == 3:
        return "neutral"
    return "positiva"
