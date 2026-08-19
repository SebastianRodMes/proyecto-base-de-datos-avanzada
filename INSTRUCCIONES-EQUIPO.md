# Instrucciones para el equipo

**ITI-821 Bases de Datos Avanzadas · Escenario 8: Turismo Inteligente · Semana 3**
Entregado por **Alex Herrera** (Integrante 1 — ingreso de datos al modelo analítico y reporte PBI)

---

## Estado del proyecto de un vistazo

Qué está hecho y qué no, para que nadie tenga que deducirlo leyendo el documento entero.

| | Estado | Responsable |
|---|---|---|
| Base analítica `TurismoDW` con modelo estrella | **Hecho** — creada y poblada | Int. 1 |
| ETL desde PostgreSQL, MongoDB, JSON y XML | **Hecho** — 22 de 22 pruebas en OK | Int. 1 |
| Modelo semántico de Power BI (52 medidas DAX) | **Hecho** — generado | Int. 1 |
| Lienzo del reporte (6 páginas, 56 visuales) | **Generado, sin confirmar** — falta abrirlo en Power BI Desktop | Int. 1 |
| **Instalar SQL Server Developer Edition** | **PENDIENTE — bloquea al Integrante 3** | quien tenga la máquina |
| Filegroups por año, particionamiento e índices | Pendiente | Int. 2 |
| Mirroring y prueba de falla | Bloqueado hasta que exista Developer | Int. 3 |
| Documento final y bitácora | Pendiente | Int. 4 |

---

## El bloqueo: falta instalar Developer Edition

**Sigue pendiente. Nadie lo ha hecho todavía.** Es el primer paso del equipo, antes que cualquier otra cosa.

Estado verificado de la máquina de laboratorio:

```
MSSQLSERVER    Enterprise Evaluation Edition   DETENIDA (licencia vencida)
SQLEXPRESS     Express Edition                 corriendo
SQLEXPRESS01   Express Edition                 corriendo
SQLEXPRESS02   Express Edition                 corriendo
```

`MSSQLSERVER` se instaló el **1 de agosto de 2025**. La licencia Evaluation caduca a los 180 días: venció el **28 de enero de 2026** y el servicio ya no arranca.

Las otras tres son **Express**, y Express **sólo puede ser testigo** de Database Mirroring — nunca principal ni espejo. Con lo que hay instalado hoy, **el Mirroring es imposible**.

La salida es **SQL Server 2022 Developer Edition**: gratuita, funcionalidad idéntica a Enterprise, sin caducidad. Procedimiento completo en `99-setup/01-instalar-developer.md`.

> **Entonces, ¿cómo es que el resto sí está hecho?** El modelo analítico y el ETL se construyeron y validaron sobre `.\SQLEXPRESS`, que estaba corriendo y no exige privilegios de administrador. Ahí funciona todo igual salvo el Mirroring y el tope de 10 GB por base. Migrar a Developer es cambiar `SQL_SERVIDOR` en `05-etl/.env` y volver a correr la secuencia: `40-crear-basedatos.sql` detecta la edición y ajusta los tamaños de archivo por su cuenta.

---

## Qué recibís

Una base analítica `TurismoDW` en SQL Server con modelo estrella, un ETL que la alimenta desde las cuatro fuentes del escenario, y el modelo semántico de Power BI que la consume.

| | |
|---|---|
| Reservas en el modelo | 2 000 005 (2021–2026) |
| Filas que atraviesan el ETL | 8 488 093 |
| Tablas del modelo estrella | 8 dimensiones + 6 hechos |
| Medidas DAX | 52 |
| Páginas y visuales del reporte | 6 páginas, 56 visuales |
| Pruebas de consistencia automatizadas | 22 (todas en OK) |

Documento de traspaso completo, con diagramas y explicaciones: **`00-docs/Traspaso-TurismoDW.html`** (abrilo con doble clic en cualquier navegador).

---

## Puesta en marcha, una sola vez

Si vas a levantar el proyecto en tu propia máquina:

```powershell
# 1. Dependencias de Python
pip install -r 05-etl\requirements.txt

# 2. Configuración: copiá el ejemplo y ajustá lo que difiera
copy 05-etl\.env.example 05-etl\.env
#    SQL_SERVIDOR  -> la instancia donde vas a crear el DW
#    PG_*          -> tu instancia de PostgreSQL

# 3. Preparar la instancia de SQL Server (como Administrador)
.\99-setup\00-setup-admin.ps1
```

Después, la secuencia completa está en `README.md`, sección «Ejecución completa, en orden».

**Requisitos:** PostgreSQL 15+, MongoDB, SQL Server 2022 (Developer), Python 3.11, y las utilidades de línea de comandos de SQL Server (`sqlcmd` y `bcp`, que vienen con el ODBC Driver 17/18).

