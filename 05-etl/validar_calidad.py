"""Validacion reproducible de calidad antes y despues del ETL.

La fase ``antes`` revisa las reglas que implementa
``etl.usp_ValidarStaging`` directamente en PostgreSQL, MongoDB y los
archivos JSON/XML. La fase ``despues`` consulta la bitacora, los rechazos,
las marcas de agua y la integridad del modelo analitico en SQL Server.

No imprime cadenas de conexion ni credenciales.
"""

from __future__ import annotations

import argparse
import json
from decimal import Decimal, InvalidOperation

import psycopg2
from lxml import etree
from pymongo import MongoClient

from etl import config
from etl import load_sqlserver as sql


def titulo(texto: str) -> None:
    print()
    print(f"=== {texto} ===")


def valor_decimal(valor: object) -> Decimal | None:
    if valor is None or isinstance(valor, bool):
        return None
    try:
        numero = Decimal(str(valor))
        return numero if numero.is_finite() else None
    except (InvalidOperation, ValueError):
        return None


def validar_postgresql() -> None:
    titulo("CALIDAD ANTES - POSTGRESQL")
    consultas = (
        ("clientes_total", "SELECT COUNT(*) FROM cliente"),
        ("clientes_identificacion_vacia", """
            SELECT COUNT(*) FROM cliente
             WHERE identificacion IS NULL OR btrim(identificacion) = ''
        """),
        ("clientes_email_invalido", """
            SELECT COUNT(*) FROM cliente
             WHERE correo IS NOT NULL
               AND (correo !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$'
                    OR correo LIKE '% %')
        """),
        ("clientes_identificacion_duplicada", """
            SELECT COUNT(*) FROM (
                SELECT identificacion FROM cliente
                 WHERE identificacion IS NOT NULL
                 GROUP BY identificacion HAVING COUNT(*) > 1
            ) d
        """),
        ("reservas_total", "SELECT COUNT(*) FROM reserva"),
        ("reservas_monto_negativo", """
            SELECT COUNT(*) FROM reserva WHERE monto_total IS NULL OR monto_total < 0
        """),
        ("reservas_rango_fechas_invalido", """
            SELECT COUNT(*) FROM reserva
             WHERE fecha_inicio IS NULL OR fecha_fin IS NULL OR fecha_fin < fecha_inicio
        """),
        ("reservas_estado_fuera_dominio", """
            SELECT COUNT(*) FROM reserva
             WHERE estado IS NULL
                OR upper(btrim(estado)) NOT IN ('CONFIRMADA','PENDIENTE','CANCELADA')
        """),
    )
    with psycopg2.connect(**config.PG) as cn, cn.cursor() as cur:
        for nombre, consulta in consultas:
            cur.execute(consulta)
            print(f"{nombre}|{cur.fetchone()[0]}")


def validar_mongodb() -> None:
    titulo("CALIDAD ANTES - MONGODB")
    cliente = MongoClient(config.MONGO_URI, serverSelectionTimeoutMS=15_000)
    try:
        db = cliente[config.MONGO_DB]
        resenas = db[config.COLECCION_RESENAS]
        interacciones = db[config.COLECCION_INTERACCIONES]
        print(f"resenas_total|{resenas.count_documents({})}")
        print(
            "resenas_calificacion_fuera_1_5|"
            + str(
                resenas.count_documents(
                    {"$or": [
                        {"calificacion": {"$exists": False}},
                        {"calificacion": {"$not": {"$gte": 1, "$lte": 5}}},
                    ]}
                )
            )
        )
        print(
            "resenas_entidad_incompleta|"
            + str(
                resenas.count_documents(
                    {"$or": [
                        {"tipo_entidad": {"$exists": False}},
                        {"entidad_id": {"$exists": False}},
                    ]}
                )
            )
        )
        print(f"interacciones_total|{interacciones.count_documents({})}")
        print(
            "interacciones_fecha_ausente|"
            + str(interacciones.count_documents({"fecha_evento": {"$exists": False}}))
        )
    finally:
        cliente.close()


