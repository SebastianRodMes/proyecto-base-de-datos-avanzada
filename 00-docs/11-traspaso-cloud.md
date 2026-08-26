# Traspaso de la fase cloud — cómo continuar

**ITI-821 · Escenario 8: Turismo Inteligente · Semanas 3 y 4 · Integrante 1: Alex Herrera**

Documento de continuidad. Los documentos `07` a `10` explican **qué se hizo y por qué**; este explica **cómo retomarlo**: cómo reactivar el entorno, qué no tocar, qué falta y de quién es cada pendiente.

> Sigue el precedente de `00-docs/03-contrato-integrante2.md`, el contrato con el que se le entregó el modelo estrella al Integrante 2 en la Semana 1. La idea es la misma: que quien continúe no tenga que reconstruir el contexto preguntando.

---

## 1. Lo primero que hay que entender

**El repositorio no alcanza para reproducir la migración.** Faltan tres cosas a propósito, porque son secretos y no se versionan:

| Qué falta | Dónde vive | Sin eso no podés |
|---|---|---|
| Credenciales de AWS | `.secrets/turismodw-cloud.env` | Correr nada de `07-migracion/` |
| Cadena de conexión de Atlas | `ATLAS_URI` en ese mismo archivo | Migrar ni consultar MongoDB en la nube |
| Configuración cloud del ETL | `05-etl/.env.aws` | Correr el ETL contra la nube |

Los tres están en `.gitignore`. La sección 3 explica cómo volver a tenerlos.

**Lo que sí viene en el repositorio** es todo lo demás: los 12 scripts de `07-migracion/`, las variantes RDS del DDL, los dos scripts de carga incremental, el override de Docker, los cuatro documentos y las 15 evidencias. La migración es reproducible; lo que hay que reponer son las llaves.

---

## 2. Estado en el que quedó todo

### 2.1 Infraestructura en AWS, cuenta `063876841411`, región `us-east-1`

| Recurso | Identificador | Estado al cierre |
|---|---|---|
| RDS for PostgreSQL 16.14 | `turismodw-pg` | **Detenida** (`db.t4g.micro`) |
| RDS for SQL Server 2022 Express | `turismodw-sql` | **Detenida** (`db.t3.small`) |
| Bucket S3 | `turismodw-migracion-063876841411` | Activo, 5 archivos, 3,1 MB |
| Grupo de seguridad | `turismodw-sg` | Activo, abierto a una sola IP |
| Grupo de subredes | `turismodw-subnets` | Activo |
| Rol IAM | `turismodw-s3-role` | Activo |
| Option group | `turismodw-backup-restore` | Activo |
| Usuario IAM | `turismodw-migracion` | Activo |

Detenidas cuestan solo almacenamiento, unos **0,15 USD/día**. Encendidas, unos **0,052 USD/hora**.

> **Aviso que importa.** AWS **reinicia sola** una instancia detenida a los **7 días**. Si el proyecto se deja parado más tiempo, va a empezar a cobrar sin que nadie la haya encendido. Antes de ese plazo: o se vuelve a detener, o se elimina con `78-detener-recursos.ps1 -Eliminar`.

### 2.2 MongoDB Atlas

Cluster **`moviles-II`**, base `turismo_nosql`, región `CENTRAL_US`.

> **Es un cluster compartido con otro proyecto.** No se creó uno nuevo porque el service account de Atlas no tiene el rol de creador de proyectos en la organización, y la capa gratuita admite un solo cluster M0 por proyecto. Se optó por **reusar sin destruir**: se creó la base `turismo_nosql` al lado de la que ya existía y un usuario `turismodw` con `readWrite` **acotado a esa sola base**. Los datos del otro proyecto nunca se tocaron, y revertir es soltar una base.
>
> El precio de esa decisión está en `10-validacion-post-migracion.md`, sección 8: el cupo de 512 MB se cuenta **por cluster**, así que `interacciones_web` entró al 50 %.

### 2.3 Entorno local

Sigue intacto y es la fuente de verdad. **La migración nunca modificó el origen**: ningún script de `07-migracion/` escribe en PostgreSQL, MongoDB ni en el SQL Server local. Todos leen del origen y escriben en el destino.

### 2.4 Qué hay dentro de `.secrets/`

Cuatro archivos. Solo uno lo lee el código; los otros tres son materia prima para regenerarlo.