---

# Integrante 2 — Filegroups, particionamiento e índices

**Tu documento:** `00-docs/03-contrato-integrante2.md` (leelo completo, tiene el detalle)

## Lo que ya está hecho de tu lado

La base viene con **cinco filegroups por propósito**, no por tamaño:

| Filegroup | Contiene |
|---|---|
| `PRIMARY` | Sólo metadatos del sistema |
| `FG_DIM` | Las 8 dimensiones y las tablas de control del ETL |
| `FG_FACT` | Las 6 tablas de hechos, en 2 archivos. Es el filegroup por defecto |
| `FG_STG` | Staging del ETL (volátil, se trunca en cada corrida) |
| `FG_IDX` | Índices no agrupados |

Los archivos están en `D:\DB\mssql\TurismoDW\data\`, fuera de `C:\Program Files`.

## Lo que es tuyo

Los **filegroups por rango de año**, la **función y el esquema de partición**, y **todos los índices de tuning**. No los creé porque dependen de cómo decidas particionar.

## Clave de partición acordada

```
dw.FactReserva.FechaInicioKey   INT   -- formato yyyymmdd
```

Cuatro razones: es la columna por la que filtra todo el dashboard, reparte parejo entre 2021 y 2026, ocupa 4 bytes y se lee al depurar, y permite archivar por año con `SWITCH PARTITION`.

Límites sugeridos:

```sql
CREATE PARTITION FUNCTION pf_TurismoAnio (int)
AS RANGE RIGHT FOR VALUES
    (20210101, 20220101, 20230101, 20240101, 20250101, 20260101, 20270101);
```

`RANGE RIGHT` deja cada límite como primer valor de su partición, que es lo correcto con fechas.

## Cinco cosas que tenés que saber

1. **Las tablas de hechos vienen sin índices no agrupados, a propósito.** Así tu comparación «antes y después» parte de una línea base limpia. Si hubiera dejado índices de tuning, tus mediciones vendrían contaminadas.

2. **No borres los índices `UQ_*_Negocio`.** No son tuning: son lo que impide que una segunda corrida del ETL duplique filas.

3. **El Query Store ya está activo** (modo lectura-escritura, intervalos de 15 minutos, hasta 2 GB). Tenés el histórico de planes y duraciones sin capturarlo a mano.

4. **Power BI consume las vistas `dw.vw_*`, no las tablas.** Es deliberado: podés reparticionar y reconstruir índices sin que el `.pbix` se entere. Si necesitás cambiar la definición de una vista, avisame antes.

5. **El ETL sigue funcionando después de que particiones.** `etl.usp_CargarHechos` usa `TRUNCATE TABLE`, que funciona sobre tablas particionadas.

## Tus consultas testigo

El contrato trae **5 consultas** que son las que el dashboard ejecuta de verdad. Capturá el plan y el `SET STATISTICS IO, TIME ON` de cada una **antes** de tocar nada, y repetí después. Cubren: eliminación de particiones, el KPI de ocupación, el ranking de tours, el perfil del visitante y la tendencia mensual completa.

## Tu espacio en el dashboard

La **página 6 del reporte** tiene un bloque reservado para tus resultados de particionamiento e índices, como pide el enunciado. Pasame los números en una tabla y los conecto, o armá la sección vos mismo sobre el mismo `.pbix`.

---

# Integrante 3 — Alta disponibilidad y prueba de recuperación

**Tu documento:** `99-setup/01-instalar-developer.md`, sección 6

## Tu primer paso NO es el Mirroring

Es **instalar dos instancias SQL Server 2022 Developer Edition**. Sin eso no hay nada que configurar. Releé el bloqueo al inicio de este documento.

Arquitectura objetivo:

```
   BOSGAME-WINTP\DW          <──mirroring──>   BOSGAME-WINTP\MIRROR
   Developer 2022                              Developer 2022
   PRINCIPAL  · puerto 5022                    ESPEJO · puerto 5023
              └──────────────┬─────────────────┘
                   BOSGAME-WINTP\SQLEXPRESS
                   TESTIGO · puerto 5024        <- ya instalada, se reutiliza
