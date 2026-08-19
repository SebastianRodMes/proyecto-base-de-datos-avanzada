# Arquitectura de la solución y plan de integración de datos

**ITI-821 Bases de Datos Avanzadas · Escenario 8: Turismo Inteligente · Semana 3**
**Integrante 1: Alex Herrera** — ingreso de datos al modelo analítico y despliegue en Power BI

---

## 1. Problema que resuelve esta arquitectura

El enunciado de la Semana 3 parte de seis problemas concretos. Los que corresponden a este integrante son:

| Problema del enunciado | Cómo lo resuelve esta arquitectura |
|---|---|
| «Las consultas históricas afectan las operaciones» | Se separa físicamente la carga analítica: PostgreSQL queda sólo con la operación, SQL Server recibe todo lo histórico. El dashboard nunca toca la base transaccional. |
| «No existe una estructura analítica ni separación física» | `TurismoDW` con modelo estrella, en filegroups propios y archivos en un volumen distinto al de la base operacional. |
| «No existe un dashboard que interactúe con el modelo de alta disponibilidad» | Power BI se conecta al alias `TURISMODW`, no al nombre físico del nodo; tras el failover el reporte sigue funcionando sin editarse. |

---

## 2. Diagrama de la solución

```
┌──────────────────────── ORÍGENES (on-premise) ────────────────────────┐
│                                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐  ┌───────────┐    │
│  │ PostgreSQL15 │  │  MongoDB     │  │  JSON     │  │   XML     │    │
│  │  :5433       │  │  :27017      │  │  (RF-10)  │  │  (RF-11)  │    │
│  │  'turismo'   │  │'turismo_nosql'│ │           │  │           │    │
│  ├──────────────┤  ├──────────────┤  ├───────────┤  ├───────────┤    │
│  │ 13 tablas    │  │ resenas      │  │ preferen- │  │ catálogo  │    │
│  │ 2.0 M reservas│ │   500 k      │  │ cias de   │  │ de paque- │    │
│  │ 1.7 M hab.   │  │ interacciones│  │ visitante │  │ tes       │    │
│  │ 2.7 M tours  │  │  1.5 M       │  │  6 000    │  │   150     │    │
│  └──────┬───────┘  └──────┬───────┘  └─────┬─────┘  └─────┬─────┘    │
└─────────┼─────────────────┼────────────────┼──────────────┼──────────┘
          │ psycopg2        │ pymongo        │ json         │ lxml
          │ cursor servidor │ batch_size     │              │ iterparse
          ▼                 ▼                ▼              ▼
      ┌───────────────────────────────────────────────────────────┐
      │   E X T R A C C I Ó N   ->   archivos planos delimitados   │
      │   D:\DB\mssql\TurismoDW\etl\*.dat                          │
      └───────────────────────────┬───────────────────────────────┘
                                  │ bcp  (carga masiva, log mínimo)
                                  ▼
┌───────────────────────── SQL SERVER 2022 ────────────────────────────┐
│                        Base analítica TurismoDW                       │
│                                                                        │
│   ┌──────────────┐   validación    ┌──────────────────────────────┐  │
│   │  esquema stg │  ─────RF-15───► │       esquema dw             │  │
│   │  (FG_STG)    │                 │  Modelo estrella (FG_DIM /   │  │
│   │  16 tablas   │  rechazos ──┐   │  FG_FACT)                    │  │
│   │  todo nvarchar│             │   │  8 dimensiones + 6 hechos    │  │
│   └──────────────┘             │   └──────────────┬───────────────┘  │
│                                 ▼                  │                   │
│   ┌────────────────────────────────────┐          │  vistas dw.vw_*   │
│   │  esquema etl  (RNF-05)             │          │                   │
│   │  Ejecucion / Etapa / Error         │          ▼                   │
│   └────────────────────────────────────┘   ┌──────────────┐          │
│                                              │  Power BI    │          │
│   Recovery FULL ──► Mirroring (Integrante 3) │  Import mode │          │
└──────────────────────────────────────────────┴──────┬───────┴─────────┘
                                                       │
                                     alias SQL «TURISMODW» (repunteable)
```

---

## 3. Flujo del ETL, etapa por etapa

| # | Etapa | Fuente | Qué hace | Dónde queda registrada |
|---|---|---|---|---|
| 1a | `EXTRAER_PG` | PostgreSQL | 11 tablas → archivos `.dat` con cursor del lado del servidor | `etl.Etapa` |
| 1b | `EXTRAER_MONGO` | MongoDB | 2 colecciones aplanadas a filas | `etl.Etapa` |
| 1c | `EXTRAER_ARCHIVOS` | JSON + XML | 3 lotes JSON + 2 documentos XML | `etl.Etapa` |
| 2 | `TRUNCAR_STG` / `CARGAR_STG` | — | `bcp` carga cada `.dat` en `stg.*` | `etl.Etapa` |
| 3 | `VALIDAR` | — | RF-15: obligatorios, formatos, duplicados, rangos | `etl.Error` |
| 4a | `CARGAR_DW_DIM` | — | `MERGE` SCD-1 sobre 8 dimensiones | `etl.Etapa` |
| 4b | `CARGAR_DW_HECHOS` | — | `TRUNCATE` + `INSERT` de 5 tablas de hechos | `etl.Etapa` |
| 5 | `CARGAR_DW_OCUPACION` | — | Explota estadías → `FactOcupacionDiaria` | `etl.Etapa` |
| 6 | `VERIFICAR_INTEGRIDAD` | — | Revalida FK `WITH CHECK` + `UPDATE STATISTICS` | `etl.Etapa` |