| Archivo | Quién lo escribe | Quién lo lee | ¿Se regenera? |
|---|---|---|---|
| `turismodw-cloud.env` | `70-provisionar-aws.ps1` | `comun.ps1`, y por él **todos** los scripts `72`–`79` | Sí, volviendo a correr `70` |
| `turismodw-migracion_accessKeys.csv` | La consola de AWS al crear la clave | Nadie: se usó una vez para `aws configure --profile turismodw` | No. Si se pierde, se crea una clave nueva |
| `mongo_account_service` | La consola de Atlas al crear el service account | Nadie automáticamente; es el insumo del cliente de la API de administración | No. Si se pierde, se crea otro service account |
| `atlas-token.json` | Un token OAuth de la API de Atlas, obtenido durante la sesión | Nadie | Sí, y **caduca en 1 hora**. Es descartable |

> **La única pieza indispensable es `turismodw-cloud.env`**, y aun así se regenera corriendo `70`. Lo que **no** se regenera solo es la línea `ATLAS_URI`: hay que volver a pegarla a mano. El script ahora la conserva si ya existe, pero si el archivo se perdió del todo, hay que recuperarla de Atlas.
>
> El perfil de AWS **no vive en el repositorio** sino en `~/.aws/config` y `~/.aws/credentials`, bajo el nombre `turismodw`. Un compañero en otra máquina tiene que crearlo con `aws configure --profile turismodw`.

---

## 3. Cómo reactivar el entorno

Tres escenarios según lo que necesites.

### 3.1 Solo el laboratorio local

```powershell
docker compose -f docker\docker-compose.yml `
               -f docker\docker-compose.override.yml up -d --build
```

**Los dos archivos, siempre.** El override publica PostgreSQL en `15432` y MongoDB en `27018` en vez de los puertos habituales. No es capricho: muchas máquinas tienen servicios nativos de Windows ocupando 5432, 5433 y 27017 sobre IPv4 mientras Docker publica sobre IPv6, y entonces una conexión a `127.0.0.1` habla con el servicio nativo **sin dar ningún error**. Pasó en esta máquina y el ETL leyó 2 000 005 reservas cuando el contenedor tenía 2 000 010.

Verificá que estás leyendo el contenedor y no otra cosa:

```powershell
cd 05-etl
python -c "from etl import extract_postgres; print(extract_postgres.contar_origen()['reserva'])"
```

Debe decir **2 000 010**. Si dice otra cosa, estás conectado a la base equivocada.

> **Si además necesitás el endpoint `localhost,14330`** —el de alta disponibilidad de las semanas 1 y 2, que es a donde apunta `repuntar-powerbi.ps1 -Local`— hay que levantar el perfil `ha`, porque los servicios que lo publican están detrás de `profiles: ["ha"]` en el compose:
>
> ```powershell
> docker compose -f docker\docker-compose.yml `
>                -f docker\docker-compose.override.yml --profile ha up -d
> ```
>
> Sin `--profile ha` ese puerto no lo escucha nadie y Power BI se queda esperando sin un mensaje que lo explique.

### 3.2 Volver a encender la nube que ya existe

Necesitás `.secrets/turismodw-cloud.env`. Si lo tenés:

```powershell
.\07-migracion\78-detener-recursos.ps1 -Iniciar -Esperar
```

Tarda unos minutos. Después, **hay que reabrir la regla del grupo de seguridad para tu IP**, porque `turismodw-sg` solo admite la que se registró al provisionar y las IP domésticas cambian:

```powershell
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
aws ec2 authorize-security-group-ingress --group-id sg-0918cbca9545be043 `
    --protocol tcp --port 1433 --cidr "$ip/32" --profile turismodw
aws ec2 authorize-security-group-ingress --group-id sg-0918cbca9545be043 `
    --protocol tcp --port 5432 --cidr "$ip/32" --profile turismodw
```

Lo mismo con Atlas: **Network Access → Add IP Address**. Sin eso, la conexión no falla con un mensaje claro, se queda esperando hasta agotar el tiempo.

### 3.3 Desde cero, en otra cuenta

Es el escenario del compañero que clona el repositorio. Cinco pasos.

**Paso 1 — Usuario IAM.** En la consola de AWS, IAM → Users → Create user, nombre `turismodw-migracion`, y adjuntarle:

