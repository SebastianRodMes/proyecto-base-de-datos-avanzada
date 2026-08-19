"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

20-seed_resenas.py
==================

Siembra la base MongoDB 'turismo_nosql' con los datos no estructurados que
el escenario asigna a este motor:

    resenas             ~  500 000 documentos   (RF-12)
    interacciones_web   ~1 500 000 documentos   (RF-13)

Por que este script existe
--------------------------
El requerimiento de la Semana 3 dice "Cargar informacion desde PostgreSQL y
MongoDB", pero MongoDB no tiene datos de turismo: las semanas 1 y 2 solo
construyeron el modelo relacional. Sin esta siembra no hay nada que
extraer y la mitad NoSQL del ETL quedaria sin evidencia.

Coherencia con el modelo relacional
-----------------------------------
Los identificadores de cliente, hotel, tour y paquete se leen de PostgreSQL,
no se inventan. Asi las claves cruzan de verdad al llegar al modelo estrella
y FactResena no queda apuntando a la fila "No aplica".

La calificacion y el texto del comentario estan correlacionados: una resena
de 5 estrellas no puede tener el texto de una de 1 estrella, porque de lo
contrario el KPI de satisfaccion no significaria nada.

Uso
---
    python 20-seed_resenas.py                 # volumen completo
    python 20-seed_resenas.py --limpiar       # borra y vuelve a sembrar
    python 20-seed_resenas.py --resenas 10000 --interacciones 20000   # prueba
