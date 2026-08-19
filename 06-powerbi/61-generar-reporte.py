"""
ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
Integrante 1: Alex Herrera

61-generar-reporte.py
=====================

Genera el lienzo del reporte -- las 6 paginas con sus visuales -- en formato
PBIR (Power BI Enhanced Report Format), donde cada visual es un archivo JSON
de texto en lugar de un blob dentro del .pbix.

Se ejecuta despues de 60-generar-pbip.py, que produce el modelo semantico.

Por que se genera y no se arma a mano
-------------------------------------
Son 6 paginas con unos 30 visuales, cada uno con su tipo, su posicion, sus
campos y su formato. Armarlos a mano en la interfaz toma cerca de una hora y
el resultado no queda versionado: si alguien lo rompe, no hay diff que mirar.
En PBIR cada visual es un archivo, asi que el reporte entero se revisa y se
regenera igual que el resto del proyecto.

Limitacion honesta
------------------
El formato PBIR evoluciona entre versiones de Power BI Desktop. Estos
archivos se generan segun el esquema publicado, pero NO se pudieron abrir en
Power BI Desktop desde este entorno para confirmarlo visualmente. Si alguna
version rechaza el lienzo, el modelo semantico (60-generar-pbip.py) sigue
siendo valido y las paginas se arman siguiendo 00-docs/04-guia-powerbi.md.

Requisito en Power BI Desktop
-----------------------------
    Archivo > Opciones > Caracteristicas de vista previa
      [x] Almacenar el reporte con formato PBIR mejorado

Uso:
    python 61-generar-reporte.py
"""

from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
NOMBRE = "TurismoDW"
DIR_REPORTE = RAIZ / f"{NOMBRE}.Report"
DIR_DEF = DIR_REPORTE / "definition"

ANCHO, ALTO = 1280, 720

# Paleta del reporte. Verde jade como acento -- es un proyecto de turismo
# sostenible -- con ambar para lo que exige atencion y gris azulado neutro.
TEMA = {
    "name": "TurismoDW",
    "dataColors": ["#0B6E55", "#2E6288", "#B5822A", "#6B4A85", "#3D7A3C",
                   "#9C4A18", "#4A7C8C", "#7A5C3E", "#556B5D", "#8C6A9E"],
    "background": "#FFFFFF",
    "foreground": "#131A17",
    "tableAccent": "#0B6E55",
}


# ---------------------------------------------------------------------------
# Constructores de visuales
# ---------------------------------------------------------------------------
def _campo(tabla: str, columna: str, tipo: str = "column") -> dict:
    """Referencia a una columna o medida en el lenguaje de consulta del visual."""
    if tipo == "measure":
        return {"Measure": {"Expression": {"SourceRef": {"Entity": tabla}},
                            "Property": columna}}
    return {"Column": {"Expression": {"SourceRef": {"Entity": tabla}},
                       "Property": columna}}


def _proyeccion(tabla: str, nombre: str, tipo: str, idx: int) -> dict:
    return {
        "field": _campo(tabla, nombre, tipo),
        "queryRef": f"{tabla}.{nombre}",
        "nativeQueryRef": nombre,
    }


def visual(nombre_archivo: str, tipo: str, x: int, y: int, w: int, h: int,
           roles: dict, titulo: str | None = None,
           opciones: dict | None = None) -> dict:
    """Arma la definicion de un visual.

    roles: {rol_visual: [(tabla, campo, 'column'|'measure'), ...]}
           Los roles dependen del tipo: 'Category'/'Y' en graficos de barras,
           'Values' en tarjetas, 'Rows'/'Columns' en matrices.
    """
    proyecciones: dict[str, list] = {}
    for rol, campos in roles.items():
        proyecciones[rol] = [
            _proyeccion(t, c, k, i) for i, (t, c, k) in enumerate(campos)
        ]

    objetos: dict = {}
    if titulo:
        objetos["title"] = [{
            "properties": {
                "text": {"expr": {"Literal": {"Value": f"'{titulo}'"}}},
                "fontSize": {"expr": {"Literal": {"Value": "12D"}}},
                "fontColor": {"solid": {"color": {"expr": {"Literal": {"Value": "'#131A17'"}}}}},
            }
        }]
    if opciones:
        objetos.update(opciones)

    return {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/1.0.0/schema.json",
        "name": nombre_archivo,
        "position": {"x": x, "y": y, "z": 0, "width": w, "height": h},
        "visual": {
            "visualType": tipo,
            "query": {"queryState": {
                rol: {"projections": proy} for rol, proy in proyecciones.items()
            }},
            "objects": objetos,
        },
    }