def validar_archivos() -> None:
    titulo("CALIDAD ANTES - JSON Y XML")
    json_total = json_sin_id = json_presupuesto_invalido = 0
    for ruta in sorted(config.DIR_ARCHIVOS_ENTRADA.glob("preferencias_*.json")):
        contenido = json.loads(ruta.read_text(encoding="utf-8"))
        for registro in contenido.get("preferencias", []):
            json_total += 1
            if not str(registro.get("identificacion") or "").strip():
                json_sin_id += 1
            presupuesto = (registro.get("preferencias") or {}).get("presupuesto_estimado")
            if presupuesto is not None:
                numero = valor_decimal(presupuesto)
                if numero is None or numero < 0:
                    json_presupuesto_invalido += 1

    xml_total = xml_precio_invalido = 0
    for ruta in sorted(config.DIR_ARCHIVOS_ENTRADA.glob("paquetes_*.xml")):
        for _evento, elemento in etree.iterparse(str(ruta), events=("end",), tag="Paquete"):
            xml_total += 1
            numero = valor_decimal(elemento.findtext("PrecioTotal"))
            if numero is None or numero <= 0:
                xml_precio_invalido += 1
            elemento.clear()

    print(f"json_registros_total|{json_total}")
    print(f"json_identificacion_vacia|{json_sin_id}")
    print(f"json_presupuesto_invalido|{json_presupuesto_invalido}")
    print(f"xml_registros_total|{xml_total}")
    print(f"xml_precio_invalido|{xml_precio_invalido}")


def imprimir_filas(encabezados: tuple[str, ...], filas: list[tuple]) -> None:
    print("|".join(encabezados))
    for fila in filas:
        print("|".join("NULL" if valor is None else str(valor) for valor in fila))