"""

from __future__ import annotations

import argparse
import random
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

# El paquete de configuracion vive en 05-etl/; se agrega al path para no
# duplicar cadenas de conexion entre scripts.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "05-etl"))

import psycopg2                                    # noqa: E402
from pymongo import ASCENDING, MongoClient         # noqa: E402

from etl import config                             # noqa: E402


# ---------------------------------------------------------------------------
# Catalogos de texto
# ---------------------------------------------------------------------------

# Plantillas por nivel de calificacion. El indice es la calificacion (1..5).
COMENTARIOS = {
    5: [
        "Experiencia excelente de principio a fin, volveria sin dudarlo.",
        "Superó todas nuestras expectativas. El personal fue atentísimo.",
        "Impecable. Las instalaciones, la comida y la atención, todo de primera.",
        "El mejor viaje que hemos hecho en años. Totalmente recomendado.",
        "Una maravilla. La vista, el servicio y la organización fueron perfectos.",
    ],
    4: [
        "Muy buena experiencia, solo detalles menores por pulir.",
        "Nos gustó mucho. El desayuno podría mejorar, pero todo lo demás bien.",
        "Buena relación calidad-precio. Repetiríamos.",
        "Personal amable y lugar limpio. Falta señalización en el acceso.",
        "Cumplió con lo prometido. Recomendado para familias.",
    ],
    3: [
        "Cumple, sin más. Ni bueno ni malo.",
        "Correcto para el precio, aunque esperábamos algo mejor.",
        "La ubicación es buena pero las instalaciones están algo desgastadas.",
        "Aceptable. El servicio fue lento en horas pico.",
        "Regular. La descripción prometía más de lo que encontramos.",
    ],
    2: [
        "Bastante decepcionante para lo que costó.",
        "La habitación no estaba lista a la hora del check-in y nadie avisó.",
        "El tour se recortó sin explicación. No lo recomiendo.",
        "Limpieza deficiente y atención poco profesional.",
        "Muchos problemas de organización durante toda la estadía.",
    ],
    1: [
        "Pésima experiencia. No vuelvo ni lo recomiendo.",
        "Nos cobraron de más y nunca resolvieron el reclamo.",
        "Las condiciones no corresponden en nada con las fotos publicadas.",
        "Cancelaron el servicio el mismo día sin ofrecer alternativa.",
        "Trato irrespetuoso del personal. Una pérdida de tiempo y dinero.",
    ],
}

TITULOS = {
    5: ["Excelente", "Inolvidable", "Perfecto", "Lo mejor del viaje", "Volveremos"],
    4: ["Muy bueno", "Buena elección", "Recomendado", "Grata sorpresa", "Cumplió"],
    3: ["Aceptable", "Ni fu ni fa", "Correcto", "Esperaba más", "Regular"],
    2: ["Decepcionante", "No lo repetiría", "Mala organización", "Deficiente", "Problemas"],
    1: ["Pésimo", "Evitar", "Muy mala experiencia", "No recomendado", "Un desastre"],
}

ETIQUETAS = {
    5: ["limpieza", "servicio", "ubicacion", "comida", "relacion_calidad_precio"],
    4: ["servicio", "ubicacion", "comodidad", "desayuno"],
    3: ["ubicacion", "precio", "instalaciones"],
    2: ["limpieza", "atencion", "puntualidad", "instalaciones"],
    1: ["atencion", "cobro_indebido", "cancelacion", "limpieza"],
}

IDIOMAS = ["es", "es", "es", "en", "en", "de", "fr", "pt"]
CANALES = ["Sitio web", "App movil", "Agencia en linea", "Buscador", "Redes sociales"]
DISPOSITIVOS = ["Escritorio", "Movil", "Movil", "Tablet"]

TIPOS_EVENTO = [
    "busqueda",
    "busqueda",
    "vista_hotel",
    "vista_hotel",
    "vista_tour",
    "vista_paquete",
    "agregar_carrito",
    "abandono_carrito",
    "inicio_reserva",
    "reserva_completada",
]

EVENTOS_CONVERSION = {"reserva_completada"}

PAISES_VISITANTE = [
    "Costa Rica", "Costa Rica", "Estados Unidos", "Estados Unidos",
    "Espana", "Mexico", "Colombia", "Canada", "Alemania", "Argentina",
]

FECHA_INICIO = datetime(2021, 1, 1)
FECHA_FIN = datetime(2026, 12, 31)
DIAS_RANGO = (FECHA_FIN - FECHA_INICIO).days


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def log(mensaje: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {mensaje}", flush=True)


def leer_llaves_postgres() -> dict[str, list[int]]:
    """Trae del origen relacional los IDs con los que se van a cruzar los documentos."""
    log("Leyendo identificadores desde PostgreSQL...")
    with psycopg2.connect(**config.PG) as cn, cn.cursor() as cur:
        cur.execute("SELECT cliente_id FROM cliente ORDER BY cliente_id")
        clientes = [f[0] for f in cur.fetchall()]

        cur.execute("SELECT hotel_id FROM hotel ORDER BY hotel_id")
        hoteles = [f[0] for f in cur.fetchall()]

        cur.execute("SELECT tour_id FROM tour ORDER BY tour_id")
        tours = [f[0] for f in cur.fetchall()]

        cur.execute("SELECT paquete_id FROM paquete_turistico ORDER BY paquete_id")
        paquetes = [f[0] for f in cur.fetchall()]

        cur.execute("SELECT DISTINCT ciudad FROM hotel ORDER BY ciudad")
        destinos = [f[0] for f in cur.fetchall()]

    log(
        f"  clientes={len(clientes):,}  hoteles={len(hoteles):,}  "
        f"tours={len(tours):,}  paquetes={len(paquetes):,}  destinos={len(destinos):,}"
    )
    if not (clientes and hoteles and tours):
        raise SystemExit(
            "PostgreSQL no tiene datos de turismo. Ejecute antes "
            "01-postgres/10-generador-volumen.sql"
        )
    return {
        "clientes": clientes,
        "hoteles": hoteles,
        "tours": tours,
        "paquetes": paquetes,
        "destinos": destinos,
    }


def fecha_aleatoria(rnd: random.Random) -> datetime:
    """Fecha dentro del rango del proyecto, con sesgo hacia la temporada alta."""
    d = rnd.randint(0, DIAS_RANGO)
    f = FECHA_INICIO + timedelta(days=d)
    # Reintento sesgado: si cae en temporada baja, hay 40 % de probabilidad de
    # volver a tirar. Reproduce el pico de actividad de diciembre-enero y julio.
    if f.month not in (12, 1, 2, 3, 7) and rnd.random() < 0.40:
        f = FECHA_INICIO + timedelta(days=rnd.randint(0, DIAS_RANGO))
    return f + timedelta(
        hours=rnd.randint(0, 23), minutes=rnd.randint(0, 59), seconds=rnd.randint(0, 59)
    )


def calificacion_sesgada(rnd: random.Random) -> int:
    """Distribucion realista de calificaciones: mayoria positivas, cola negativa.

    5 -> 42 %   4 -> 30 %   3 -> 15 %   2 -> 8 %   1 -> 5 %
    """
    r = rnd.random()
    if r < 0.42:
        return 5
    if r < 0.72:
        return 4
    if r < 0.87:
        return 3
    if r < 0.95:
        return 2
    return 1


# ---------------------------------------------------------------------------
# Generadores
# ---------------------------------------------------------------------------
def generar_resenas(rnd: random.Random, llaves: dict, cantidad: int):
    """Produce documentos de resena de a uno (generador, no lista: 500k docs
    completos en memoria consumirian varios GB)."""
    clientes = llaves["clientes"]
    hoteles = llaves["hoteles"]
    tours = llaves["tours"]
    paquetes = llaves["paquetes"]

    for i in range(cantidad):
        cal = calificacion_sesgada(rnd)

        # 60 % hoteles, 30 % tours, 10 % paquetes: refleja que el visitante
        # califica sobre todo donde durmio.
        r = rnd.random()
        if r < 0.60:
            tipo, entidad = "HOTEL", rnd.choice(hoteles)
        elif r < 0.90:
            tipo, entidad = "TOUR", rnd.choice(tours)
        else:
            tipo, entidad = "PAQUETE", rnd.choice(paquetes)

        n_etiquetas = rnd.randint(1, min(3, len(ETIQUETAS[cal])))

        yield {
            "cliente_id": rnd.choice(clientes),
            "tipo_entidad": tipo,
            "entidad_id": entidad,
            "calificacion": cal,
            "titulo": rnd.choice(TITULOS[cal]),
            "comentario": rnd.choice(COMENTARIOS[cal]),
            "idioma": rnd.choice(IDIOMAS),
            "fecha": fecha_aleatoria(rnd),
            # Solo ~70 % de las resenas provienen de una reserva comprobada.
            "verificada": rnd.random() < 0.70,
            "etiquetas": rnd.sample(ETIQUETAS[cal], n_etiquetas),
            "origen_canal": rnd.choice(CANALES),
            "util_votos": rnd.randint(0, 40),
        }


def generar_interacciones(rnd: random.Random, llaves: dict, cantidad: int):
    clientes = llaves["clientes"]
    hoteles = llaves["hoteles"]
    tours = llaves["tours"]
    destinos = llaves["destinos"] or ["San Jose"]

    for i in range(cantidad):
        evento = rnd.choice(TIPOS_EVENTO)

        # 35 % del trafico es anonimo: nadie inicia sesion para buscar.
        anonimo = rnd.random() < 0.35
        cliente = None if anonimo else rnd.choice(clientes)

        if evento in ("vista_hotel",):
            ent_tipo, ent_id = "HOTEL", rnd.choice(hoteles)
        elif evento in ("vista_tour",):
            ent_tipo, ent_id = "TOUR", rnd.choice(tours)
        else:
            ent_tipo, ent_id = None, None

        yield {
            "cliente_id": cliente,
            "sesion_id": f"s-{rnd.getrandbits(48):012x}",
            "tipo_evento": evento,
            "destino_buscado": rnd.choice(destinos) if evento == "busqueda" else None,
            "entidad_tipo": ent_tipo,
            "entidad_id": ent_id,
            "dispositivo": rnd.choice(DISPOSITIVOS),
            "canal": rnd.choice(CANALES),
            "pais_visitante": rnd.choice(PAISES_VISITANTE),
            "fecha_evento": fecha_aleatoria(rnd),
            "duracion_seg": rnd.randint(3, 900),
            "convirtio": evento in EVENTOS_CONVERSION,
        }


def insertar_por_lotes(coleccion, generador, total: int, lote: int, etiqueta: str) -> int:
    """Inserta en bloques con ordered=False, que deja a MongoDB paralelizar."""
    inicio = time.time()
    buffer, insertados = [], 0

    for doc in generador:
        buffer.append(doc)
        if len(buffer) >= lote:
            coleccion.insert_many(buffer, ordered=False)
            insertados += len(buffer)
            buffer.clear()
            pct = 100 * insertados / total
            log(f"  {etiqueta}: {insertados:,} / {total:,} ({pct:.0f} %) "
                f"- {time.time() - inicio:.0f}s")

    if buffer:
        coleccion.insert_many(buffer, ordered=False)
        insertados += len(buffer)

    log(f"  {etiqueta}: {insertados:,} documentos en {time.time() - inicio:.1f}s")
    return insertados


# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description="Siembra MongoDB para el Escenario 8.")
    p.add_argument("--resenas", type=int, default=config.N_RESENAS)
    p.add_argument("--interacciones", type=int, default=config.N_INTERACCIONES)
    p.add_argument("--limpiar", action="store_true",
                   help="Elimina las colecciones antes de sembrar.")
    args = p.parse_args()

    rnd = random.Random(config.SEMILLA)
    llaves = leer_llaves_postgres()

    log(f"Conectando a MongoDB: {config.MONGO_URI} -> {config.MONGO_DB}")
    cliente = MongoClient(config.MONGO_URI)
    db = cliente[config.MONGO_DB]

    col_resenas = db[config.COLECCION_RESENAS]
    col_interacciones = db[config.COLECCION_INTERACCIONES]

    if args.limpiar:
        log("Eliminando colecciones existentes...")
        col_resenas.drop()
        col_interacciones.drop()
    elif col_resenas.estimated_document_count() > 0:
        raise SystemExit(
            f"La coleccion '{config.COLECCION_RESENAS}' ya tiene documentos. "
            "Use --limpiar para regenerarla."
        )

    log(f"Generando {args.resenas:,} resenas...")
    n_res = insertar_por_lotes(
        col_resenas,
        generar_resenas(rnd, llaves, args.resenas),
        args.resenas,
        config.MONGO_TAMANO_LOTE,
        "resenas",
    )

    log(f"Generando {args.interacciones:,} interacciones web...")
    n_int = insertar_por_lotes(
        col_interacciones,
        generar_interacciones(rnd, llaves, args.interacciones),
        args.interacciones,
        config.MONGO_TAMANO_LOTE,
        "interacciones_web",
    )

    # Los indices se crean despues de insertar: mantenerlos durante una carga
    # masiva de 2 millones de documentos es mucho mas lento que reconstruirlos.
    log("Creando indices...")
    col_resenas.create_index([("fecha", ASCENDING)])
    col_resenas.create_index([("entidad_id", ASCENDING), ("tipo_entidad", ASCENDING)])
    col_resenas.create_index([("cliente_id", ASCENDING)])
    col_interacciones.create_index([("fecha_evento", ASCENDING)])
    col_interacciones.create_index([("cliente_id", ASCENDING)])
    col_interacciones.create_index([("tipo_evento", ASCENDING)])

    log("")
    log("=== Resumen ===")
    log(f"  {config.MONGO_DB}.{config.COLECCION_RESENAS}: {n_res:,} documentos")
    log(f"  {config.MONGO_DB}.{config.COLECCION_INTERACCIONES}: {n_int:,} documentos")
    log("Siembra completada.")
    cliente.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