def tarjeta(nombre: str, x: int, y: int, w: int, h: int,
            medida: str, titulo: str) -> dict:
    return visual(nombre, "card", x, y, w, h,
                  {"Values": [("_Medidas", medida, "measure")]}, titulo)


def segmentador(nombre: str, x: int, y: int, w: int, h: int,
                tabla: str, columna: str, titulo: str) -> dict:
    return visual(nombre, "slicer", x, y, w, h,
                  {"Values": [(tabla, columna, "column")]}, titulo)


# ---------------------------------------------------------------------------
# Las seis paginas
# ---------------------------------------------------------------------------
def pagina_resumen() -> tuple[str, str, list[dict]]:
    v = []
    # Fila de tarjetas: los seis KPI que exige el escenario, de un vistazo.
    kpis = [
        ("Reservas", "Reservas"),
        ("Ingresos confirmados", "Ingresos"),
        ("% Ocupacion hotelera", "Ocupacion"),
        ("Promedio de estadia (noches)", "Estadia media"),
        ("Indice de satisfaccion", "Satisfaccion"),
        ("Ticket promedio", "Ticket promedio"),
    ]
    for i, (medida, titulo) in enumerate(kpis):
        v.append(tarjeta(f"kpi{i}", 24 + i * 205, 70, 195, 100, medida, titulo))

    v.append(visual("tendencia", "lineChart", 24, 190, 800, 260, {
        "Category": [("DimTiempo", "AnioMesEtiqueta", "column")],
        "Y": [("_Medidas", "Ingresos confirmados", "measure"),
              ("_Medidas", "Ingresos ano anterior", "measure")],
    }, "Ingresos por mes contra el ano anterior"))

    v.append(visual("mix_estado", "donutChart", 840, 190, 416, 260, {
        "Category": [("DimEstadoReserva", "Estado", "column")],
        "Y": [("_Medidas", "Reservas", "measure")],
    }, "Reservas por estado"))

    v.append(visual("top_paises", "barChart", 24, 466, 600, 230, {
        "Category": [("DimCliente", "PaisOrigen", "column")],
        "Y": [("_Medidas", "Reservas", "measure")],
    }, "Paises de origen del visitante"))

    v.append(segmentador("sl_anio", 640, 466, 190, 230,
                         "DimTiempo", "Anio", "Ano"))
    v.append(segmentador("sl_pais", 846, 466, 200, 230,
                         "DimHotel", "Pais", "Pais del destino"))
    v.append(segmentador("sl_temporada", 1062, 466, 194, 230,
                         "DimTiempo", "TipoTemporada", "Temporada"))
    return "resumen", "1 · Resumen ejecutivo", v


def pagina_ocupacion() -> tuple[str, str, list[dict]]:
    v = [
        tarjeta("oc_kpi0", 24, 70, 260, 100, "% Ocupacion hotelera", "Ocupacion promedio"),
        tarjeta("oc_kpi1", 296, 70, 260, 100, "Habitaciones ocupadas", "Habitaciones-noche"),
        tarjeta("oc_kpi2", 568, 70, 260, 100, "Ingresos por hotel", "Ingresos por alojamiento"),
        tarjeta("oc_kpi3", 840, 70, 260, 100, "Destinos visitados", "Destinos activos"),
    ]
    v.append(visual("oc_mapa", "map", 24, 190, 620, 300, {
        "Category": [("DimHotel", "Ciudad", "column")],
        "Size": [("_Medidas", "Habitaciones ocupadas", "measure")],
    }, "Ocupacion por destino"))

    # Matriz hotel x mes: el patron estacional se lee de un golpe.
    v.append(visual("oc_matriz", "pivotTable", 660, 190, 596, 300, {
        "Rows": [("DimHotel", "Nombre", "column")],
        "Columns": [("DimTiempo", "NombreMesCorto", "column")],
        "Values": [("_Medidas", "% Ocupacion hotelera", "measure")],
    }, "Ocupacion por hotel y mes"))

    v.append(visual("oc_evolucion", "areaChart", 24, 506, 620, 190, {
        "Category": [("DimTiempo", "AnioMesEtiqueta", "column")],
        "Y": [("_Medidas", "% Ocupacion hotelera", "measure")],
    }, "Evolucion de la ocupacion"))

    v.append(visual("oc_ranking", "tableEx", 660, 506, 596, 190, {
        "Values": [("DimHotel", "Nombre", "column"),
                   ("DimHotel", "Categoria", "column"),
                   ("_Medidas", "% Ocupacion hotelera", "measure"),
                   ("_Medidas", "Ingresos por hotel", "measure")],
    }, "Detalle por hotel"))
    return "ocupacion", "2 · Ocupacion hotelera", v