Orquestador: `05-etl/run_etl.py`.

---

## 4. Justificación de la tecnología ETL (entregable 6 del proyecto)

Se evaluaron cinco opciones contra las restricciones reales del laboratorio:

| Opción | Veredicto | Razón |
|---|---|---|
| **SSIS** (SQL Server Integration Services) | Descartada | No está instalado y no viene incluido con la instancia disponible. Instalarlo requiere el instalador completo de SQL Server más Visual Studio con SSDT. |
| **Linked Servers + OPENQUERY** | Descartada | Requiere un proveedor OLE DB/ODBC para PostgreSQL y otro para MongoDB. El inventario de la máquina sólo tiene los drivers de SQL Server, MySQL y Access. Además, un linked server no ofrece bitácora de errores por registro, que RNF-05 exige. |
| **Azure Data Factory** | Descartada | Es un servicio en la nube. El enunciado especifica explícitamente una solución **on-premise**. |
| **Pentaho / Talend** | Descartada | Instalación pesada (JRE + IDE), configuración por GUI que no se puede versionar en el repositorio del equipo, y curva de aprendizaje que no aporta al objetivo del curso. |
| **Python 3.11 + `bcp`** | **Seleccionada** | Ver abajo. |

### Por qué Python + bcp

1. **Ya está todo instalado.** `psycopg2`, `pymongo`, `lxml`, `pyodbc` y las utilidades de línea de comandos de SQL Server (`bcp`, `sqlcmd`) están presentes. Cero instalación adicional para el resto del equipo.
2. **Es el único conector que cubre las cuatro fuentes.** PostgreSQL, MongoDB, JSON y XML con una sola pila.
3. **Versionable y reproducible.** El proceso es código de texto que va al repositorio junto con los scripts SQL. Un paquete SSIS o un job de Pentaho son binarios/XML generados que nadie revisa en un diff.
4. **`bcp` usa la ruta de carga masiva del motor.** Es la diferencia entre cargar 2 millones de filas en menos de un minuto o en más de una hora. Un `INSERT` fila a fila desde Python envía cada fila como parámetro por ODBC; `bcp` escribe directamente en las páginas de datos con registro mínimo en el log.
5. **La transformación ocurre dentro del motor.** Python sólo mueve bytes; los `MERGE` y agregaciones corren como procedimientos almacenados, donde están los datos y los índices. Arrastrar 2 millones de filas a memoria de Python para transformarlas sería el error de diseño clásico.

### Patrón: E → archivo → bcp → staging → MERGE → estrella

```
  Origen  ──extract──►  *.dat  ──bcp──►  stg.*  ──T-SQL──►  dw.*
          (Python)              (motor)          (motor)
```

El archivo plano intermedio parece un rodeo, pero es lo que permite usar la carga masiva. El costo es disco temporal —barato— y a cambio se gana un orden de magnitud en velocidad.

---

## 5. Decisiones de diseño y sus razones

### 5.1 Staging con todas las columnas `nvarchar` y sin restricciones

Si el staging fuera fuertemente tipado, una sola fila mal formada abortaría el lote completo de `bcp` y se perdería la traza de qué venía mal. Con `nvarchar` todo entra, y la conversión real ocurre después con `TRY_CONVERT` dentro del motor, donde un valor no convertible se vuelve `NULL` y se registra en `etl.Error` con el dato original intacto. Eso es exactamente lo que pide RNF-05.

### 5.2 Dimensiones con `MERGE`, hechos con recarga completa

Las dimensiones son pequeñas (miles de filas) y cambian poco: `MERGE` SCD-1 es barato y preserva las claves subrogadas, que es lo que mantiene válidos los hechos ya cargados.

Los hechos son millones de filas: comparar fila por fila costaría más que volver a escribirlas. Además, la recarga completa elimina el riesgo de dejar hechos huérfanos si el origen borró registros.

### 5.3 `FactOcupacionDiaria` como tabla derivada

«Porcentaje de ocupación hotelera» es el primer KPI del escenario. Una reserva de 5 noches ocupa 5 días distintos, así que hay que explotar la estadía en días. Hacerlo en DAX sobre 2 millones de filas colapsaría el reporte; hacerlo una vez en el ETL cuesta segundos y deja una tabla de ~400 000 filas que el dashboard consulta al instante.

La tabla guarda **numerador y denominador por separado** (`HabitacionesOcupadas`, `HabitacionesDisponibles`), no el porcentaje. Un porcentaje almacenado no se puede promediar correctamente al agregar por mes o por país; la división debe hacerse siempre al final, sobre las sumas.

### 5.4 Claves foráneas deshabilitadas durante la carga