| Política | Para qué |
|---|---|
| `AmazonRDSFullAccess` | Crear y administrar las dos instancias |
| `AmazonS3FullAccess` | Bucket de landing zone y respaldos |
| `AmazonEC2FullAccess` | Grupo de seguridad y consulta de la VPC |
| `IAMFullAccess` | Crear el rol que RDS usa para leer S3 |

Después, Security credentials → Create access key → CLI, y:

```powershell
aws configure --profile turismodw
```

> **DMS no hace falta.** La matriz de herramientas lo descartó: el origen es un laboratorio congelado durante la copia, así que la captura de cambios continua no aporta nada y la instancia de replicación duplicaría el costo.

**Paso 2 — Provisionar.**

```powershell
.\07-migracion\70-provisionar-aws.ps1
```

Genera las contraseñas, las guarda en `.secrets/turismodw-cloud.env` y lanza las dos instancias. Tarda entre 15 y 25 minutos en que queden `available`; el script no bloquea salvo que le pases `-Esperar`.

**Paso 3 — Atlas.** Hay dos caminos.

*Manual:* crear cuenta en `cloud.mongodb.com`, cluster M0 en AWS `us-east-1`, un usuario de base y una regla de acceso por IP. Copiar la cadena de **Connect → Drivers**.

*Por API,* que es como se hizo esta vez: crear un **Service Account** en Atlas (Organization Access → Applications), guardar su Client ID y Client Secret, y usar la API de administración. Si además querés un proyecto propio en vez de compartir cluster, el service account necesita el rol **Organization Project Creator**, que en esta organización **no tiene**: por eso hubo que reusar `moviles-II`.

En cualquier caso, agregá al archivo de secretos:

```
ATLAS_URI=mongodb+srv://turismodw:<clave>@<cluster>.mongodb.net/
```

**Paso 4 — Migrar.** En este orden:

```powershell
.\07-migracion\71-inventario-objetos.ps1     # inventario del origen
.\07-migracion\72-piloto-migracion.ps1       # piloto del 10 %
.\07-migracion\73-migrar-postgres.ps1
.\07-migracion\74-migrar-mongo.ps1
.\07-migracion\74b-archivos-a-s3.ps1
.\07-migracion\75-migrar-dw.ps1
```

`75-migrar-dw.ps1` acepta `-SoloEsquema` y `-SoloDatos` por si hay que repetir una mitad.

**Paso 5 — Validar y repuntar.**

```powershell
.\07-migracion\repuntar-powerbi.ps1
.\07-migracion\77-comparar-local-cloud.ps1
```

Y la validación contra la nube, con los conteos del origen como parámetros:

```powershell
sqlcmd -S "<endpoint>,1433" -U turismoadmin -P "<clave>" -C -N -d TurismoDW `
  -i 07-migracion\76-validacion-post-migracion.sql `
  -v ReservasOrigen=2000011 MontoOrigen=16709505560.28 `
     ResenasOrigen=500002 InteraccionesOrigen=1500002