```

El testigo es lo que habilita el **failover automático** en modo alta seguridad. Express sirve para ese rol, así que las instancias que ya existen no se desperdician.

## Lo que ya está resuelto de tu lado

- La base **nace en modelo de recuperación `FULL`**, que es prerrequisito de Mirroring. No hay que cambiarlo.
- El **alias de cliente SQL `TURISMODW`** está diseñado para que, tras el failover, se repunte el alias y **ni el ETL ni el `.pbix` se toquen**. El script de repunte está en `00-docs/04-guia-powerbi.md`, sección 6.
- **`dw.vw_EstadoSistema`** ya expone rol, estado, socio y testigo del mirroring. Es lo que alimenta la página 6 del dashboard, o sea la evidencia visual de tu trabajo.
- Los scripts de **backup, restore, endpoints y permisos** están escritos en tu documento.

## Los dos detalles donde esto suele fallar

**1. El `RESTORE` en el espejo necesita SIETE cláusulas `MOVE`.**

La base tiene cinco filegroups repartidos en seis archivos de datos, más el log. El ejemplo de `Mirroring.zip` asume un solo archivo de datos; si lo copiás tal cual, el restore falla.

```sql
RESTORE DATABASE TurismoDW
  FROM DISK = '...\TurismoDW_full.bak'
  WITH NORECOVERY,
       MOVE 'TurismoDW_sys'    TO 'D:\DB\mssql\Mirror\TurismoDW_sys.mdf',
       MOVE 'TurismoDW_dim01'  TO 'D:\DB\mssql\Mirror\TurismoDW_dim01.ndf',
       MOVE 'TurismoDW_fact01' TO 'D:\DB\mssql\Mirror\TurismoDW_fact01.ndf',
       MOVE 'TurismoDW_fact02' TO 'D:\DB\mssql\Mirror\TurismoDW_fact02.ndf',
       MOVE 'TurismoDW_stg01'  TO 'D:\DB\mssql\Mirror\TurismoDW_stg01.ndf',
       MOVE 'TurismoDW_idx01'  TO 'D:\DB\mssql\Mirror\TurismoDW_idx01.ndf',
       MOVE 'TurismoDW_log'    TO 'D:\DB\mssql\Mirror\TurismoDW_log.ldf';
```

**2. El `GRANT CONNECT ON ENDPOINT`.**

Cada instancia corre bajo una cuenta de servicio virtual distinta (`NT Service\MSSQL$DW`, `NT Service\MSSQL$MIRROR`, `NT Service\MSSQL$SQLEXPRESS`). Sin ese permiso, la sesión de mirroring queda en estado `DISCONNECTED` **sin decir por qué**. `Mirroring.zip` lo menciona como «GRANT Connect Mirroring» y es exactamente ese paso.

## La prueba de falla, coordinada conmigo

El guion completo está en `00-docs/04-guia-powerbi.md`, sección 6. Resumen:

1. Refrescamos el `.pbix` y capturamos: nodo activo, reservas, ingresos, % ocupación, hora.
2. Provocás la caída o ejecutás `ALTER DATABASE TurismoDW SET PARTNER FAILOVER;`
3. Observamos que **el dashboard sigue mostrando todos sus visuales** — ésa es la continuidad de servicio del modo Import.
4. Repuntamos el alias al espejo (un `Set-ItemProperty` en dos ramas del registro).
5. Refrescamos: la página 6 muestra el **nuevo nombre de nodo** y la página 1 **los mismos totales**.
6. La diferencia de hora es el **tiempo aproximado de recuperación** que pide el enunciado.

Que los totales coincidan antes y después es la «validación de datos antes y después del reemplazo del nodo» del entregable.

---

# Integrante 4 — Rendimiento, consistencia y documentación

**Tu script principal:** `04-sqlserver/46-validacion-consistencia.sql`

## Tres insumos que ya existen — no hay que fabricarlos

**1. Tiempos por etapa del ETL** — tabla `etl.Etapa`

Cada corrida deja duración y filas de las seis etapas. Es tu línea base de rendimiento del proceso de carga.

```sql
SELECT Nombre, ObjetoDestino, Estado, DuracionSegundos, Filas
FROM   etl.Etapa
WHERE  EjecucionId = (SELECT MAX(EjecucionId) FROM etl.Ejecucion)
ORDER BY Secuencia;
```

**2. Query Store activo** sobre la base, con planes y duraciones de todas las consultas del dashboard.

```sql
SELECT TOP (20)
    qt.query_sql_text,
    rs.avg_duration / 1000.0  AS ms_promedio,
    rs.avg_logical_io_reads   AS lecturas_logicas,
    rs.count_executions
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt   ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p          ON p.query_id = q.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
ORDER BY rs.avg_duration DESC;
```

**3. Veintidós pruebas de consistencia** automatizadas, con veredicto `OK` / `REVISAR` por prueba y un veredicto global.

```powershell
# Primero sacá los valores esperados del origen
psql -h 127.0.0.1 -p 5433 -U postgres -d turismo -f 01-postgres\11-verificacion-origen.sql
mongosh --quiet --file 02-mongodb\21-verificacion-mongo.js

# Después contrastá contra el DW (los números salen de los dos anteriores)
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\46-validacion-consistencia.sql `
       -v ReservasOrigen=2000005 MontoOrigen=... ResenasOrigen=500000 InteraccionesOrigen=1500000 `
       -o 00-docs\05-evidencias\validacion-consistencia.txt
