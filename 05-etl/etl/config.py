"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Configuracion central del ETL.

Unica fuente de verdad de las cadenas de conexion y las rutas. Los valores
se leen del archivo .env que esta junto a este paquete; si una variable no
esta definida se usa el valor por defecto del laboratorio, de modo que el
ETL corre sin configuracion previa en la maquina de clase.

No se usa python-dotenv a proposito: el cargador son veinte lineas y evita
sumar una dependencia que habria que instalar en cada maquina del equipo.
"""

from __future__ import annotations

import os
from pathlib import Path

# ---------------------------------------------------------------------------
# Rutas del proyecto
# ---------------------------------------------------------------------------
# config.py vive en <proyecto>/05-etl/etl/, asi que la raiz esta dos niveles arriba.
DIR_PAQUETE = Path(__file__).resolve().parent
DIR_ETL = DIR_PAQUETE.parent
RAIZ_PROYECTO = DIR_ETL.parent

DIR_ARCHIVOS_ENTRADA = RAIZ_PROYECTO / "03-archivos" / "entrada"
DIR_SQL = RAIZ_PROYECTO / "04-sqlserver"
DIR_EVIDENCIAS = RAIZ_PROYECTO / "00-docs" / "05-evidencias"

# Los CSV intermedios que consume bcp. Van fuera del arbol del proyecto para
# no ensuciar el entregable con archivos de varios cientos de megabytes.
DIR_TRABAJO = Path(os.environ.get("TURISMO_DIR_TRABAJO", r"D:\DB\mssql\TurismoDW\etl"))


# ---------------------------------------------------------------------------
# Cargador de .env
# ---------------------------------------------------------------------------
def _cargar_env(ruta: Path) -> None:
    """Vuelca las variables de un archivo .env en os.environ.

    Las variables que ya existen en el entorno tienen prioridad: permite
    sobrescribir un valor puntual desde la linea de comandos sin editar
    el archivo.
    """
    if not ruta.is_file():
        return
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, _, valor = linea.partition("=")
        clave = clave.strip()
        valor = valor.strip().strip('"').strip("'")
        os.environ.setdefault(clave, valor)


_cargar_env(DIR_ETL / ".env")


def _env(clave: str, defecto: str) -> str:
    return os.environ.get(clave, defecto)


def _env_int(clave: str, defecto: int) -> int:
    try:
        return int(os.environ.get(clave, defecto))
    except ValueError:
        return defecto


# ---------------------------------------------------------------------------
# Origen 1: PostgreSQL (base operacional)
# ---------------------------------------------------------------------------
PG = {
    "host": _env("PG_HOST", "127.0.0.1"),
    "port": _env_int("PG_PORT", 5433),
    "dbname": _env("PG_DB", "turismo"),
    "user": _env("PG_USER", "postgres"),
    "password": _env("PG_PASSWORD", "postgres"),
}

# Filas por lote al leer con cursor del lado del servidor. 100 000 mantiene
# el uso de memoria de Python acotado con tablas de millones de filas.
PG_TAMANO_LOTE = _env_int("PG_TAMANO_LOTE", 100_000)


# ---------------------------------------------------------------------------
# Origen 2: MongoDB (datos no estructurados)
# ---------------------------------------------------------------------------
MONGO_URI = _env("MONGO_URI", "mongodb://127.0.0.1:27017/")
MONGO_DB = _env("MONGO_DB", "turismo_nosql")
MONGO_TAMANO_LOTE = _env_int("MONGO_TAMANO_LOTE", 50_000)

COLECCION_RESENAS = "resenas"
COLECCION_INTERACCIONES = "interacciones_web"


# ---------------------------------------------------------------------------
# Destino: SQL Server (base analitica)
# ---------------------------------------------------------------------------
# TURISMODW es el alias de cliente SQL, no el nombre fisico del servidor.
# Tras el failover del Integrante 3 se repunta el alias y ni el ETL ni el
# reporte de Power BI necesitan cambiar.
SQL_SERVIDOR = _env("SQL_SERVIDOR", "TURISMODW")
SQL_BASE = _env("SQL_BASE", "TurismoDW")
SQL_DRIVER = _env("SQL_DRIVER", "ODBC Driver 17 for SQL Server")

# Autenticacion integrada de Windows por defecto; si se define SQL_USUARIO
# se cambia a autenticacion de SQL Server.
SQL_USUARIO = _env("SQL_USUARIO", "")
SQL_PASSWORD = _env("SQL_PASSWORD", "")

# Filas por lote de commit en bcp. 50 000 equilibra velocidad de carga
# contra crecimiento del log de transacciones.
BCP_TAMANO_LOTE = _env_int("BCP_TAMANO_LOTE", 50_000)

# Delimitadores de los archivos intermedios.
#
# Campo: "|~|" en lugar de coma o pipe simple, porque los nombres de hotel
# llevan comas y las listas de servicios llevan pipes. Tres caracteres hacen
# la colision practicamente imposible.
#
# Fila: salto de linea, que es el terminador por omision de bcp. Se probo un
# marcador multicaracter ("|#|\n") para tolerar saltos de linea dentro de un
# campo, pero el bcp de ODBC 17 no interpreta la secuencia \n dentro de un
# terminador compuesto y falla al delimitar las filas. La alternativa es
# sanear los saltos de linea en el propio dato (ver comun.formatear), que es
# lo que se hace: ningun campo del modelo necesita conservarlos.
BCP_SEP_CAMPO = "|~|"
BCP_SEP_FILA = "\n"


def cadena_odbc(base: str | None = None) -> str:
    """Cadena de conexion ODBC hacia SQL Server."""
    destino = base or SQL_BASE
    partes = [
        f"DRIVER={{{SQL_DRIVER}}}",
        f"SERVER={SQL_SERVIDOR}",
        f"DATABASE={destino}",
        "TrustServerCertificate=yes",
    ]
    if SQL_USUARIO:
        partes += [f"UID={SQL_USUARIO}", f"PWD={SQL_PASSWORD}"]
    else:
        partes.append("Trusted_Connection=yes")
    return ";".join(partes) + ";"


def argumentos_bcp() -> list[str]:
    """Argumentos de autenticacion comunes a todas las invocaciones de bcp.

    No se pasa -u ("confiar en el certificado del servidor"): esa opcion solo
    existe en el bcp que viene con ODBC Driver 18. El instalado aqui es el de
    ODBC 17, que la rechaza con "unknown option u". ODBC 17 no fuerza cifrado
    por omision, asi que la conexion local funciona sin ella.
    """
    args = ["-S", SQL_SERVIDOR]
    if SQL_USUARIO:
        args += ["-U", SQL_USUARIO, "-P", SQL_PASSWORD]
    else:
        args.append("-T")          # autenticacion integrada de Windows
    return args


# ---------------------------------------------------------------------------
# Volumen de los generadores de datos de origen
# ---------------------------------------------------------------------------
N_RESENAS = _env_int("N_RESENAS", 500_000)
N_INTERACCIONES = _env_int("N_INTERACCIONES", 1_500_000)
N_PREFERENCIAS_JSON = _env_int("N_PREFERENCIAS_JSON", 6_000)

# Porcentaje de registros invalidos que se inyecta a proposito en los
# archivos JSON/XML. Sin ellos, la bitacora de errores del ETL quedaria
# vacia y no habria evidencia de que la validacion de RF-15 funciona.
PCT_REGISTROS_INVALIDOS = float(_env("PCT_REGISTROS_INVALIDOS", "0.02"))

# Semilla fija: los generadores producen siempre el mismo conjunto, de modo
# que los conteos de la validacion son reproducibles entre integrantes.
SEMILLA = _env_int("SEMILLA", 8218)