```

> Los valores de origen **cambian** con cada corrida del ETL incremental. Sacalos siempre del origen en el momento, no de este documento: `01-postgres/11-verificacion-origen.sql` los produce.

### 3.4 Correr el ETL contra la nube

Es el entregable central de la Semana 4 y el paso que menos se documenta solo, porque `config.py` **solo lee `05-etl/.env`**: no hay un interruptor de entorno. Cambiar de destino es cambiar ese archivo.

**Ida:**

```powershell
cd 05-etl
Copy-Item .env .env.local.bak        # respaldá el local ANTES de pisarlo
Copy-Item .env.aws .env
python run_etl.py --modo INCREMENTAL
```

**Vuelta, y no es opcional:**

```powershell
Copy-Item .env.local.bak .env -Force
Remove-Item .env.local.bak
```

> **Si te olvidás de volver**, tu laboratorio local queda apuntando a RDS. La próxima vez que corras el ETL "en local" vas a estar escribiendo en la nube sin darte cuenta, y con las instancias detenidas simplemente va a fallar con un error de red que no dice nada de esto.

`05-etl/.env.aws` no viene en el repositorio. Se arma copiando `05-etl/.env.aws.example` y rellenando cuatro valores desde `.secrets/turismodw-cloud.env`:

| En `.env.aws` | Sale de |
|---|---|
| `PG_HOST` | Endpoint de `turismodw-pg` (`aws rds describe-db-instances`) |
| `PG_PASSWORD` | `RDS_PG_PASSWORD` |
| `SQL_SERVIDOR` | Endpoint de `turismodw-sql` |
| `SQL_PASSWORD` | `RDS_SQL_PASSWORD` |
| `MONGO_URI` | `ATLAS_URI` |

**Lo que ya se probó.** La corrida registrada en `00-docs/05-evidencias/migracion/etl-cloud.txt` es del 25 de agosto y se hizo **sin** `--solo-pg`: ejercitó las tres fuentes contra la nube. 1 258 074 filas leídas en 11m 27s, de ellas 1 249 874 desde Atlas (500 002 reseñas y 749 872 interacciones) y 6 150 desde los archivos JSON y XML. Los 84 rechazos son los esperados y quedaron en `etl.Error`, que es lo que puebla `dw.vw_CalidadDatos`.

La corrida anterior, con `--solo-pg`, no leía de Atlas. Vale la pena decir por qué hicieron falta dos intentos más antes de que Mongo moviera datos: **con `etl.Marca` en el máximo de la fuente, un incremental lee 0 documentos**, así que una corrida "sin `--solo-pg`" a secas ejecuta las etapas de Mongo y archivos pero con cero filas. Para que movieran datos de verdad hubo que limpiar las marcas de `MONGODB` y tocar el `mtime` de los cinco archivos de `03-archivos/entrada`.

> **Y ahí saltó un problema que ya existía.** La clave de negocio de `dw.FactResena` y `dw.FactInteraccionWeb` es el `_id` de MongoDB. Los del DW empiezan en `6a8220` y los de Atlas en `6a8906`: 5,3 días de diferencia en la marca de tiempo del ObjectId. El MongoDB local se regeneró entre la carga del DW y la migración a Atlas. `mongodump` y `mongorestore` preservan `_id`, así que `74-migrar-mongo.ps1` no fue el culpable.
>
> Para el DW cada documento de Atlas es una fila nueva, y el borrar-e-insertar por clave solo encontró 2 coincidencias de 1 249 874. Las tablas quedaron con doble conteo (1 000 002 y 2 249 872) hasta que se borraron las 1 249 870 filas de origen Atlas. Después: 6/6 tablas de hechos en su cifra documentada, 32/32 claves foráneas confiables, 0 huérfanos.
>
> **No vuelvas a limpiar las marcas de `MONGODB`** mientras Atlas y el DW no compartan los `_id`. Con las marcas en su máximo el problema no se repite. Para dejar los dos lados consistentes hay que volver a migrar Mongo desde el laboratorio local actual, o recargar el DW desde ese mismo laboratorio. Detalle completo en la sección 6 de `etl-cloud.txt`.

**Cómo encaja con el trabajo del Integrante 2.** El Integrante 2 construyó el orquestador de las cuatro fuentes, `05-etl/validar_calidad.py` y `07-migracion/80-validar-etl-integrante2.ps1`, y con eso corrió la **ejecución #5** contra la nube. Su documentación está en `00-docs/12-etl-integrante2-semanas3-4.md` y `00-docs/05-evidencias/migracion/etl-integrante2-calidad.txt`, y las dos correcciones que hizo sobre `43b`/`44b` siguen vigentes.

Conviene precisar qué cubre cada corrida, porque las dos aparecen en la documentación y sus cifras no coinciden:

| | Ejecución #5 (Integrante 2) | Ejecución #8 (Integrante 1) |
|---|---|---|
| Etapas | 23 | 25 |
| `EXTRAER_PG` | 2 050 filas | 2 050 filas |
| `EXTRAER_MONGO` | **0 filas** | **1 249 874 filas** |
| `EXTRAER_ARCHIVOS` | **0 filas**, `sin archivos de entrada` | **6 150 filas** |
| Rechazos | 0 | 84, los esperados |
| Estado | `COMPLETADO` | `CON_ERRORES` por esos 84 |

No es que la #5 estuviera mal: **ejecutó** las etapas de Mongo y archivos, y por eso se la describió como "las cuatro fuentes". Lo que pasa es que con `etl.Marca` en el máximo de la fuente un incremental lee 0 documentos, y los archivos quedan fuera porque su `mtime` no supera la marca. Para que movieran datos hubo que forzar la relectura, y eso es lo que hizo la #8.

Dicho de otro modo: la #5 prueba que el **camino** funciona de punta a punta; la #8 prueba que **los datos** viajan. Y fue la #8 la que destapó lo de los `_id`, que la #5 no podía ver justamente porque no leía de Atlas.

### 3.5 Trampas al repetir

Cinco cosas que muerden a quien vuelva a correr los scripts:

| Trampa | Qué pasa | Cómo evitarla |
|---|---|---|
| Correr `70-provisionar-aws.ps1` dos veces | Reescribe `turismodw-cloud.env` entero | **Ya corregido**: ahora conserva `ATLAS_URI` si existía. Aun así, revisá el archivo después |
| La clase por defecto | Era `db.t3.micro`, que no puede cargar el DW | **Ya corregido**: el valor por defecto es `db.t3.small`. Ver sección 6.1 de `10-*.md` |
| El `.bak` de la ruta alterna | El piloto intentaba restaurar un archivo que nadie subía, y el error parecía un rechazo de RDS | **Ya corregido**: `72` genera el respaldo, lo sube y recién entonces intenta restaurar. Con `-SinRutaAlterna` se salta |
| Las evidencias | Los 15 archivos de `05-evidencias/migracion/` se escriben **con nombre fijo** | Correr un script "para probar" **pisa la entrega**. Copiá la carpeta antes de experimentar |
| Limpiar las marcas de `MONGODB` para forzar una relectura | Las dos tablas de hechos de Mongo se duplican en silencio, porque los `_id` de Atlas no son los del DW. Los índices `UQ_*_Negocio` no lo impiden: las claves son de verdad distintas | **No lo hagas.** Con las marcas en su máximo el incremental lee 0 documentos y no pasa nada. Si ya ocurrió, borrá las filas cuyo `EjecucionIdCarga` sea el de esa corrida y cuya clave empiece en `6a8906` |

---

## 4. Lo que no hay que tocar

| No cambies | Por qué |
|---|---|
| Los índices `UQ_*_Negocio` | Son la clave por la que la carga incremental borra antes de insertar. Sin ellos, `usp_CargarHechosIncremental` hace recorrido completo en vez de búsqueda, y la idempotencia se pierde |
| `04-sqlserver/40` a `47c` originales | Son entregables de las semanas 1 y 2. Las variantes cloud viven aparte, en `07-migracion/sql/` |
| `docker/docker-compose.yml` | Entregable de otro integrante. Los cambios de puerto van en el override |
| `dw.vw_EstadoSistema` y sus 21 columnas | `EstadoSistema.tmdl` del modelo de Power BI las tiene atadas por nombre y tipo. Cambiar una rompe la página 6 |
| `06-powerbi/60-generar-pbip.py` como forma de repuntar | Hace `shutil.rmtree` del reporte y emite uno vacío. Además los artefactos versionados divergieron del generador en el commit `0ee64a4`. Para cambiar de servidor usá `repuntar-powerbi.ps1` |
| El orden de columnas de los `SELECT` en `extract_postgres.py` | `bcp` carga por **posición**, no por nombre. Reordenar una columna corrompe la carga en silencio |

### 4.1 Si algo falla

Cuatro síntomas que ya se vieron, con su causa real. Los cuatro engañan: ninguno dice lo que en verdad pasa.

| Síntoma | Causa real | Qué hacer |
|---|---|---|
| La conexión a RDS **se queda colgada** hasta agotar el tiempo, sin error claro | Tu IP pública cambió y ya no está en `turismodw-sg`. Un grupo de seguridad no rechaza: descarta el paquete en silencio | Reautorizar la IP, sección 3.2 |
| Lo mismo contra Atlas | Tu IP no está en Network Access | Atlas → Network Access → Add IP Address |
| La instancia RDS parece **colgada**: hasta un `SELECT 1` se queda esperando | Una sesión `insert bulk` huérfana de una carga interrumpida retiene un bloqueo de esquema | `SELECT session_id, blocking_session_id, wait_type FROM sys.dm_exec_requests WHERE session_id > 50;` y `KILL <spid>`. Ojo: **`rdsadmin.dbo.rds_kill` no existe** en esta versión de RDS, pero `KILL` directo sí funciona para el usuario maestro |
| `comun.ps1` dice **"La instancia no existe"** | Casi siempre **falta el AWS CLI** o el perfil, no la instancia: la consulta se silencia con `2>$null` y la ausencia de salida se interpreta como ausencia de instancia | `aws sts get-caller-identity --profile turismodw`. Si eso falla, el problema es el perfil |
| Todo responde pero los conteos no cuadran con lo esperado | Estás leyendo un servicio **nativo** de Windows en vez del contenedor | Sección 3.1, verificación de los 2 000 010 |

---

## 5. Qué falta y de quién es

Esta tabla se escribió cuando casi todo estaba abierto. Hoy está casi toda cerrada: los Integrantes 2, 3 y 4 entregaron entre el 24 y el 25 de agosto. Se conserva el listado porque muestra el reparto según el enunciado, con el estado actualizado.

| Pendiente | Semana | Responsable según el enunciado | Estado |
|---|---|---|---|
| Tema de investigación: documentar y prototipo | 3 | **Integrante 4** | **Completo**: ML de clasificación de sentimiento en `08-investigacion-ml/` |
| Tema de investigación: implementación completa | 4 | **Integrante 4** | **Completo**: scripts, métricas, matriz de confusión y capturas de ejecución |
| Demostración de la tecnología investigada | 3 | **Integrante 4** | **Completo**: `08-investigacion-ml/Reseñas.pptx` |
| Dashboard y métricas de negocio | 3 | **Integrante 3** | **Completo**: 52 KPIs certificados, `13-dashboard-metricas-integrante3.md` y `dashboard-turismo.html` |
| Validación de dashboard | 3 | Integrante 3 con Integrante 1 | **Completo**: paridad DAX vs SQL certificada, y el refresco real contra la nube ya está capturado |
| Manual técnico | 4 | Equipo | Cubierto en la práctica por `01`, `11`, `12` y `15`; no existe como documento único |
| Manual de usuario | 4 | Equipo | **Completo**: `14-manual-usuario-dashboard.md` |
| Video de demostración | 4 | Equipo | **No iniciado**. Es el último pendiente real del proyecto |
| Presentación ejecutiva final | 4 | Equipo | **Completa**: `Presentación de flujo.pptx`, lista para presentar |
| Capturas de Power BI contra la nube | 4 | **Integrante 1** | **Hecho** el 25 de agosto: refresco real contra RDS y capturas de las páginas 1 y 6 |

> El estado vivo de los pendientes se lleva en `00-docs/15-pendientes-y-operacion-cloud.md`. Si las dos tablas se contradicen, mandá esa.

### 5.1 Sobre el tema de investigación

El enunciado ofrece nueve temas: CDC, Kafka, Data Lake, Docker, Data Vault, GeoJSON, series temporales, *machine learning* y observabilidad.

**Se eligió *machine learning*,** y el trabajo está en `08-investigacion-ml/`: extracción de reseñas, entrenamiento, predicción, métricas, matriz de confusión y capturas de las tres ejecuciones. La presentación es `08-investigacion-ml/Reseñas.pptx`.

El repositorio ya apuntaba en esa dirección desde la Semana 1: `00-docs/02-diccionario-modelo-estrella.md:199` documenta la columna `LongitudTexto` de `dw.FactResena` como *«Insumo para el tema de investigación (clasificación de reseñas con ML)»*. Por eso `resenas` se migró **completa** a Atlas y no al 50 % como `interacciones_web`: las 500 002 reseñas con calificación, texto, idioma y verificación estaban reservadas para esto.

### 5.2 Sobre las capturas de Power BI

**Cerrado el 25 de agosto.** Era lo único del alcance del Integrante 1 que quedaba abierto, porque abrir el `.pbip`, autenticar y refrescar es interactivo. Se hizo así: el `.pbip` se abrió y se disparó el refresco desde la cinta, una persona escribió la contraseña en el diálogo de **Base de datos** —ese paso sigue sin poder guionizarse— y el resto corrió solo.

El refresco tardó unos 6 minutos. Las cuatro tablas de hechos grandes se pasaron ese rato en `ASYNC_NETWORK_IO`: RDS ya tenía las filas listas y esperaba a que el cliente las consumiera. Con las 17 tablas en modo **import** y 8,6 M de filas viajando de `us-east-1` a Panamá, el cuello de botella es la WAN, no la instancia. Conviene saberlo antes de la demostración en vivo.

Las capturas quedaron en:

- `00-docs/05-evidencias/migracion/powerbi-cloud-pagina1-resumen.png`
- `00-docs/05-evidencias/migracion/powerbi-cloud-pagina6-estado.png`

Lo que muestran, y que sirve de contraste contra el ETL y contra RDS:

| Visual | Valor | Cuadra con |
|---|---|---|
| Nodo activo | `EC2AMAZ-HN6CSJ3` | `@@SERVERNAME` de la instancia actual |
| Estado del mirroring | `GESTIONADO POR AWS`, `RDS Single-AZ` | servicio gestionado, sin AG propio |
| Semáforo de frescura | `Datos al dia`, última carga `8/26/2026` | la corrida del ETL cloud |
| % Ocupación hotelera | `30.2 %` | el `30.19 %` que reportó el ETL |
| Registros rechazados | `84` | los 84 de `etl.Error`, desglosados 44 + 38 + 2 |
| Reservas / Reseñas / Interacciones | 2 mill. / 500 mil / 2 mill. | 2 000 011 / 500 002 / 1 500 002 |

El desglose de calidad de datos que aparece en la página 6 (`JSON preferencias no_nulo 44`, `JSON preferencias numerico_positivo 38`, `XML paquetes numerico_positivo 2`) es, de paso, el registro de calidad que el Integrante 2 tenía pendiente capturar.

**Qué le hace a los archivos guardar el `.pbip`.** Al guardar desde Power BI Desktop 2.157, la aplicación reescribe tres JSON de metadatos —`TurismoDW.pbip`, `TurismoDW.Report/definition.pbir` y `TurismoDW.SemanticModel/definition.pbism`— y les **quita la línea `$schema`**. También crea `TurismoDW.SemanticModel/diagramLayout.json`, que guarda dónde quedó cada tabla en la vista de modelo. Son cambios cosméticos y esperados; no hay que revertirlos, y volverán a aparecer en el próximo guardado. Lo que importa es que **no toca los TMDL de las tablas**: las 16 particiones siguen apuntando a RDS después de guardar. Se verificó.

**El `.pbix` no se genera solo.** Guardar el proyecto no produce el binario: hay que hacer *Archivo → Guardar como → `TurismoDW.pbix`* aparte. Y `.gitignore` excluye `*.pbix` a propósito, porque el archivo con datos incrustados pesa cientos de megabytes. Si el profesor exige el binario, hay que entregarlo por fuera del repositorio.

Lo que sí quedó hecho y verificado: las 16 particiones apuntan a RDS, y las 16 vistas que consume el modelo responden en la nube con los conteos correctos (`00-docs/05-evidencias/migracion/powerbi-validacion-cloud.txt`, regenerado el 25 de agosto después del ETL completo y de la reparación de la sección 3.4).

Tres cifras de ese archivo cambiaron respecto de la versión del 21 de agosto, y cambiaron **bien**: `vw_DimCliente` 50 009 → 50 010, `vw_FactReserva` 2 000 010 → 2 000 011 y `vw_FactOcupacionDiaria` 431 321 → 431 325, por las corridas incrementales. Y `vw_CalidadDatos` pasó de 0 a 6 filas, porque los 84 rechazos por fin poblaron `etl.Error`. Esa vista es, de paso, el registro de calidad de datos que el Integrante 2 tenía pendiente capturar.

Para repetirlo —por ejemplo, si hay que rehacer las capturas después de otra carga:

1. Encender las instancias (sección 3.2).
2. `Start-Process .\06-powerbi\TurismoDW.pbip`
3. Autenticación **Base de datos**, usuario `turismoadmin`, contraseña de `.secrets/turismodw-cloud.env`, confiar en el certificado del servidor.
4. Refrescar. Tarda unos 6 minutos; no está colgado.
5. Capturar página 1 (Resumen) y página 6 (Estado del sistema) en `00-docs/05-evidencias/migracion/`.

> En la página 6 vas a ver `RDS Single-AZ` y `GESTIONADO POR AWS` donde antes decía `AG PRIMARY / SYNCHRONIZED`. Es lo correcto: la vista se adaptó para reportar la redundancia del servicio gestionado en vez de un grupo de disponibilidad propio. Y el `NodoActual` **cambia** después de cualquier cambio de clase de instancia o mantenimiento de AWS; no es un error.

---

## 6. Cerrar el proyecto

Cuando ya no haya que presentar nada desde la nube:

```powershell
.\07-migracion\78-detener-recursos.ps1 -Eliminar
```

Pide confirmación escrita porque es irreversible. Borra las dos instancias y el bucket. **No borra** el grupo de seguridad, el de subredes, el option group ni el rol IAM, porque no cuestan nada; si querés dejar la cuenta limpia hay que hacerlo a mano, y conviene revocar también la clave de acceso del usuario `turismodw-migracion`.

En Atlas, soltar la base `turismo_nosql` y borrar el usuario `turismodw`. **No borres el cluster**: es de otro proyecto.

El laboratorio local no se toca. La migración sigue siendo reversible mientras el entorno Docker esté en pie y el repositorio conserve los scripts originales.

### 6.1 Quién paga y cuánto va

La infraestructura vive en la cuenta AWS **`063876841411`**, que es personal de Alex Herrera, no institucional. El cluster de Atlas está en la organización personal de la misma persona. **Eso importa para el traspaso**: si el proyecto continúa después del curso, o si otro integrante necesita acceso, hay que decidir a nombre de quién queda.

Para ver el gasto acumulado:

```powershell
aws ce get-cost-and-usage --profile turismodw `
    --time-period Start=2026-08-01,End=2026-09-01 `
    --granularity MONTHLY --metrics UnblendedCost `
    --group-by Type=DIMENSION,Key=SERVICE
```

