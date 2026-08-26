"""Paso 2 - Entrenamiento.

Modelo simple de clasificacion de sentimiento de resenas:
  texto (titulo + comentario) --> TF-IDF --> Regresion Logistica --> clase

Clases: negativa (1-2), neutral (3), positiva (4-5).
Guarda el modelo entrenado y un reporte de metricas + matriz de confusion.
"""
import sys

import joblib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (ConfusionMatrixDisplay, classification_report,
                             confusion_matrix)
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline

import config

CLASES = ["negativa", "neutral", "positiva"]


def main() -> int:
    config.DIR_MODELOS.mkdir(parents=True, exist_ok=True)
    config.DIR_EVIDENCIAS.mkdir(parents=True, exist_ok=True)

    print("Cargando dataset...", flush=True)
    df = pd.read_csv(config.ARCHIVO_DATASET)
    df["titulo"] = df["titulo"].fillna("")
    df["comentario"] = df["comentario"].fillna("")
    df["texto"] = (df["titulo"] + ". " + df["comentario"]).str.strip()
    df["sentimiento"] = df["calificacion"].apply(config.etiqueta_sentimiento)

    print(f"Filas: {len(df):,}")
    print("Distribución de clases:")
    for c in CLASES:
        n = int((df["sentimiento"] == c).sum())
        print(f"  {c:9s}: {n:>7,}  ({n/len(df)*100:5.1f}%)")

    X = df["texto"].values
    y = df["sentimiento"].values
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )
    print(f"\nEntrenamiento: {len(X_tr):,} | Prueba: {len(X_te):,}")

    # Pipeline simple y reproducible. class_weight balanced compensa el
    # desbalance hacia resenas positivas.
    modelo = Pipeline([
        ("tfidf", TfidfVectorizer(
            lowercase=True,
            strip_accents="unicode",
            ngram_range=(1, 2),
            min_df=5,
            max_features=40000,
            sublinear_tf=True,
        )),
        ("clf", LogisticRegression(
            max_iter=1000,
            C=4.0,
            class_weight="balanced",
        )),
    ])

    print("Entrenando (TF-IDF + Regresión Logística)...", flush=True)
    modelo.fit(X_tr, y_tr)

    print("Evaluando...", flush=True)
    y_pred = modelo.predict(X_te)
    reporte = classification_report(y_te, y_pred, labels=CLASES, digits=4)
    exactitud = (y_pred == y_te).mean()

    cm = confusion_matrix(y_te, y_pred, labels=CLASES)

    # Guardar metricas
    n_vocab = len(modelo.named_steps["tfidf"].vocabulary_)
    lineas = [
        "PROTOTIPO ML - CLASIFICACIÓN DE SENTIMIENTO DE RESEÑAS",
        "=" * 56,
        f"Registros totales : {len(df):,}",
        f"Entrenamiento     : {len(X_tr):,}",
        f"Prueba            : {len(X_te):,}",
        f"Vocabulario TF-IDF: {n_vocab:,} términos (1-2 gramas)",
        f"Exactitud global  : {exactitud:.4f}",
        "",
        "Reporte por clase (conjunto de prueba):",
        reporte,
        "Matriz de confusión (filas=real, columnas=predicho):",
        "         " + "  ".join(f"{c:>9s}" for c in CLASES),
    ]
    for i, c in enumerate(CLASES):
        lineas.append(f"{c:>8s} " + "  ".join(f"{v:>9,}" for v in cm[i]))
    reporte_txt = "\n".join(lineas)
    config.ARCHIVO_METRICAS.write_text(reporte_txt, encoding="utf-8")
    print("\n" + reporte_txt)

    # Terminos mas influyentes por clase (interpretabilidad para la demo)
    print("\nTérminos más asociados a cada clase:")
    tfidf = modelo.named_steps["tfidf"]
    clf = modelo.named_steps["clf"]
    vocab = np.array(tfidf.get_feature_names_out())
    for idx, c in enumerate(clf.classes_):
        top = np.argsort(clf.coef_[idx])[-12:][::-1]
        print(f"  {c:9s}: " + ", ".join(vocab[top]))

    # Matriz de confusion como imagen
    fig, ax = plt.subplots(figsize=(5.5, 4.5))
    ConfusionMatrixDisplay(cm, display_labels=CLASES).plot(
        ax=ax, cmap="Blues", colorbar=False, values_format=","
    )
    ax.set_title("Matriz de confusión - sentimiento de reseñas")
    fig.tight_layout()
    fig.savefig(config.ARCHIVO_MATRIZ, dpi=120)
    print(f"\nMatriz de confusion -> {config.ARCHIVO_MATRIZ}")

    joblib.dump(modelo, config.ARCHIVO_MODELO)
    print(f"Modelo guardado    -> {config.ARCHIVO_MODELO}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
