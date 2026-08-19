"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

30-gen_json_xml.py
==================

Genera las dos fuentes basadas en archivos que exige el escenario:

    RF-10  archivos JSON con preferencias semiestructuradas de visitantes
    RF-11  documentos XML con informacion de paquetes turisticos

Salida en 03-archivos/entrada/:

    preferencias_lote1.json .. lote3.json
    paquetes_2025.xml, paquetes_2026.xml

Registros invalidos a proposito
-------------------------------
Un 2 % de los registros (configurable con PCT_REGISTROS_INVALIDOS) se emite
deliberadamente mal formado: identificacion vacia, correo sin dominio,
presupuesto negativo o precio no numerico.

No es un descuido. RF-15 pide que el ETL valide, normalice y detecte
duplicados, y RNF-05 pide trazabilidad de errores. Si todos los archivos
fueran perfectos, etl.Error quedaria vacio y no habria forma de demostrar
que la validacion funciona. Estos registros son la evidencia.

Uso
---
    python 30-gen_json_xml.py
    python 30-gen_json_xml.py --preferencias 500      # version reducida
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "05-etl"))

import psycopg2                       # noqa: E402

from etl import config                # noqa: E402


DESTINOS_PREFERIDOS = [
    "Playa, Volcanes", "Ciudades historicas", "Aventura, Selva", "Playa, Relax",
    "Naturaleza", "Montana, Cafe", "Islas, Buceo", "Cultura, Gastronomia",
]
ALOJAMIENTOS = [
    "Hotel 3 estrellas", "Hotel 4 estrellas", "Hotel 5 estrellas", "Boutique",
    "Ecolodge", "Resort todo incluido", "Cabana", "Hostal",
]
TEMPORADAS = ["Alta", "Verde", "Seca", "Media"]
IDIOMAS = ["es", "es", "en", "de", "fr", "pt"]
GRUPOS = ["solo", "pareja", "familia", "amigos"]
ACTIVIDADES = [
    "Canopy", "Rafting", "Buceo", "Senderismo", "Avistamiento de aves",
    "Tour de cafe", "Kayak", "Snorkel", "Cabalgata", "Gastronomia",
]
SERVICIOS = [
    "Traslados, Desayunos, Guia", "Traslados, Media pension",
    "Vuelos, Todo incluido", "Traslados, Pension completa",
    "Desayunos, Seguro de viaje",
]


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


# ---------------------------------------------------------------------------
# Datos de referencia desde PostgreSQL
# ---------------------------------------------------------------------------
def leer_referencias() -> tuple[list[tuple], list[tuple]]:
    """Clientes y paquetes reales, para que los archivos crucen con el modelo."""
    log("Leyendo referencias desde PostgreSQL...")
    with psycopg2.connect(**config.PG) as cn, cn.cursor() as cur:
        cur.execute(
            "SELECT identificacion, correo, pais_origen "
            "FROM cliente ORDER BY cliente_id"
        )
        clientes = cur.fetchall()

        cur.execute(
            "SELECT p.paquete_id, p.nombre, p.duracion_dias, p.precio_total, "
            "       COALESCE(h.ciudad,'San Jose'), COALESCE(h.pais,'Costa Rica') "
            "FROM paquete_turistico p "
            "LEFT JOIN paquete_hotel ph ON ph.paquete_id = p.paquete_id "
            "LEFT JOIN hotel h ON h.hotel_id = ph.hotel_id "
            "ORDER BY p.paquete_id"
        )
        paquetes = cur.fetchall()

    log(f"  clientes={len(clientes):,}  paquetes={len(paquetes):,}")
    if not clientes:
        raise SystemExit(
            "PostgreSQL sin datos. Ejecute antes 01-postgres/10-generador-volumen.sql"
        )
    return clientes, paquetes


