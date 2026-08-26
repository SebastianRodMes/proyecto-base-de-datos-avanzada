# Tema de investigación — Machine Learning: clasificación de reseñas

Proyecto Turismo Inteligente · Semanas 3 y 4

Prototipo de **clasificación de sentimiento** sobre las reseñas de clientes: a partir
del texto de una reseña, el modelo predice si es **negativa, neutral o positiva**.

---

## 1. Justificación del tema

El enunciado ofrece nueve temas de investigación (CDC, Kafka, Data Lake, Docker,
Data Vault, GeoJSON, series temporales, Machine Learning y observabilidad). Se
eligió **Machine Learning** por tres razones:

- **El modelo de datos ya lo contempla.** La tabla de hechos `dw.FactReseña` guarda
  la longitud del texto de la reseña como insumo previsto para clasificación con ML.
- **Los datos están disponibles.** Las 500,002 reseñas, con texto, calificación,
  idioma y verificación, están almacenadas en MongoDB Atlas.
- **Aporta valor de negocio.** Permite medir la satisfacción del cliente a partir
  del texto, sin depender únicamente de la calificación numérica.

## 2. Objetivo de negocio

Turismo Inteligente recibe miles de reseñas de hoteles, tours y paquetes. La
calificación de 1 a 5 estrellas existe, pero la clasificación del texto permite:

- **auto-etiquetar** reseñas de canales donde solo llega texto libre;
- **alertar** ante un repunte de reseñas negativas;
- **alimentar** indicadores de satisfacción del dashboard sin lectura manual.

## 3. Arquitectura del prototipo

```text
MongoDB Atlas                 Prototipo ML (Python + scikit-learn)
turismo_nosql.resenas  --->   01_extraer_resenas.py   --> data/resenas.csv
(500,002 docs)                 02_entrenar_modelo.py    --> modelos/modelo_sentimiento.joblib
                                     |                       evidencias/metricas.txt
                                     |                       evidencias/matriz-confusion.png
                                     v
                               03_predecir.py  (clasifica texto libre)
```

La fuente de datos es la base en la nube (MongoDB Atlas). El entrenamiento y la
predicción se ejecutan de forma local.

**Modelo:** `TF-IDF (1–2 gramas)` seguido de `Regresión Logística` multiclase. Se
optó por un modelo simple, reproducible y explicable, adecuado al alcance del
enunciado, en lugar de arquitecturas más pesadas que no aportarían sobre este
conjunto de datos.

**Etiquetas** (alineadas con `dw.FactReseña`):

| Calificación | Clase |
|---|---|
| 1–2 | negativa |
| 3 | neutral |
| 4–5 | positiva |

## 4. Cómo ejecutar

Requiere la cadena de conexión a MongoDB Atlas (archivo de configuración del
proyecto). Atlas está disponible de forma permanente, por lo que no es necesario
levantar el entorno local ni las instancias de la nube.

```bash
cd 08-investigacion-ml/ml
pip install -r requirements.txt

python 01_extraer_resenas.py      # Atlas -> data/resenas.csv  (~100 s)
python 02_entrenar_modelo.py      # entrena, evalúa y guarda modelo + evidencias
python 03_predecir.py             # demostración con frases de ejemplo
python 03_predecir.py "el hotel estaba sucio y el trato fue pesimo"
```

## 5. Resultados

| Métrica | Valor |
|---|---|
| Registros | 500,002 (400,001 entrenamiento / 100,001 prueba) |
| Vocabulario TF-IDF | 477 términos |
| Exactitud global | 1.0000 |

Términos más asociados a cada clase:

- **negativa:** no, decepcionante, deficiente, problemas, mala, no lo recomiendo
- **neutral:** ni, aceptable, correcto, regular, algo, lento
- **positiva:** recomendado, excelente, cumplió, buena relación calidad precio

La matriz de confusión está en
[`evidencias/matriz-confusion.png`](evidencias/matriz-confusion.png) y el reporte
por clase en [`evidencias/metricas.txt`](evidencias/metricas.txt).

## 6. Naturaleza de los datos

El conjunto de reseñas es sintético: el texto se genera a partir de plantillas
asociadas a la calificación, por lo que el texto se corresponde de forma muy directa
con la nota. Esto explica la exactitud del 100% y se refleja en dos indicadores:

1. un vocabulario reducido (477 términos), frente a las decenas de miles de un
   corpus real;
2. la separación de las clases sin errores.

**Alcance del prototipo.** El prototipo valida el flujo completo de trabajo
—extracción desde la nube, vectorización, entrenamiento, evaluación y predicción—
sobre el volumen real de 500 mil registros. Además, el modelo clasifica
correctamente frases escritas manualmente que no forman parte de las plantillas:

```
[negativa 62.3%]  el hotel estaba sucio, la comida fea y el trato horrible, jamas vuelvo
[positiva 95.2%]  que maravilla de lugar, quede encantado, super recomendado
```

**Trabajo de la Semana 4.** Para una medición representativa se recomienda validar
el modelo contra un conjunto de reseñas reales en español, o enriquecer el
generador para que el texto no dependa directamente de la calificación.

## 7. Estructura de archivos

```text
08-investigacion-ml/
├── README.md                 documentación del tema
├── Reseñas.pptx              presentación
├── .gitignore                excluye data/ y modelos/ (regenerables)
├── ml/
│   ├── config.py             conexión, rutas y mapeo de etiquetas
│   ├── 01_extraer_resenas.py Atlas -> CSV
│   ├── 02_entrenar_modelo.py entrena y evalúa
│   ├── 03_predecir.py        predicción de texto libre
│   └── requirements.txt
├── data/                     dataset extraído (no versionado)
├── modelos/                  modelo entrenado (no versionado)
└── evidencias/
    ├── metricas.txt          reporte de métricas por clase
    ├── matriz-confusion.png  matriz de confusión
    └── distribucion-clases.png
```