`NOCHECK CONSTRAINT ALL` antes de cargar y `WITH CHECK CHECK CONSTRAINT ALL` después. Validar 2 millones de filas una a una durante el `INSERT` es varias veces más caro que validar el conjunto completo de una vez al final. Si algo quedó mal, la revalidación falla y la carga no se da por buena.

### 5.5 Registros inválidos inyectados a propósito

Los generadores de JSON y XML emiten un 2 % de registros defectuosos (identificación vacía, correo sin dominio, presupuesto negativo, precio no numérico). Sin ellos, `etl.Error` quedaría vacío y no habría forma de demostrar que la validación de RF-15 funciona. Son la evidencia, no un descuido.

### 5.6 Alias de cliente SQL en lugar del nombre del servidor

Todo —el ETL y el `.pbix`— apunta a `TURISMODW`, que es un alias registrado en `HKLM\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo`. Tras el failover del Integrante 3, se repunta el alias al nodo espejo y nada más se toca. Sin esto, cada failover obligaría a editar la fuente de datos del reporte a mano.

---

## 6. Trazabilidad de la fuente al modelo (RNF-05)

Cada fila de hechos lleva:

- `EjecucionIdCarga` → apunta a `etl.Ejecucion`, que dice cuándo, en qué nodo y con qué usuario se cargó.
- La clave de negocio del origen (`ReservaId`, `ResenaId`, `InteraccionId`) → permite volver al registro original en PostgreSQL o MongoDB.

Cada registro rechazado queda en `etl.Error` con: fuente, archivo, número de registro, campo, regla violada, descripción y **el payload original completo**. La cadena queda cerrada en ambos sentidos.

---

## 7. Cómo ejecutar todo, en orden

```powershell
# 0. Preparación de la instancia (una sola vez, como Administrador)
.\99-setup\00-setup-admin.ps1

# 1. Escalar el origen relacional a volumen productivo
psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 01-postgres\10-generador-volumen.sql
psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 01-postgres\11-verificacion-origen.sql

# 2. Sembrar MongoDB
python 02-mongodb\20-seed_resenas.py --limpiar
mongosh --quiet --file 02-mongodb\21-verificacion-mongo.js

# 3. Generar los archivos JSON y XML
python 03-archivos\30-gen_json_xml.py

# 4. Crear la base analítica
sqlcmd -S TURISMODW -E -C -i 04-sqlserver\40-crear-basedatos.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\41-esquema-staging.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\42-esquema-estrella.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\43-etl-control.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\44-transformacion.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\45-vistas-powerbi.sql

# 5. Ejecutar el ETL
python 05-etl\run_etl.py

# 6. Validar la consistencia
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\46-validacion-consistencia.sql

# 7. Abrir el reporte
#    06-powerbi\TurismoDW.pbip  ->  Actualizar  ->  Guardar como .pbix
```

---

## 8. Estado de la infraestructura y plan de cierre

### 8.1 La instancia Enterprise Evaluation está vencida (hecho verificado)

```
MSSQLSERVER · Enterprise Evaluation Edition
Instalada el 1 de agosto de 2025  ·  vigencia 180 días  ·  venció el 28 de enero de 2026
```

No es un riesgo: el servicio no arranca. Por eso la validación de este entregable se hizo sobre `.\SQLEXPRESS`, que ya estaba corriendo y acepta conexiones sin privilegios elevados.

### 8.2 Host provisional vs. host definitivo

| | Provisional (hoy) | Definitivo |
|---|---|---|
| Instancia | `BOSGAME-WINTP\SQLEXPRESS` | `BOSGAME-WINTP\DW` (Developer) |
| Para qué sirve | Validar ETL, modelo estrella y KPIs de punta a punta | Entrega final y Mirroring |
| Limitaciones | 10 GB por base, 1.4 GB de RAM, 4 núcleos, sin Mirroring como principal | Ninguna |

`40-crear-basedatos.sql` **detecta la edición y ajusta los tamaños de archivo solo**: en Express preasigna ~2.6 GB; en Developer, ~7.4 GB. Migrar de un host al otro es cambiar una línea de `05-etl/.env` y volver a correr la secuencia. Nada del trabajo se pierde.

### 8.3 Cierre definitivo de los riesgos

El procedimiento completo está en `99-setup/01-instalar-developer.md`. En resumen: dos instancias **SQL Server 2022 Developer Edition** (gratuita, funcionalidad idéntica a Enterprise, **sin caducidad**) como principal y espejo, con `SQLEXPRESS` de testigo —rol para el que Express sí es válido—. Eso elimina de raíz la caducidad, el límite de 10 GB y la imposibilidad de Mirroring, y deja intactos los scripts de todos los integrantes.

### 8.4 El origen PostgreSQL se reconstruyó

El contenedor Docker de las semanas 1–2 ya no existe en esta máquina (sin contenedor, imagen ni volumen). El origen se reconstruyó en la instancia local **PostgreSQL 15 del puerto 5433** aplicando `turismo_ddl.sql` y `turismo_crud.sql`, de modo que los datos de las semanas anteriores se conservan íntegros, y encima se generó el volumen productivo de 2 millones de reservas.
