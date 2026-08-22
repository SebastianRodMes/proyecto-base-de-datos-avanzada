"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

run_etl.py -- orquestador del proceso ETL (RF-14)
=================================================

Extrae de las cuatro fuentes del escenario, valida, transforma y carga el
modelo estrella de TurismoDW, dejando bitacora de cada etapa.

    PostgreSQL  ->  reservas, clientes, hoteles, tours, paquetes
    MongoDB     ->  resenas e interacciones web
    JSON        ->  preferencias de visitantes  (RF-10)
    XML         ->  catalogo de paquetes        (RF-11)

Flujo:

    1. EXTRAER      cada fuente a archivos planos en el directorio de trabajo
    2. CARGAR_STG   los archivos a stg.* con bcp (carga masiva)
    3. VALIDAR      RF-15: obligatorios, formatos, duplicados -> etl.Error
    4. CARGAR_DW    MERGE de dimensiones y recarga de hechos
    5. OCUPACION    deriva FactOcupacionDiaria (KPI de ocupacion hotelera)
    6. INTEGRIDAD   revalida las FK y actualiza estadisticas

Uso:
    python run_etl.py                     # carga completa
    python run_etl.py --modo INCREMENTAL  # solo lo cambiado desde la ultima corrida
    python run_etl.py --solo-mongo        # solo la parte NoSQL
    python run_etl.py --solo-archivos     # solo JSON y XML
    python run_etl.py --sin-extraer       # reutiliza los archivos ya extraidos

Carga incremental (RF de la Semana 4)
-------------------------------------
En modo INCREMENTAL cada extractor consulta etl.Marca para saber hasta
donde leyo la ultima vez y filtra por ahi:

    PostgreSQL  cliente.fecha_registro, preferencia_cliente y reserva por
                fecha_actualizacion; las lineas de reserva se cuelgan de la
                marca de reserva porque el origen no les da fecha propia
    MongoDB     resenas.fecha e interacciones_web.fecha_evento
    Archivos    fecha de modificacion del archivo

Los catalogos pequenos (hotel, tipo_habitacion, tour y los de paquetes) se
leen completos siempre: no tienen columna de fecha y entre todos no llegan
a 2 000 filas.