```

## Qué cubren esas pruebas

| Bloque | Qué verifica |
|---|---|
| **Completitud** | Conteos y sumas del DW contra PostgreSQL y MongoDB |
| **Integridad** | Cero huérfanos, cero claves sin resolver, cero FK no confiables |
| **Unicidad** | Que la recarga no haya duplicado hechos |
| **Coherencia de negocio** | Ocupación ≤ 100 %, noches no negativas, calificaciones en 1–5, cobertura de los seis años |

El script también imprime un bloque de **KPI de referencia calculados en T-SQL**, pensado para compararlos tarjeta por tarjeta contra Power BI.

> Si un número del dashboard no coincide con el de SQL, casi siempre es una de dos cosas: un filtro de página que quedó activo en el `.pbix`, o una medida que promedia porcentajes en vez de dividir sumas. Por eso `% Ocupación hotelera` está escrita como `DIVIDE(SUM(ocupadas), SUM(disponibles))` y nunca como un promedio.

## Para la documentación y los diagramas

| Necesitás | Está en |
|---|---|
| Diagrama de arquitectura y flujo del ETL | `00-docs/01-arquitectura-etl.md` |
| Justificación de la tecnología ETL (entregable 6) | `00-docs/01-arquitectura-etl.md`, sección 4 |
| Diccionario del modelo y linaje campo → fuente | `00-docs/02-diccionario-modelo-estrella.md` |
| Cobertura de RF-01 a RF-15 y RNF-05 | `00-docs/02`, sección final |
| Tiempos de carga medidos | `00-docs/Traspaso-TurismoDW.html`, sección 2 |

## Un dato para la bitácora

La validación **ya detectó y corrigió un error real**, y vale la pena contarlo en el documento porque es justo lo que una prueba de coherencia de negocio debe hacer.

La primera carga daba **255 % de ocupación hotelera**, físicamente imposible. El síntoma fue cambiando de forma mientras se investigaba —255 %, luego picos diarios del 163 %, luego diez destinos con exactamente 154 547 reservas cada uno— porque eran manifestaciones distintas del mismo defecto.

**La causa raíz:** el multiplicador del muestreo compartía un factor con el módulo.

```
40503 mod 150 = 3   ->   (i * 40503) mod 150  solo produce multiplos de 3
```

Es decir, **sólo 50 de los 150 paquetes se elegían jamás**, y con ellos dos tercios de las ciudades y de los hoteles quedaban sin una sola reserva. La demanda de 2 millones de reservas se apilaba sobre un tercio del catálogo. Se corrigió muestreando con `random()` —como ya hacía el calendario, que siempre funcionó bien— en vez de aritmética modular sobre el contador.

Un segundo defecto, independiente: **la capacidad instalada variaba 10 veces entre hoteles mientras la demanda se repartía pareja**, así que los hoteles chicos quedaban sobrevendidos y los grandes vacíos. Se resolvió dimensionando cada hotel a su demanda pico (paso 6b del generador): capacidad = pico diario ÷ 0,82. Es como se construye un hotel real, y de paso cierra una incoherencia con RF-07 sobre evitar sobreventas.

**Resultado final:** 150 de 150 paquetes usados, 31 de 31 ciudades y 200 de 200 hoteles con demanda, ranking de destinos con curva realista, ocupación media **30 %**, pico diario **82 %**, **cero** días-hotel por encima de la capacidad, 22 pruebas en `OK`.

### Por qué esto vale para el documento

El defecto más caro **no produjo ningún error**. Produjo datos sesgados. Todos los conteos daban bien —2 000 005 reservas, cero huérfanos, integridad referencial perfecta, las 22 pruebas en verde— y aun así el modelo mentía sobre el negocio que representa.

Sólo apareció al mirar el *ranking de destinos* del dashboard y notar diez ciudades con la misma cifra exacta. Validar conteos e integridad no alcanza: hay que mirar la salida y preguntarse si se parece a la realidad.

---

## Contacto y convenciones

- Todo el código y los scripts están comentados **explicando el porqué**, no el qué. Si algo parece una decisión rara, el comentario dice la razón.
- La configuración vive en un solo lugar: `05-etl/.env`. No hay cadenas de conexión repartidas por los scripts.
- Los generadores usan **semilla fija** (`SEMILLA=8218`), así que todos obtenemos exactamente el mismo conjunto de datos.
- Si cambiás algo que otro integrante consume (nombres de tablas de `dw`, definición de vistas, el modelo de recuperación), avisá antes.

Cualquier duda sobre el modelo, el ETL o el reporte, escribime.

— **Alex Herrera**, Integrante 1
