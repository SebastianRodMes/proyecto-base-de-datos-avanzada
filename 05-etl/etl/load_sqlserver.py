"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

Carga hacia SQL Server y ejecucion de los procedimientos de transformacion.

Division de responsabilidades:
    bcp     -> mover millones de filas a las tablas de staging
    pyodbc  -> DDL, control, invocacion de procedimientos y consultas de
               verificacion

bcp se invoca como proceso externo porque es la unica via de carga masiva
disponible sin SSIS (que no viene con esta edicion) y porque usa la ruta
BULK INSERT del motor, que registra minimamente en el log de transacciones.
"""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

import pyodbc

from . import config
from .comun import formato_duracion, formato_filas, log


# ---------------------------------------------------------------------------
# Conexion
# ---------------------------------------------------------------------------
def conectar(autocommit: bool = True) -> pyodbc.Connection:
    cn = pyodbc.connect(config.cadena_odbc(), autocommit=autocommit)
    # Las cargas y los MERGE sobre millones de filas superan con holgura el
    # tiempo de espera por defecto de 30 segundos.
    cn.timeout = 0
    return cn


def probar_conexion() -> dict[str, str]:
    """Verifica la conexion y devuelve la identidad del nodo.

    Con el alias TURISMODW, el valor de 'servidor' revela a que nodo se
    resolvio realmente: es la comprobacion de que el failover funciono.
    """
    with conectar() as cn:
        fila = cn.cursor().execute(
            "SELECT @@SERVERNAME, DB_NAME(), "
            "CONVERT(varchar(60), SERVERPROPERTY('Edition')), "
            "CONVERT(varchar(30), SERVERPROPERTY('ProductVersion'))"
        ).fetchone()
    return {
        "servidor": fila[0],
        "base": fila[1],
        "edicion": fila[2],
        "version": fila[3],
    }


# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------
def truncar_staging() -> list[str]:
    """Vacia todas las tablas de stg. El staging es volatil por diseno: cada
    corrida parte de cero, de modo que una corrida fallida no contamina la
    siguiente con filas a medio cargar."""
    with conectar() as cn:
        cur = cn.cursor()
        tablas = [
            f"stg.{f[0]}"
            for f in cur.execute(
                "SELECT t.name FROM sys.tables t "
                "JOIN sys.schemas s ON s.schema_id = t.schema_id "
                "WHERE s.name = 'stg' ORDER BY t.name"
            ).fetchall()
        ]
        for t in tablas:
            cur.execute(f"TRUNCATE TABLE {t}")
    return tablas


def cargar_bcp(tabla: str, archivo: Path) -> tuple[int, float]:
    """Carga un archivo plano en una tabla de staging con bcp.

    Devuelve (filas_cargadas, segundos).
    """
    inicio = time.time()

    comando = [
        "bcp",
        f"{config.SQL_BASE}.{tabla}",
        "in", str(archivo),
        "-c",                                  # datos en modo caracter
        "-C", "65001",                         # pagina de codigos UTF-8
        "-t", config.BCP_SEP_CAMPO,            # separador de campo
        # -r debe recibir un salto de linea REAL, no la secuencia "\n".
        # Dos hallazgos verificados con este bcp (ODBC 17):
        #   * omitir -r no aplica el valor por omision cuando -t es
        #     multicaracter: la ultima columna se traga el resto del archivo;
        #   * pasar la cadena de dos caracteres \ + n tampoco se interpreta.
        # Con el caracter literal funciona.
        "-r", config.BCP_SEP_FILA,
        "-b", str(config.BCP_TAMANO_LOTE),     # commit por lote
        "-m", "10",                            # tolera hasta 10 filas malas
        "-e", str(archivo.with_suffix(".err")),  # archivo de filas rechazadas
    ] + config.argumentos_bcp()

    proc = subprocess.run(comando, capture_output=True, text=True, encoding="utf-8",
                          errors="replace")

    salida = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        raise RuntimeError(
            f"bcp fallo al cargar {tabla} (codigo {proc.returncode}).\n{salida.strip()}"
        )

    # bcp informa "N filas copiadas." / "N rows copied."
    filas = 0
    for linea in salida.splitlines():
        low = linea.lower()
        if "rows copied" in low or "filas copiadas" in low:
            token = linea.strip().split()[0].replace(",", "").replace(".", "")
            if token.isdigit():
                filas = int(token)
            break

    transcurrido = time.time() - inicio
    log(
        f"  {tabla:<26} {formato_filas(filas):>12} filas  "
        f"{formato_duracion(transcurrido):>8}"
    )
    return filas, transcurrido


# ---------------------------------------------------------------------------
# Bitacora
# ---------------------------------------------------------------------------
def iniciar_ejecucion(modo: str) -> int:
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "DECLARE @id int; EXEC etl.usp_IniciarEjecucion ?, @id OUTPUT; SELECT @id;",
            modo,
        )
        return int(cur.fetchval())


def iniciar_etapa(ejecucion_id: int, nombre: str, fuente: str,
                  destino: str | None = None) -> int:
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "DECLARE @id int; EXEC etl.usp_IniciarEtapa ?, ?, ?, ?, @id OUTPUT; SELECT @id;",
            ejecucion_id, nombre, fuente, destino,
        )
        return int(cur.fetchval())


def finalizar_etapa(etapa_id: int, filas: int | None = None,
                    estado: str = "COMPLETADO", mensaje: str | None = None) -> None:
    with conectar() as cn:
        cn.cursor().execute(
            "EXEC etl.usp_FinalizarEtapa ?, ?, ?, ?", etapa_id, filas, estado, mensaje
        )


def finalizar_ejecucion(ejecucion_id: int, estado: str | None = None,
                        mensaje: str | None = None) -> None:
    with conectar() as cn:
        cn.cursor().execute(
            "EXEC etl.usp_FinalizarEjecucion ?, ?, ?", ejecucion_id, estado, mensaje
        )


def actualizar_leidos(ejecucion_id: int, leidos: int) -> None:
    with conectar() as cn:
        cn.cursor().execute(
            "UPDATE etl.Ejecucion SET RegistrosLeidos = ? WHERE EjecucionId = ?",
            leidos, ejecucion_id,
        )


# ---------------------------------------------------------------------------
# Marcas de agua de la carga incremental (etl.Marca, ver 43b-carga-incremental)
# ---------------------------------------------------------------------------
def obtener_marca(fuente: str, objeto: str) -> str | None:
    """Hasta donde se leyo este objeto la ultima vez.

    Devuelve None cuando nunca se cargo, y entonces el extractor hace
    barrido completo: la primera corrida INCREMENTAL sobre una base recien
    migrada equivale a una FULL, que es el comportamiento correcto.

    Si la tabla no existe todavia (base creada antes de 43b) tambien se
    devuelve None, para que el ETL siga corriendo en modo completo en vez
    de abortar por un objeto de control ausente.
    """
    try:
        with conectar() as cn:
            cur = cn.cursor()
            cur.execute(
                "DECLARE @v varchar(50); "
                "EXEC etl.usp_ObtenerMarca ?, ?, @v OUTPUT; SELECT @v;",
                fuente, objeto,
            )
            while cur.description:
                fila = cur.fetchone()
                if fila and fila[0] is not None:
                    return str(fila[0])
                if not cur.nextset():
                    break
            return None
    except Exception as exc:                       # noqa: BLE001
        log(f"No se pudo leer la marca de {fuente}/{objeto}: {exc}", "AVISO")
        return None


def actualizar_marca(fuente: str, objeto: str, valor: str | None,
                     filas: int = 0, ejecucion_id: int | None = None) -> None:
    """Avanza la marca. Un valor None deja la marca donde estaba.

    Se llama solo cuando la corrida termino bien. Si el ETL falla a media
    carga la marca no se mueve y el siguiente intento reprocesa el mismo
    lote: es preferible reprocesar a perder datos, y la carga de hechos
    incremental es idempotente porque borra por clave de negocio antes de
    insertar.
    """
    try:
        with conectar() as cn:
            cn.cursor().execute(
                "EXEC etl.usp_ActualizarMarca ?, ?, ?, ?, ?",
                fuente, objeto, valor, filas, ejecucion_id,
            )
    except Exception as exc:                       # noqa: BLE001
        log(f"No se pudo actualizar la marca de {fuente}/{objeto}: {exc}", "AVISO")


# ---------------------------------------------------------------------------
# Transformacion
# ---------------------------------------------------------------------------
def ejecutar_procedimiento(nombre: str, ejecucion_id: int) -> list[list[tuple]]:
    """Invoca un procedimiento de etl y devuelve todos sus conjuntos de
    resultados, que los procedimientos usan para reportar conteos."""
    conjuntos: list[list[tuple]] = []
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(f"EXEC {nombre} ?", ejecucion_id)
        while True:
            if cur.description:
                conjuntos.append([tuple(f) for f in cur.fetchall()])
            if not cur.nextset():
                break
    return conjuntos


def ejecutar_script(ruta: Path) -> None:
    """Ejecuta un archivo .sql separando por lotes GO.

    pyodbc no entiende GO (es una instruccion de sqlcmd, no de T-SQL), asi
    que hay que partir el archivo manualmente.
    """
    texto = ruta.read_text(encoding="utf-8", errors="replace")
    lotes, actual = [], []
    for linea in texto.splitlines():
        if linea.strip().upper() == "GO":
            if actual:
                lotes.append("\n".join(actual))
                actual = []
        else:
            actual.append(linea)
    if actual:
        lotes.append("\n".join(actual))

    with conectar() as cn:
        cur = cn.cursor()
        for lote in lotes:
            if lote.strip():
                cur.execute(lote)


def consultar(sql: str, *params) -> list[tuple]:
    with conectar() as cn:
        cur = cn.cursor().execute(sql, *params)
        return [tuple(f) for f in cur.fetchall()]