Los hechos se cargan con borrar-e-insertar por clave de negocio en vez de
TRUNCATE, asi que la operacion es idempotente. Las marcas solo avanzan si
la corrida termina bien.
"""

from __future__ import annotations

import argparse
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from etl import config, extract_files, extract_mongo, extract_postgres  # noqa: E402
from etl import load_sqlserver as sql                                   # noqa: E402
from etl.comun import formato_duracion, formato_filas, log, log_etapa   # noqa: E402


class Orquestador:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.ejecucion_id: int | None = None
        self.inicio = time.time()
        self.filas_leidas = 0
        self.archivos: list[tuple[str, Path, int]] = []

        self.usar_pg = not (args.solo_mongo or args.solo_archivos)
        self.usar_mongo = not (args.solo_pg or args.solo_archivos)
        self.usar_archivos = not (args.solo_pg or args.solo_mongo)

        # INCREMENTAL deja de ser una etiqueta y pasa a cambiar el camino:
        # los extractores filtran por etl.Marca y los hechos se cargan con
        # borrar-e-insertar por clave de negocio en vez de TRUNCATE.
        self.incremental = args.modo.strip().upper() == "INCREMENTAL"

    # -- utilidades de bitacora ------------------------------------------
    def _etapa(self, nombre: str, fuente: str, destino: str | None = None) -> int:
        return sql.iniciar_etapa(self.ejecucion_id, nombre, fuente, destino)

    # -- 0. verificaciones previas ---------------------------------------
    def verificar_entorno(self) -> None:
        log_etapa("Verificacion del entorno")
        try:
            info = sql.probar_conexion()
        except Exception as exc:
            log(f"No se pudo conectar a SQL Server ({config.SQL_SERVIDOR}).", "ERROR")
            log("Ejecute antes 99-setup/00-setup-admin.ps1 como Administrador.", "ERROR")
            raise SystemExit(f"  detalle: {exc}")

        log(f"  SQL Server : {info['servidor']}  [{info['edicion']}]")
        log(f"  Base       : {info['base']}  (version {info['version']})")
        log(f"  Alias      : {config.SQL_SERVIDOR}")

        faltantes = sql.consultar(
            "SELECT o.name FROM (VALUES ('usp_ValidarStaging'),('usp_CargarDimensiones'),"
            "('usp_CargarHechos'),('usp_CargarOcupacionDiaria'),('usp_VerificarIntegridad')) "
            "AS o(name) WHERE OBJECT_ID('etl.' + o.name) IS NULL"
        )
        if faltantes:
            raise SystemExit(
                "Faltan procedimientos en la base: "
                + ", ".join(f[0] for f in faltantes)
                + "\nEjecute los scripts 40..45 de 04-sqlserver antes del ETL."
            )

        if self.usar_pg:
            conteos = extract_postgres.contar_origen()
            log(f"  PostgreSQL : {formato_filas(conteos['reserva'])} reservas, "
                f"{formato_filas(conteos['cliente'])} clientes")
        if self.usar_mongo:
            conteos = extract_mongo.contar_origen()
            log(f"  MongoDB    : " + ", ".join(
                f"{formato_filas(v)} {k}" for k, v in conteos.items()))

    # -- marcas de agua ---------------------------------------------------
    def _leer_marcas(self, fuente: str, objetos: list[str]) -> dict[str, str]:
        """Marcas vigentes de una fuente. Solo se consultan en modo
        INCREMENTAL: en FULL se extrae todo y las marcas se avanzan al
        final igual, para que la siguiente incremental parta de ahi."""
        if not self.incremental:
            return {}
        marcas = {}
        for objeto in objetos:
            valor = sql.obtener_marca(fuente, objeto)
            if valor:
                marcas[objeto] = valor
        return marcas

    def _avanzar_marcas(self) -> None:
        """Avanza todas las marcas al maximo actual del origen.

        Se llama SOLO tras una corrida correcta. Si el ETL falla, las
        marcas se quedan donde estaban y el siguiente intento reprocesa el
        mismo lote: es preferible reprocesar a perder datos, y la carga
        incremental es idempotente porque borra por clave de negocio.
        """
        log_etapa("7. Avance de marcas de agua")
        etapa = self._etapa("AVANZAR_MARCAS", "INTERNO", "etl.Marca")
        total = 0
        try:
            grupos = []
            if self.usar_pg:
                grupos.append(("POSTGRESQL", extract_postgres.calcular_marcas()))
            if self.usar_mongo:
                grupos.append(("MONGODB", extract_mongo.calcular_marcas()))
            if self.usar_archivos:
                archivos = extract_files.calcular_marcas()
                grupos.append(("JSON", {"preferencias": archivos.get("preferencias")}))
                grupos.append(("XML", {"paquetes": archivos.get("paquetes")}))

            for fuente, marcas in grupos:
                for objeto, valor in marcas.items():
                    if valor is None:
                        continue
                    sql.actualizar_marca(fuente, objeto, valor,
                                         ejecucion_id=self.ejecucion_id)
                    log(f"  {fuente:<12} {objeto:<22} -> {valor}")
                    total += 1
            sql.finalizar_etapa(etapa, total)
        except Exception as exc:                      # noqa: BLE001
            sql.finalizar_etapa(etapa, total, "FALLIDO", str(exc)[:4000])
            raise

    # -- 1. extraccion ----------------------------------------------------
    def extraer(self) -> None:
        if self.args.sin_extraer:
            log_etapa("Extraccion omitida (--sin-extraer)")
            return

        if self.usar_pg:
            log_etapa("1a. Extraccion desde PostgreSQL")
            etapa = self._etapa("EXTRAER_PG", "POSTGRESQL")
            marcas = self._leer_marcas("POSTGRESQL", sorted({
                e.objeto_marca for e in extract_postgres.EXTRACCIONES if e.objeto_marca
            }))
            if marcas:
                log(f"  Marcas vigentes: {marcas}")
            total = 0
            for ext, ruta, filas, _ in extract_postgres.extraer_todo(
                    self.ejecucion_id, marcas):
                self.archivos.append((ext.tabla_staging, ruta, filas))
                total += filas
            sql.finalizar_etapa(etapa, total)
            self.filas_leidas += total
            log(f"  Total PostgreSQL: {formato_filas(total)} filas")

        if self.usar_mongo:
            log_etapa("1b. Extraccion desde MongoDB")
            etapa = self._etapa("EXTRAER_MONGO", "MONGODB")
            marcas = self._leer_marcas("MONGODB", list(extract_mongo.CAMPO_MARCA))
            if marcas:
                log(f"  Marcas vigentes: {marcas}")
            total = 0
            for tabla, ruta, filas, _ in extract_mongo.extraer_todo(
                    self.ejecucion_id, marcas):
                self.archivos.append((tabla, ruta, filas))
                total += filas
            sql.finalizar_etapa(etapa, total)
            self.filas_leidas += total
            log(f"  Total MongoDB: {formato_filas(total)} filas")

        if self.usar_archivos:
            log_etapa("1c. Extraccion de archivos JSON y XML")
            etapa = self._etapa("EXTRAER_ARCHIVOS", "JSON")
            marcas = {}
            marcas.update(self._leer_marcas("JSON", ["preferencias"]))
            marcas.update(self._leer_marcas("XML", ["paquetes"]))
            if marcas:
                log(f"  Marcas vigentes: {marcas}")
            total = 0
            for tabla, ruta, filas, _ in extract_files.extraer_todo(
                    self.ejecucion_id, marcas):
                self.archivos.append((tabla, ruta, filas))
                total += filas
            sql.finalizar_etapa(etapa, total)
            self.filas_leidas += total
            log(f"  Total archivos: {formato_filas(total)} filas")

        sql.actualizar_leidos(self.ejecucion_id, self.filas_leidas)

    # -- 2. carga a staging ----------------------------------------------
    def cargar_staging(self) -> None:
        log_etapa("2. Carga masiva a staging (bcp)")

        etapa = self._etapa("TRUNCAR_STG", "INTERNO", "stg.*")
        tablas = sql.truncar_staging()
        sql.finalizar_etapa(etapa, len(tablas))
        log(f"  {len(tablas)} tablas de staging vaciadas")

        if self.args.sin_extraer:
            # Se reconstruye la lista desde los archivos ya presentes.
            self.archivos = []
            mapa = {e.archivo: e.tabla_staging for e in extract_postgres.EXTRACCIONES}
            mapa.update({
                "resena.dat": "stg.Resena",
                "interaccion_web.dat": "stg.InteraccionWeb",
                "preferencia_archivo.dat": "stg.PreferenciaArchivo",
                "paquete_archivo.dat": "stg.PaqueteArchivo",
            })
            for archivo, tabla in mapa.items():
                ruta = config.DIR_TRABAJO / archivo
                if ruta.is_file():
                    self.archivos.append((tabla, ruta, 0))

        total = 0
        for tabla, ruta, _ in self.archivos:
            etapa = self._etapa("CARGAR_STG", "INTERNO", tabla)
            try:
                filas, _seg = sql.cargar_bcp(tabla, ruta)
                sql.finalizar_etapa(etapa, filas)
                total += filas
            except Exception as exc:
                sql.finalizar_etapa(etapa, 0, "FALLIDO", str(exc)[:4000])
                raise
        log(f"  Total cargado a staging: {formato_filas(total)} filas")

    # -- 3. validacion ----------------------------------------------------
    def validar(self) -> None:
        log_etapa("3. Validacion y limpieza (RF-15)")
        etapa = self._etapa("VALIDAR", "INTERNO", "etl.Error")
        conjuntos = sql.ejecutar_procedimiento("etl.usp_ValidarStaging", self.ejecucion_id)
        rechazos = advertencias = 0
        if conjuntos and conjuntos[-1]:
            rechazos, advertencias = conjuntos[-1][0]
        sql.finalizar_etapa(etapa, rechazos + advertencias)
        log(f"  Rechazos     : {formato_filas(rechazos)}")
        log(f"  Advertencias : {formato_filas(advertencias)}")

        detalle = sql.consultar(
            "SELECT Fuente, ReglaValidacion, Severidad, COUNT(*) "
            "FROM etl.Error WHERE EjecucionId = ? "
            "GROUP BY Fuente, ReglaValidacion, Severidad ORDER BY COUNT(*) DESC",
            self.ejecucion_id,
        )
        for fuente, regla, sev, n in detalle:
            log(f"    {fuente:<12} {regla:<22} {sev:<12} {formato_filas(n):>8}")

    # -- 4. carga al modelo estrella --------------------------------------
    def cargar_dw(self) -> None:
        log_etapa("4a. Dimensiones (MERGE, SCD tipo 1)")
        etapa = self._etapa("CARGAR_DW_DIM", "INTERNO", "dw.Dim*")
        conjuntos = sql.ejecutar_procedimiento("etl.usp_CargarDimensiones", self.ejecucion_id)
        total_dim = 0
        for conjunto in conjuntos:
            for nombre, filas in conjunto:
                log(f"  {nombre:<26} {formato_filas(filas):>12} filas")
                total_dim += filas
        sql.finalizar_etapa(etapa, total_dim)

        if self.incremental:
            log_etapa("4b. Hechos (incremental: borrar-e-insertar por clave)")
            procedimiento = "etl.usp_CargarHechosIncremental"
        else:
            log_etapa("4b. Hechos (recarga completa)")
            procedimiento = "etl.usp_CargarHechos"

        etapa = self._etapa("CARGAR_DW_HECHOS", "INTERNO", "dw.Fact*")
        conjuntos = sql.ejecutar_procedimiento(procedimiento, self.ejecucion_id)
        total_fact = 0
        for conjunto in conjuntos:
            for fila in conjunto:
                if self.incremental and len(fila) == 3:
                    nombre, reemplazadas, total_actual = fila
                    log(f"  {nombre:<26} {formato_filas(reemplazadas):>12} reemplazadas"
                        f"   (total {formato_filas(total_actual)})")
                    total_fact += reemplazadas
                else:
                    nombre, filas = fila[0], fila[1]
                    log(f"  {nombre:<26} {formato_filas(filas):>12} filas")
                    total_fact += filas
        sql.finalizar_etapa(etapa, total_fact)

    # -- 5. ocupacion diaria ----------------------------------------------
    def cargar_ocupacion(self) -> None:
        if self.incremental:
            log_etapa("5. FactOcupacionDiaria (recalculo por ambito afectado)")
            procedimiento = "etl.usp_CargarOcupacionIncremental"
        else:
            log_etapa("5. FactOcupacionDiaria (KPI de ocupacion hotelera)")
            procedimiento = "etl.usp_CargarOcupacionDiaria"

        etapa = self._etapa("CARGAR_DW_OCUPACION", "INTERNO", "dw.FactOcupacionDiaria")
        conjuntos = sql.ejecutar_procedimiento(procedimiento, self.ejecucion_id)
        filas = 0
        for conjunto in conjuntos:
            for nombre, n, promedio in conjunto:
                filas = n
                log(f"  {nombre:<26} {formato_filas(n):>12} filas")
                log(f"  Ocupacion promedio del periodo: {promedio} %")
        sql.finalizar_etapa(etapa, filas)

    # -- 6. integridad -----------------------------------------------------
    def verificar_integridad(self) -> None:
        log_etapa("6. Verificacion de integridad referencial")
        etapa = self._etapa("VERIFICAR_INTEGRIDAD", "INTERNO", "dw.*")
        conjuntos = sql.ejecutar_procedimiento(
            "etl.usp_VerificarIntegridad", self.ejecucion_id
        )
        problemas = [f for c in conjuntos for f in c]
        if problemas:
            for nombre, tabla, no_confiable, deshabilitada in problemas:
                log(f"  {tabla}.{nombre}: no_confiable={no_confiable} "
                    f"deshabilitada={deshabilitada}", "AVISO")
            sql.finalizar_etapa(etapa, len(problemas), "COMPLETADO",
                                "Hay restricciones no confiables")
        else:
            log("  Todas las claves foraneas quedaron validadas y confiables.")
            sql.finalizar_etapa(etapa, 0)

    # -- resumen -----------------------------------------------------------
    def resumen(self) -> None:
        log_etapa("Resumen de la ejecucion")
        filas = sql.consultar(
            "SELECT Modo, Estado, RegistrosLeidos, RegistrosCargados, "
            "RegistrosRechazados, DuracionSegundos "
            "FROM etl.Ejecucion WHERE EjecucionId = ?",
            self.ejecucion_id,
        )
        if filas:
            modo, estado, leidos, cargados, rechazados, segundos = filas[0]
            log(f"  Ejecucion  : {self.ejecucion_id}  ({modo})")
            log(f"  Estado     : {estado}")
            log(f"  Leidos     : {formato_filas(leidos or 0)}")
            log(f"  Cargados   : {formato_filas(cargados or 0)}")
            log(f"  Rechazados : {formato_filas(rechazados or 0)}")
            log(f"  Duracion   : {formato_duracion(segundos or 0)}")

        log("")
        log("  Etapas:")
        for nombre, destino, est, seg, n in sql.consultar(
            "SELECT Nombre, ISNULL(ObjetoDestino,''), Estado, "
            "ISNULL(DuracionSegundos,0), ISNULL(Filas,0) "
            "FROM etl.Etapa WHERE EjecucionId = ? ORDER BY Secuencia",
            self.ejecucion_id,
        ):
            log(f"    {nombre:<22} {destino:<26} {est:<12} "
                f"{float(seg):8.2f}s {formato_filas(int(n)):>12}")

    # -- ejecucion ---------------------------------------------------------
    def ejecutar(self) -> int:
        modo = self.args.modo
        self.verificar_entorno()

        self.ejecucion_id = sql.iniciar_ejecucion(modo)
        log(f"  Ejecucion ETL #{self.ejecucion_id} iniciada en modo {modo}")

        try:
            self.extraer()
            self.cargar_staging()
            self.validar()
            self.cargar_dw()
            self.cargar_ocupacion()
            self.verificar_integridad()
            self._avanzar_marcas()
            sql.finalizar_ejecucion(self.ejecucion_id)
        except Exception as exc:
            log(f"El ETL fallo: {exc}", "ERROR")
            traceback.print_exc()
            sql.finalizar_ejecucion(self.ejecucion_id, "FALLIDO", str(exc)[:4000])
            self.resumen()
            return 1

        self.resumen()
        log("")
        log(f"ETL completado en {formato_duracion(time.time() - self.inicio)}.")
        return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description="ETL del Escenario 8: PostgreSQL + MongoDB + JSON + XML -> SQL Server"
    )
    p.add_argument("--modo", default="FULL",
                   help="FULL recarga todo; INCREMENTAL filtra por etl.Marca y "
                        "carga los hechos por clave de negocio.")
    p.add_argument("--solo-pg", action="store_true", help="Solo la fuente PostgreSQL.")
    p.add_argument("--solo-mongo", action="store_true", help="Solo la fuente MongoDB.")
    p.add_argument("--solo-archivos", action="store_true", help="Solo JSON y XML.")
    p.add_argument("--sin-extraer", action="store_true",
                   help="Reutiliza los archivos ya extraidos en el directorio de trabajo.")
    args = p.parse_args()

    print("=" * 78)
    print(" ITI-821 | Escenario 8: Turismo Inteligente | ETL Semana 3")
    print(" Integrante 1: Alex Herrera")
    print("=" * 78)

    return Orquestador(args).ejecutar()


if __name__ == "__main__":
    raise SystemExit(main())