def pagina_temporadas() -> tuple[str, str, list[dict]]:
    v = [
        tarjeta("tp_kpi0", 24, 70, 260, 100, "Reservas en temporada alta", "Temporada alta"),
        tarjeta("tp_kpi1", 296, 70, 260, 100, "Concentracion en temporada alta", "Concentracion"),
        tarjeta("tp_kpi2", 568, 70, 260, 100, "Tasa de cancelacion", "Cancelacion"),
        tarjeta("tp_kpi3", 840, 70, 260, 100, "Crecimiento de ingresos YoY", "Crecimiento YoY"),
    ]
    v.append(visual("tp_anio", "clusteredColumnChart", 24, 190, 620, 280, {
        "Category": [("DimTiempo", "Anio", "column")],
        "Series": [("DimTiempo", "TipoTemporada", "column")],
        "Y": [("_Medidas", "Reservas", "measure")],
    }, "Reservas por ano y temporada"))

    v.append(visual("tp_mes", "columnChart", 660, 190, 596, 280, {
        "Category": [("DimTiempo", "NombreMes", "column")],
        "Y": [("_Medidas", "Reservas", "measure")],
    }, "Estacionalidad mensual"))

    v.append(visual("tp_cancel", "lineChart", 24, 486, 620, 210, {
        "Category": [("DimTiempo", "AnioMesEtiqueta", "column")],
        "Y": [("_Medidas", "Tasa de cancelacion", "measure")],
    }, "Cancelaciones en el tiempo"))

    v.append(visual("tp_antic", "columnChart", 660, 486, 596, 210, {
        "Category": [("DimPaquete", "RangoDuracion", "column")],
        "Y": [("_Medidas", "Dias de anticipacion promedio", "measure")],
    }, "Anticipacion segun duracion del paquete"))
    return "temporadas", "3 · Reservas y temporadas", v


def pagina_destinos() -> tuple[str, str, list[dict]]:
    v = [
        tarjeta("ds_kpi0", 24, 70, 260, 100, "Tours solicitados", "Tours vendidos"),
        tarjeta("ds_kpi1", 296, 70, 260, 100, "Ingresos por tour", "Ingresos por tour"),
        tarjeta("ds_kpi2", 568, 70, 260, 100, "Personas en tours", "Participantes"),
        tarjeta("ds_kpi3", 840, 70, 260, 100, "Ingresos por paquete", "Ingresos por paquete"),
    ]
    v.append(visual("ds_destinos", "barChart", 24, 190, 620, 300, {
        "Category": [("DimHotel", "PaisCiudad", "column")],
        "Y": [("_Medidas", "Reservas alojamiento", "measure")],
    }, "Destinos mas visitados"))

    v.append(visual("ds_tours", "barChart", 660, 190, 596, 300, {
        "Category": [("DimTour", "Nombre", "column")],
        "Y": [("_Medidas", "Tours solicitados", "measure")],
    }, "Tours mas solicitados"))

    v.append(visual("ds_actividad", "treemap", 24, 506, 620, 190, {
        "Group": [("DimTour", "TipoActividad", "column")],
        "Values": [("_Medidas", "Ingresos por tour", "measure")],
    }, "Ingresos por tipo de actividad"))

    v.append(visual("ds_proveedor", "tableEx", 660, 506, 596, 190, {
        "Values": [("DimTour", "Proveedor", "column"),
                   ("_Medidas", "Tours solicitados", "measure"),
                   ("_Medidas", "Ingresos por tour", "measure")],
    }, "Desempeno por proveedor"))
    return "destinos", "4 · Destinos y tours", v


