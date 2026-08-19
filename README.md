# Semana 3 — Integrante 1: ingreso de datos al modelo analítico y reporte Power BI

**ITI-821 Bases de Datos Avanzadas · Escenario 8: Turismo Inteligente**
**Alex Herrera**

---

## 🚀 ¿Cómo levanto todo el proyecto?

Para montar la base completa con datos en tu computadora, seguí la guía paso a
paso (pensada para todo el equipo, no hace falta saber Docker):

👉 **[docker/README.md](docker/README.md)**

En resumen: instalás Docker Desktop + SSMS, clonás el repo y corrés un comando
(`docker compose up -d --build`). El primer arranque tarda ~20 min y deja
`TurismoDW` lista en `localhost,1433`.

## 👥 Equipo

| Integrante | Persona | Parte |
|---|---|---|
| 1 | Alex Herrera | Modelo analítico, ETL y Power BI *(entregado)* |
| 2 | **Sebastián** | Filegroups, particionamiento e índices |
| 3 | **Erick** | Alta disponibilidad (Mirroring) y prueba de falla |
| 4 | **Sergio** | Rendimiento, consistencia y documentación |

---

## Qué hay aquí

El modelo analítico completo del escenario: una base `TurismoDW` en SQL Server con modelo estrella, alimentada por un ETL que integra las cuatro fuentes del proyecto, y el modelo semántico de Power BI que la consume.

```
Requerimiento del enunciado                                    Dónde está
─────────────────────────────────────────────────────────────  ────────────────────────────
Crear base analítica y modelo estrella                         04-sqlserver/40, 42
Cargar información desde PostgreSQL y MongoDB                  05-etl/run_etl.py
Dashboard PBI conectado al modelo de alta disponibilidad       06-powerbi/ + 00-docs/04
```

---

## Estructura

| Carpeta | Contenido |
|---|---|
| `00-docs/` | Arquitectura y justificación del ETL, diccionario del modelo, **contrato para el Integrante 2**, guía de Power BI con el procedimiento de failover |
| `01-postgres/` | Generador de volumen (2 M reservas), verificación del origen, script de limpieza, y el DDL/CRUD original de las semanas 1–2 |
| `02-mongodb/` | Siembra de reseñas e interacciones web, verificación |
| `03-archivos/` | Generador de las fuentes JSON (RF-10) y XML (RF-11), más los archivos generados |
| `04-sqlserver/` | Los 7 scripts de la base analítica, en orden 40 → 46 |
| `05-etl/` | Paquete Python del ETL y su orquestador |
| `06-powerbi/` | Proyecto PBIP: modelo semántico en TMDL (17 tablas, 26 relaciones, 52 medidas DAX) y lienzo en PBIR (6 páginas, 56 visuales), más el catálogo de medidas |
| `99-setup/` | Preparación de la instancia y **migración a Developer Edition** |

---

## Ejecución completa, en orden

```powershell
# 0. Preparar la instancia (una vez, como Administrador)
.\99-setup\00-setup-admin.ps1

# 1. Origen relacional: escalar a volumen productivo
psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 01-postgres\10-generador-volumen.sql
psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 01-postgres\11-verificacion-origen.sql

# 2. Origen NoSQL
python 02-mongodb\20-seed_resenas.py --limpiar
mongosh --quiet --file 02-mongodb\21-verificacion-mongo.js

# 3. Fuentes de archivo
python 03-archivos\30-gen_json_xml.py

# 4. Base analítica
sqlcmd -S TURISMODW -E -C            -i 04-sqlserver\40-crear-basedatos.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\41-esquema-staging.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\42-esquema-estrella.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\43-etl-control.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\44-transformacion.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\45-vistas-powerbi.sql

# 5. ETL
pip install -r 05-etl\requirements.txt
python 05-etl\run_etl.py

# 6. Validación
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\46-validacion-consistencia.sql

# 7. Reporte (sólo si hay que regenerarlo; ya viene armado en el entregable)
python 06-powerbi\60-generar-pbip.py      # modelo semántico: tablas, relaciones, medidas
python 06-powerbi\61-generar-reporte.py   # lienzo: 6 páginas y 56 visuales
#   luego abrir 06-powerbi\TurismoDW.pbip en Power BI Desktop
```

Toda la configuración vive en `05-etl/.env`. Para apuntar a otra instancia sólo cambia `SQL_SERVIDOR`.

---

## Volumen del modelo

| Origen | Contenido |
|---|---|
| PostgreSQL 15 @5433 · `turismo` | 2 000 005 reservas · 1 700 004 líneas de habitación · 2 680 006 líneas de tour · 50 005 clientes · 200 hoteles · 400 tours · 150 paquetes · periodo 2021-2026 |
| MongoDB @27017 · `turismo_nosql` | 500 000 reseñas · 1 500 000 interacciones web |
| JSON (RF-10) | 6 000 preferencias en 3 lotes |
| XML (RF-11) | 150 paquetes en 2 documentos |

Un ~2 % de los registros JSON y XML es inválido **a propósito**: sin ellos `etl.Error` quedaría vacío y no habría evidencia de que la validación de RF-15 funciona.

---

## Estado de la infraestructura

**Pendiente y bloqueante: instalar SQL Server Developer Edition.** Nadie lo ha hecho todavía.

Estado verificado de la máquina:

| Instancia | Edición | Servicio |
|---|---|---|
| `MSSQLSERVER` | Enterprise Evaluation | **Detenida** (licencia vencida) |
| `SQLEXPRESS` | Express | Corriendo |
| `SQLEXPRESS01` | Express | Corriendo |
| `SQLEXPRESS02` | Express | Corriendo |
| Developer Edition | — | **No instalada** |

`MSSQLSERVER` se instaló el **1 de agosto de 2025**; la licencia Evaluation caducó a los 180 días, el **28 de enero de 2026**, y el servicio ya no arranca. Las tres Express **sólo pueden ser testigo** de Mirroring, nunca principal ni espejo.

Por eso el modelo analítico y el ETL se construyeron y validaron sobre `.\SQLEXPRESS`, que estaba corriendo y no exige privilegios de administrador. Ahí funciona todo salvo el Mirroring y el tope de 10 GB.

Para la entrega final hay que migrar a **SQL Server 2022 Developer Edition** — gratuita, funcionalidad idéntica a Enterprise y sin caducidad. Procedimiento completo, incluida la configuración de Mirroring con las dos instancias Developer y `SQLEXPRESS` como testigo, en `99-setup/01-instalar-developer.md`.

Migrar no repite trabajo: `40-crear-basedatos.sql` detecta la edición y ajusta los tamaños de archivo solo, y `00-setup-admin.ps1` recibe la instancia por parámetro (`-Instancia DW`). Basta cambiar `SQL_SERVIDOR` en `05-etl/.env` y volver a correr la secuencia.

---

## Para los demás integrantes

| Integrante | Qué necesita de aquí |
|---|---|
| **2** — filegroups, particionamiento, índices | `00-docs/03-contrato-integrante2.md`: clave de partición acordada, límites sugeridos, 5 consultas testigo y qué no tocar |
| **3** — alta disponibilidad | `99-setup/01-instalar-developer.md` §6: scripts de Mirroring listos, con los 6 archivos de datos en el `MOVE` |
| **4** — rendimiento y documentación | `etl.Etapa` (tiempos por etapa), Query Store activo, `46-validacion-consistencia.sql` (22 pruebas de consistencia) |
