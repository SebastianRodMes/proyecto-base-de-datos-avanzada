"""Paso 3 - Prediccion / demo.

Carga el modelo entrenado y clasifica texto libre. Sirve para la demostracion:
  - sin argumentos, corre una bateria de frases de ejemplo;
  - con argumentos, clasifica el texto recibido en la linea de comandos.

    python 03_predecir.py "el hotel estaba sucio y el trato fue pesimo"
"""
import sys

import joblib

import config

EJEMPLOS = [
    "El mejor viaje de mi vida, todo excelente y el personal muy amable.",
    "El tour estuvo bien pero el transporte llego tarde, algo regular.",
    "Una experiencia decepcionante, el servicio fue deficiente y no lo recomiendo.",
    "Cumplio con lo prometido, buena relacion calidad precio.",
    "Ni bueno ni malo, aceptable para el precio que costo.",
]


def clasificar(modelo, textos):
    pred = modelo.predict(textos)
    proba = modelo.predict_proba(textos)
    clases = list(modelo.named_steps["clf"].classes_)
    salida = []
    for t, p, pr in zip(textos, pred, proba):
        conf = pr[clases.index(p)]
        salida.append((t, p, conf))
    return salida


def main() -> int:
    if not config.ARCHIVO_MODELO.exists():
        print(f"No existe el modelo {config.ARCHIVO_MODELO}. "
              "Corre 02_entrenar_modelo.py primero.")
        return 1
    modelo = joblib.load(config.ARCHIVO_MODELO)

    textos = [" ".join(sys.argv[1:])] if len(sys.argv) > 1 else EJEMPLOS
    print("Clasificación de sentimiento\n" + "-" * 60)
    for texto, clase, conf in clasificar(modelo, textos):
        print(f"[{clase:>8s}  {conf*100:5.1f}%]  {texto}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