def pagina_visitante() -> tuple[str, str, list[dict]]:
    v = [
        tarjeta("vi_kpi0", 24, 70, 260, 100, "Indice de satisfaccion", "Satisfaccion"),
        tarjeta("vi_kpi1", 296, 70, 260, 100, "Calificacion promedio", "Calificacion media"),
        tarjeta("vi_kpi2", 568, 70, 260, 100, "Resenas", "Resenas recibidas"),
        tarjeta("vi_kpi3", 840, 70, 260, 100, "Tasa de conversion web", "Conversion web"),
    ]
    v.append(visual("vi_calif", "columnChart", 24, 190, 400, 280, {
        "Category": [("FactResena", "Calificacion", "column")],
        "Y": [("_Medidas", "Resenas", "measure")],
    }, "Distribucion de calificaciones"))

    v.append(visual("vi_perfil", "stackedColumnChart", 440, 190, 400, 280, {
        "Category": [("DimCliente", "RangoEdad", "column")],
        "Series": [("DimCliente", "GrupoViaje", "column")],
        "Y": [("_Medidas", "Reservas", "measure")],
    }, "Perfil demografico"))

    v.append(visual("vi_aloj", "treemap", 856, 190, 400, 280, {
        "Group": [("DimCliente", "TipoAlojamiento", "column")],
        "Values": [("_Medidas", "Reservas", "measure")],
    }, "Preferencia de alojamiento"))

    # Lo declarado contra lo gastado: el cruce que justifica haber traido las
    # preferencias (RF-09 y RF-10) al modelo analitico.
    v.append(visual("vi_presup", "lineClusteredColumnComboChart", 24, 486, 620, 210, {
        "Category": [("DimCliente", "RangoPresupuesto", "column")],
        "Y": [("_Medidas", "Ticket promedio", "measure")],
        "Y2": [("_Medidas", "Presupuesto promedio declarado", "measure")],
    }, "Presupuesto declarado contra gasto real"))

    v.append(visual("vi_embudo", "funnel", 660, 486, 596, 210, {
        "Category": [("FactInteraccionWeb", "TipoEvento", "column")],
        "Y": [("_Medidas", "Interacciones", "measure")],
    }, "Embudo de comportamiento web"))
    return "visitante", "5 · Perfil del visitante y satisfaccion", v


def pagina_sistema() -> tuple[str, str, list[dict]]:
    """La pagina que evidencia la conexion al modelo de alta disponibilidad.

    Todo sale de dw.vw_EstadoSistema, que se evalua contra el nodo al que se
    resolvio el alias TURISMODW en el momento del refresco. Tras el failover,
    NodoActual cambia solo y los totales se mantienen.
    """
    v = [
        tarjeta("sy_nodo", 24, 70, 300, 100, "Nodo activo", "Nodo activo"),
        tarjeta("sy_mirror", 336, 70, 300, 100, "Estado del mirroring", "Estado del mirroring"),
        tarjeta("sy_carga", 648, 70, 300, 100, "Ultima carga", "Ultima carga"),
        tarjeta("sy_frescura", 960, 70, 296, 100, "Semaforo de frescura", "Frescura de los datos"),
    ]
    v.append(visual("sy_infra", "tableEx", 24, 190, 612, 240, {
        "Values": [("EstadoSistema", "Instancia", "column"),
                   ("EstadoSistema", "Edicion", "column"),
                   ("EstadoSistema", "ModeloRecuperacion", "column"),
                   ("EstadoSistema", "RolMirroring", "column"),
                   ("EstadoSistema", "Socio", "column"),
                   ("EstadoSistema", "Testigo", "column")],
    }, "Infraestructura y alta disponibilidad"))

    v.append(visual("sy_calidad", "tableEx", 652, 190, 604, 240, {
        "Values": [("CalidadDatos", "Fuente", "column"),
                   ("CalidadDatos", "Objeto", "column"),
                   ("CalidadDatos", "Regla", "column"),
                   ("CalidadDatos", "Severidad", "column"),
                   ("CalidadDatos", "Registros", "column")],
    }, "Calidad de datos de la ultima carga (RF-15)"))

    v.append(tarjeta("sy_v0", 24, 446, 300, 110, "Reservas", "Reservas cargadas"))
    v.append(tarjeta("sy_v1", 336, 446, 300, 110, "Resenas", "Resenas cargadas"))
    v.append(tarjeta("sy_v2", 648, 446, 300, 110, "Interacciones", "Interacciones cargadas"))
    v.append(tarjeta("sy_v3", 960, 446, 296, 110,
                     "Registros rechazados en la ultima carga", "Registros rechazados"))

    # Espacio reservado para los resultados de particionamiento e indices del
    # Integrante 2, como pide el enunciado.
    v.append(visual("sy_reservado", "textbox", 24, 572, 1232, 124, {}, None, {
        "general": [{
            "properties": {
                "paragraphs": [{
                    "textRuns": [{
                        "value": ("Espacio reservado — Integrante 2: resultados de "
                                  "particionamiento e indices (antes / despues). "
                                  "Reemplazar este cuadro por la tabla comparativa."),
                        "textStyle": {"fontSize": "11pt", "color": "#77837C"},
                    }]
                }]
            }
        }]
    }))
    return "sistema", "6 · Estado del sistema", v