def validar_sqlserver() -> int:
    titulo("CALIDAD DESPUES - SQL SERVER")
    objetos = sql.consultar("""
        SELECT
          Marca = CASE WHEN OBJECT_ID('etl.Marca','U') IS NOT NULL THEN 1 ELSE 0 END,
          ObtenerMarca = CASE WHEN OBJECT_ID('etl.usp_ObtenerMarca','P') IS NOT NULL THEN 1 ELSE 0 END,
          ActualizarMarca = CASE WHEN OBJECT_ID('etl.usp_ActualizarMarca','P') IS NOT NULL THEN 1 ELSE 0 END,
          CargarHechosIncremental = CASE WHEN OBJECT_ID('etl.usp_CargarHechosIncremental','P') IS NOT NULL THEN 1 ELSE 0 END,
          CargarOcupacionIncremental = CASE WHEN OBJECT_ID('etl.usp_CargarOcupacionIncremental','P') IS NOT NULL THEN 1 ELSE 0 END
    """)
    imprimir_filas(
        ("Marca", "ObtenerMarca", "ActualizarMarca", "CargarHechosIncremental", "CargarOcupacionIncremental"),
        objetos,
    )

    ejecuciones = sql.consultar("""
        SELECT TOP (2) EjecucionId, Modo, Estado, Servidor,
               RegistrosLeidos, RegistrosCargados, RegistrosRechazados,
               DuracionSegundos, FechaInicio, FechaFin
          FROM etl.Ejecucion ORDER BY EjecucionId DESC
    """)
    titulo("ULTIMAS EJECUCIONES")
    imprimir_filas(
        ("EjecucionId", "Modo", "Estado", "Servidor", "Leidos", "Cargados", "Rechazados", "Segundos", "Inicio", "Fin"),
        ejecuciones,
    )
    if not ejecuciones:
        print("RESULTADO|SIN_EJECUCIONES")
        return 1

    ejecucion_id = int(ejecuciones[0][0])
    titulo("BITACORA DE ETAPAS")
    imprimir_filas(
        ("Secuencia", "Nombre", "Fuente", "Destino", "Estado", "Filas", "Segundos"),
        sql.consultar("""
            SELECT Secuencia, Nombre, Fuente, ISNULL(ObjetoDestino,''), Estado,
                   ISNULL(Filas,0), ISNULL(DuracionSegundos,0)
              FROM etl.Etapa WHERE EjecucionId = ? ORDER BY Secuencia
        """, ejecucion_id),
    )

    titulo("RECHAZOS Y ADVERTENCIAS")
    errores = sql.consultar("""
        SELECT Fuente, ObjetoOrigen, ReglaValidacion, Severidad, COUNT_BIG(*)
          FROM etl.Error WHERE EjecucionId = ?
         GROUP BY Fuente, ObjetoOrigen, ReglaValidacion, Severidad
         ORDER BY Fuente, ObjetoOrigen, ReglaValidacion, Severidad
    """, ejecucion_id)
    imprimir_filas(("Fuente", "Objeto", "Regla", "Severidad", "Cantidad"), errores)
    if not errores:
        print("SIN_ERRORES|0")

    titulo("MARCAS DE AGUA")
    imprimir_filas(
        ("Fuente", "Objeto", "Tipo", "Valor", "FilasUltimoLote", "EjecucionId", "Actualizada"),
        sql.consultar("""
            SELECT Fuente, Objeto, TipoMarca, ValorMarca, FilasUltimoLote,
                   EjecucionId, FechaActualizacion
              FROM etl.Marca ORDER BY Fuente, Objeto
        """),
    )

    titulo("CONTEOS DEL MODELO")
    imprimir_filas(
        ("Objeto", "Filas"),
        sql.consultar("""
            SELECT Objeto, Filas FROM (
                SELECT 'dw.FactReserva' Objeto, COUNT_BIG(*) Filas FROM dw.FactReserva
                UNION ALL SELECT 'dw.FactReservaHabitacion', COUNT_BIG(*) FROM dw.FactReservaHabitacion
                UNION ALL SELECT 'dw.FactReservaTour', COUNT_BIG(*) FROM dw.FactReservaTour
                UNION ALL SELECT 'dw.FactResena', COUNT_BIG(*) FROM dw.FactResena
                UNION ALL SELECT 'dw.FactInteraccionWeb', COUNT_BIG(*) FROM dw.FactInteraccionWeb
                UNION ALL SELECT 'dw.FactOcupacionDiaria', COUNT_BIG(*) FROM dw.FactOcupacionDiaria
            ) c ORDER BY Objeto
        """),
    )

    fk_problemas = sql.consultar("""
        SELECT COUNT(*) FROM sys.foreign_keys
         WHERE parent_object_id IN (
               SELECT object_id FROM sys.tables WHERE schema_id = SCHEMA_ID('dw'))
           AND (is_disabled = 1 OR is_not_trusted = 1)
    """)[0][0]
    titulo("INTEGRIDAD POST ETL")
    print(f"foreign_keys_no_confiables_o_deshabilitadas|{fk_problemas}")

    modo, estado = str(ejecuciones[0][1]), str(ejecuciones[0][2])
    objetos_ok = all(int(valor) == 1 for valor in objetos[0])
    resultado = estado == "COMPLETADO" and modo == "INCREMENTAL" and fk_problemas == 0 and objetos_ok
    print(f"RESULTADO|{'CALIDAD_ETL_VERIFICADA' if resultado else 'REVISION_REQUERIDA'}")
    return 0 if resultado else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Valida calidad antes/despues del ETL")
    parser.add_argument("--fase", choices=("antes", "despues", "ambas"), default="ambas")
    args = parser.parse_args()

    if args.fase in ("antes", "ambas"):
        validar_postgresql()
        validar_mongodb()
        validar_archivos()
    if args.fase in ("despues", "ambas"):
        return validar_sqlserver()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