> Si devuelve `AccessDenied`, es que al usuario `turismodw-migracion` le falta `ce:GetCostAndUsage`. No se le adjuntó porque no hacía falta para migrar; se puede agregar o consultar el costo desde la consola de facturación.

---

## 7. Dónde está cada cosa

| Documento | Qué contesta |
|---|---|
| `00-docs/07-estrategia-migracion.md` | Por qué se eligió AWS y rehost, qué riesgos había, cómo se revierte |
| `00-docs/08-matriz-herramientas.md` | Por qué `bcp` y no `.bak`, por qué no DMS, qué se descartó y por qué |
| `00-docs/09-inventario-migracion.md` | Qué objetos hay, cuáles migran tal cual y cuáles no |
| `00-docs/10-validacion-post-migracion.md` | Qué se migró, qué se verificó, qué salió mal y cómo se resolvió |
| `00-docs/11-traspaso-cloud.md` | Este documento: cómo retomar el trabajo |
| `00-docs/05-evidencias/migracion/` | Las 15 salidas crudas que respaldan todo lo anterior |

Y si hay que entender el modelo antes que la migración: `01-arquitectura-etl.md` para el ETL, `02-diccionario-modelo-estrella.md` para la semántica de cada columna, `03-contrato-integrante2.md` para la frontera con el particionamiento.