PAGINAS = [pagina_resumen, pagina_ocupacion, pagina_temporadas,
           pagina_destinos, pagina_visitante, pagina_sistema]


# ---------------------------------------------------------------------------
# Escritura
# ---------------------------------------------------------------------------
def escribir(ruta: Path, contenido: dict) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.write_text(json.dumps(contenido, indent=2, ensure_ascii=False),
                    encoding="utf-8")


def generar() -> None:
    print("Generando lienzo del reporte (formato PBIR)...")

    if DIR_DEF.exists():
        shutil.rmtree(DIR_DEF)
    # El report.json monolitico del formato anterior se elimina: con PBIR la
    # definicion vive en definition/, y dejar los dos confunde a Power BI.
    (DIR_REPORTE / "report.json").unlink(missing_ok=True)

    escribir(DIR_REPORTE / "definition.pbir", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/1.0.0/schema.json",
        "version": "4.0",
        "datasetReference": {"byPath": {"path": f"../{NOMBRE}.SemanticModel"}},
    })

    escribir(DIR_DEF / "version.json", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json",
        "version": "2.0.0",
    })

    escribir(DIR_DEF / "report.json", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/1.0.0/schema.json",
        "themeCollection": {"customTheme": {"name": TEMA["name"], "type": "RegisteredResources"}},
        "layoutOptimization": "None",
        "resourcePackages": [{
            "name": "RegisteredResources",
            "type": "RegisteredResources",
            "items": [{"name": TEMA["name"], "path": "tema.json", "type": "CustomTheme"}],
        }],
        "settings": {"useStylableVisualContainerHeader": True},
    })

    escribir(DIR_DEF / "StaticResources" / "RegisteredResources" / "tema.json", TEMA)

    nombres = []
    for constructor in PAGINAS:
        nombre, titulo, visuales = constructor()
        nombres.append(nombre)

        escribir(DIR_DEF / "pages" / nombre / "page.json", {
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/1.0.0/schema.json",
            "name": nombre,
            "displayName": titulo,
            "displayOption": "FitToPage",
            "height": ALTO,
            "width": ANCHO,
        })

        for vis in visuales:
            escribir(DIR_DEF / "pages" / nombre / "visuals" / vis["name"] / "visual.json", vis)

        print(f"  {titulo:<42} {len(visuales)} visuales")

    escribir(DIR_DEF / "pages" / "pages.json", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json",
        "pageOrder": nombres,
        "activePageName": nombres[0],
    })

    total = sum(len(c()[2]) for c in PAGINAS)
    print("")
    print(f"  Paginas : {len(nombres)}")
    print(f"  Visuales: {total}")
    print("")
    print("  Abrir 06-powerbi/TurismoDW.pbip en Power BI Desktop.")
    print("  Requiere activar el formato PBIR en Caracteristicas de vista previa.")


if __name__ == "__main__":
    generar()