# ---------------------------------------------------------------------------
# RF-10 : archivos JSON de preferencias
# ---------------------------------------------------------------------------
def generar_json(rnd: random.Random, clientes: list[tuple], total: int,
                 destino: Path, n_lotes: int = 3) -> dict:
    """Escribe las preferencias repartidas en varios lotes, como llegarian de
    un proveedor externo que envia por tandas."""
    muestra = rnd.sample(clientes, min(total, len(clientes)))
    por_lote = max(1, len(muestra) // n_lotes)
    stats = {"validos": 0, "invalidos": 0, "archivos": []}

    for lote in range(n_lotes):
        ini = lote * por_lote
        fin = len(muestra) if lote == n_lotes - 1 else ini + por_lote
        trozo = muestra[ini:fin]
        if not trozo:
            continue

        registros = []
        for n, (ident, correo, pais) in enumerate(trozo, start=1):
            invalido = rnd.random() < config.PCT_REGISTROS_INVALIDOS

            reg = {
                "numero_registro": n,
                "identificacion": ident,
                "correo": correo,
                "pais_origen": pais,
                "preferencias": {
                    "destinos_preferidos": rnd.choice(DESTINOS_PREFERIDOS),
                    "tipo_alojamiento": rnd.choice(ALOJAMIENTOS),
                    "presupuesto_estimado": round(rnd.uniform(600, 8000), 2),
                    "temporada_viaje": rnd.choice(TEMPORADAS),
                },
                "perfil": {
                    "idioma": rnd.choice(IDIOMAS),
                    "grupo_viaje": rnd.choice(GRUPOS),
                    "actividades": rnd.sample(ACTIVIDADES, rnd.randint(1, 3)),
                },
                "fecha_captura": (
                    f"202{rnd.randint(4, 6)}-{rnd.randint(1, 12):02d}-{rnd.randint(1, 28):02d}"
                ),
            }

            if invalido:
                # Una de tres averias tipicas de un proveedor externo.
                averia = rnd.choice(("sin_id", "correo_malo", "presupuesto_negativo"))
                if averia == "sin_id":
                    reg["identificacion"] = ""
                elif averia == "correo_malo":
                    reg["correo"] = correo.split("@")[0] + "@"
                else:
                    reg["preferencias"]["presupuesto_estimado"] = -abs(
                        reg["preferencias"]["presupuesto_estimado"]
                    )
                reg["_averia_inyectada"] = averia
                stats["invalidos"] += 1
            else:
                stats["validos"] += 1

            registros.append(reg)

        ruta = destino / f"preferencias_lote{lote + 1}.json"
        contenido = {
            "metadata": {
                "origen": "Portal de reservas - exportacion de preferencias",
                "version_esquema": "1.0",
                "lote": lote + 1,
                "total_registros": len(registros),
            },
            "preferencias": registros,
        }
        ruta.write_text(
            json.dumps(contenido, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        stats["archivos"].append(ruta.name)
        log(f"  {ruta.name}: {len(registros):,} registros")

    return stats


# ---------------------------------------------------------------------------
# RF-11 : documentos XML de paquetes turisticos
# ---------------------------------------------------------------------------
def generar_xml(rnd: random.Random, paquetes: list[tuple], destino: Path) -> dict:
    """Un documento por anio de vigencia, como los publicaria un mayorista."""
    stats = {"validos": 0, "invalidos": 0, "archivos": []}

    # Se reparten los paquetes entre los dos documentos.
    mitad = len(paquetes) // 2
    reparto = {2025: paquetes[:mitad], 2026: paquetes[mitad:]}

    for anio, grupo in reparto.items():
        lineas = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            f'<CatalogoPaquetes anio="{anio}" '
            f'generado="{time.strftime("%Y-%m-%d")}" version="1.0">',
        ]

        for n, (pid, nombre, dias, precio, ciudad, pais) in enumerate(grupo, start=1):
            invalido = rnd.random() < config.PCT_REGISTROS_INVALIDOS

            precio_txt = f"{float(precio):.2f}" if precio is not None else "0.00"
            if invalido:
                # Precio no numerico: el caso clasico de un XML mal exportado.
                precio_txt = rnd.choice(("N/D", "consultar", "-150.00"))
                stats["invalidos"] += 1
            else:
                stats["validos"] += 1

            actividades = rnd.sample(ACTIVIDADES, rnd.randint(2, 4))

            lineas.append(f'  <Paquete numeroRegistro="{n}" codigo="PKG-{pid}">')
            lineas.append(f"    <Nombre>{escape(nombre or '')}</Nombre>")
            lineas.append("    <Destino>")
            lineas.append(f"      <Ciudad>{escape(ciudad or '')}</Ciudad>")
            lineas.append(f"      <Pais>{escape(pais or '')}</Pais>")
            lineas.append("    </Destino>")
            lineas.append(f"    <DuracionDias>{dias if dias is not None else 0}</DuracionDias>")
            lineas.append(f'    <PrecioTotal moneda="USD">{precio_txt}</PrecioTotal>')
            lineas.append("    <Actividades>")
            for a in actividades:
                lineas.append(f"      <Actividad>{escape(a)}</Actividad>")
            lineas.append("    </Actividades>")
            lineas.append(
                f"    <ServiciosAdicionales>{escape(rnd.choice(SERVICIOS))}"
                f"</ServiciosAdicionales>"
            )
            lineas.append(f"    <Temporada>{rnd.choice(TEMPORADAS)}</Temporada>")
            lineas.append("  </Paquete>")

        lineas.append("</CatalogoPaquetes>")

        ruta = destino / f"paquetes_{anio}.xml"
        ruta.write_text("\n".join(lineas), encoding="utf-8")
        stats["archivos"].append(ruta.name)
        log(f"  {ruta.name}: {len(grupo):,} paquetes")

    return stats


# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="Genera las fuentes JSON y XML del Escenario 8.")
    p.add_argument("--preferencias", type=int, default=config.N_PREFERENCIAS_JSON)
    args = p.parse_args()

    rnd = random.Random(config.SEMILLA + 1)
    destino = config.DIR_ARCHIVOS_ENTRADA
    destino.mkdir(parents=True, exist_ok=True)

    clientes, paquetes = leer_referencias()

    log(f"Generando archivos JSON de preferencias (RF-10) en {destino}...")
    s_json = generar_json(rnd, clientes, args.preferencias, destino)

    log("Generando documentos XML de paquetes (RF-11)...")
    s_xml = generar_xml(rnd, paquetes, destino)

    log("")
    log("=== Resumen ===")
    log(f"  JSON: {s_json['validos']:,} validos / {s_json['invalidos']:,} invalidos "
        f"-> {', '.join(s_json['archivos'])}")
    log(f"  XML : {s_xml['validos']:,} validos / {s_xml['invalidos']:,} invalidos "
        f"-> {', '.join(s_xml['archivos'])}")
    log("Los registros invalidos son intencionales: alimentan etl.Error y son "
        "la evidencia de RF-15.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