### 7.1 Cuánto tarda cada cosa

Para que nadie abandone un paso creyendo que se colgó. Medido en esta ejecución:

| Paso | Duración | ¿Se puede dejar solo? |
|---|---:|---|
| Primer arranque de Docker (genera 8,7 M de filas) | 20–25 min | Sí |
| `70-provisionar-aws.ps1`, hasta `available` | 15–25 min | Sí |
| Escalar la clase de una instancia RDS | 5–10 min | Sí |
| `73-migrar-postgres.ps1` (volcado 13,6 s + restauración 167 s) | ~3 min | Sí |
| `74-migrar-mongo.ps1`, `resenas` | ~30 min | Sí, pero vigilá el cupo |
| `74-migrar-mongo.ps1`, `interacciones_web` al 50 % | ~5 min | Sí |
| `75-migrar-dw.ps1 -SoloEsquema` | ~1,5 min | Sí |
| `75-migrar-dw.ps1 -SoloDatos` (8,7 M filas) | ~10 min | Sí |
| ETL `INCREMENTAL` contra la nube | ~2 min | Sí |
| `77-comparar-local-cloud.ps1` (60 consultas) | ~5 min | Sí |

**Dónde el proceso se detiene a esperar a una persona**, y no hay forma de guionizarlo:

1. **Crear el usuario IAM y la clave de acceso** en la consola de AWS.
2. **Crear el cluster de Atlas**, el usuario de base y la regla de red; después pegar `ATLAS_URI` a mano.
3. **Escribir la contraseña en el diálogo de Power BI.** Lanzar el `.pbip`, disparar el refresco y tomar las capturas sí se puede automatizar; el diálogo de credenciales no.

Todo lo demás corre solo.
