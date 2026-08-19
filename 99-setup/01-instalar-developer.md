# Migración a SQL Server 2022 Developer Edition

**ITI-821 · Escenario 8 · Semana 3 · Integrante 1: Alex Herrera**

Este documento elimina de forma definitiva los dos riesgos abiertos del proyecto.

---

## El problema, con números

```
Instancia MSSQLSERVER
  Edición   : Enterprise Evaluation Edition
  Instalada : 1 de agosto de 2025
  Vigencia  : 180 días  ->  vencía el 28 de enero de 2026
  Hoy       : 16 de agosto de 2026  ->  380 días desde la instalación
```

**La licencia venció hace ~200 días.** El servicio no arranca. No es un riesgo: es un hecho verificado.

Y las otras tres instancias (`SQLEXPRESS`, `SQLEXPRESS01`, `SQLEXPRESS02`) son Express Edition, que **sólo puede actuar como testigo** de Database Mirroring — nunca como principal ni como espejo. Con lo instalado hoy, Mirroring es imposible.

---

## La solución: Developer Edition

| | Enterprise Evaluation | **Developer** | Express |
|---|---|---|---|
| Costo | Gratis | **Gratis** | Gratis |
| Caducidad | **180 días** | **Nunca** | Nunca |
| Funcionalidad | Enterprise completa | **Enterprise completa** | Limitada |
| Tamaño máximo de base | Sin límite | **Sin límite** | 10 GB |
| Memoria / núcleos | Sin límite | **Sin límite** | 1.4 GB / 4 núcleos |
| Mirroring principal y espejo | Sí | **Sí** | **No** (sólo testigo) |
| Particionamiento, columnstore, compresión | Sí | **Sí** | Sí (desde 2016 SP1) |
| Uso en producción | No | No | Sí |

Developer es idéntica a Enterprise en funcionalidad; la única restricción es que no puede usarse en producción. Para un proyecto académico es exactamente lo que corresponde, y **no caduca**.

---

## Arquitectura objetivo

```
   ┌──────────────────────┐  mirroring   ┌──────────────────────┐
   │  BOSGAME-WINTP\DW    │◄────────────►│ BOSGAME-WINTP\MIRROR │
   │  Developer 2022      │  puerto      │  Developer 2022      │
   │  PRINCIPAL           │  5022 / 5023 │  ESPEJO              │
   │  TurismoDW           │              │  TurismoDW           │
   └──────────┬───────────┘              └──────────┬───────────┘
              │                                     │
              └──────────────┬──────────────────────┘
                             │ puerto 5024
                  ┌──────────▼───────────┐
                  │  BOSGAME-WINTP\      │
                  │  SQLEXPRESS          │
                  │  TESTIGO             │   <- ya instalada, se reutiliza
                  └──────────────────────┘

   Power BI y el ETL apuntan al alias TURISMODW, nunca al nombre físico.
```

El testigo es lo que habilita el **failover automático** en modo alta seguridad. Express es una opción válida y gratuita para ese rol, así que las instancias que ya existen no se desperdician.

---

## Paso 1 — Descargar

<https://www.microsoft.com/es-es/sql-server/sql-server-downloads>

Botón **«Descargar ahora»** bajo *Developer*. Se baja `SQL2022-SSEI-Dev.exe` (~5 MB), que luego descarga el medio completo (~1.1 GB).

Al ejecutarlo elegir **«Descargar medios» → ISO** y guardarlo, por ejemplo, en `D:\Instaladores\`. Guardar el ISO permite instalar la segunda instancia sin volver a descargar.

---

## Paso 2 — Instalar la instancia principal

Montar el ISO (doble clic) y ejecutar `setup.exe` **como Administrador**.

1. **Instalación → Nueva instalación independiente de SQL Server**
2. Edición: **Developer** (aparece en la lista de ediciones gratuitas; no pide clave)
3. Características: marcar sólo **Servicios de Motor de base de datos**
4. Configuración de instancia: **Instancia con nombre** → `DW`
5. Configuración del servidor:
   - Motor de base de datos: **Automático**
   - **Agente SQL Server: Automático** ← hace falta para respaldos programados
6. Configuración del Motor de base de datos:
   - Modo: **Modo mixto**, contraseña de `sa`: `Armagedon45*` (la del material del curso)
   - **Agregar usuario actual** como administrador
   - Pestaña *Directorios de datos*: apuntar a `D:\DB\mssql\`
7. Instalar (~10 min)

### Paso 3 — Instalar la instancia espejo

Repetir el paso 2 con **una sola diferencia**: nombre de instancia `MIRROR`.

> Ambas instancias deben ser de la misma familia de edición. Developer ↔ Developer cumple.

---

## Paso 4 — Configurar la máquina

Ejecutar como Administrador el script que ya está en el proyecto, indicándole la instancia nueva:

```powershell
& ".\99-setup\00-setup-admin.ps1" -Instancia DW
```

El script resuelve solo el nombre del servicio y la clave del registro a partir de ese parámetro; no hay que editar nada. Si la instancia no existe, lista las que sí están instaladas con su edición y se detiene sin tocar la máquina.

Además avisa por edición: si detecta Evaluation advierte de la caducidad, y si detecta Express advierte del tope de 10 GB y de que sólo puede ser testigo de Mirroring.

Tras el failover del Integrante 3, el mismo script repunta el alias al nodo espejo:

```powershell
& ".\99-setup\00-setup-admin.ps1" -Instancia MIRROR -DestinoAlias BOSGAME-WINTP
```

El script deja: rutas de datos, TCP habilitado en el puerto 1433, firewall abierto y el alias `TURISMODW` apuntando al principal.

---

## Paso 5 — Repoblar el DW en la instancia definitiva

Todo el trabajo hecho se reutiliza sin cambios. Sólo cambia el destino en un archivo:

```ini
# 05-etl/.env
SQL_SERVIDOR=TURISMODW
```

Y se vuelve a ejecutar la secuencia completa:

```powershell
sqlcmd -S TURISMODW -E -C -i 04-sqlserver\40-crear-basedatos.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\41-esquema-staging.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\42-esquema-estrella.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\43-etl-control.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\44-transformacion.sql
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\45-vistas-powerbi.sql
python 05-etl\run_etl.py
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\46-validacion-consistencia.sql
```

`40-crear-basedatos.sql` detecta la edición automáticamente: al ver Developer usa los tamaños completos de archivo (7.4 GB preasignados) en lugar de los reducidos de Express. No hay que editar nada.

La corrida sobre Express **no se desperdicia**: sirve como evidencia de que el ETL y el modelo estrella funcionan de punta a punta, y como línea base de tiempos para comparar contra la instancia definitiva.

---

## Paso 6 — Mirroring (Integrante 3)

Con las dos instancias Developer, los pasos de `Mirroring.zip` aplican tal cual.

```sql
-- En el PRINCIPAL (instancia DW)
ALTER DATABASE TurismoDW SET RECOVERY FULL;   -- ya viene en FULL desde 40-crear-basedatos.sql

BACKUP DATABASE TurismoDW
  TO DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak' WITH INIT, COMPRESSION;

BACKUP LOG TurismoDW
  TO DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_log.trn' WITH INIT;
```

```sql
-- En el ESPEJO (instancia MIRROR) - se restaura SIN recuperar
RESTORE DATABASE TurismoDW
  FROM DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak'
  WITH NORECOVERY,
       MOVE 'TurismoDW_sys'    TO 'D:\DB\mssql\Mirror\TurismoDW_sys.mdf',
       MOVE 'TurismoDW_dim01'  TO 'D:\DB\mssql\Mirror\TurismoDW_dim01.ndf',
       MOVE 'TurismoDW_fact01' TO 'D:\DB\mssql\Mirror\TurismoDW_fact01.ndf',
       MOVE 'TurismoDW_fact02' TO 'D:\DB\mssql\Mirror\TurismoDW_fact02.ndf',
       MOVE 'TurismoDW_stg01'  TO 'D:\DB\mssql\Mirror\TurismoDW_stg01.ndf',
       MOVE 'TurismoDW_idx01'  TO 'D:\DB\mssql\Mirror\TurismoDW_idx01.ndf',
       MOVE 'TurismoDW_log'    TO 'D:\DB\mssql\Mirror\TurismoDW_log.ldf';

RESTORE LOG TurismoDW
  FROM DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_log.trn' WITH NORECOVERY;
```

> El `MOVE` debe listar **los seis archivos de datos más el log**. Es el detalle donde suele fallar el paso: la base tiene cinco filegroups, no uno.

Endpoints (uno por instancia, puertos distintos):

```sql
-- Principal (DW)
CREATE ENDPOINT Mirroring STATE = STARTED
  AS TCP (LISTENER_PORT = 5022)
  FOR DATABASE_MIRRORING (ROLE = PARTNER, ENCRYPTION = REQUIRED ALGORITHM AES);

-- Espejo (MIRROR)
CREATE ENDPOINT Mirroring STATE = STARTED
  AS TCP (LISTENER_PORT = 5023)
  FOR DATABASE_MIRRORING (ROLE = PARTNER, ENCRYPTION = REQUIRED ALGORITHM AES);

-- Testigo (SQLEXPRESS)
CREATE ENDPOINT Mirroring STATE = STARTED
  AS TCP (LISTENER_PORT = 5024)
  FOR DATABASE_MIRRORING (ROLE = WITNESS, ENCRYPTION = REQUIRED ALGORITHM AES);
```

Establecer la sesión (el orden importa: primero el espejo apunta al principal):

```sql
-- En el ESPEJO
ALTER DATABASE TurismoDW SET PARTNER = 'TCP://BOSGAME-WINTP:5022';

-- En el PRINCIPAL
ALTER DATABASE TurismoDW SET PARTNER = 'TCP://BOSGAME-WINTP:5023';
ALTER DATABASE TurismoDW SET WITNESS = 'TCP://BOSGAME-WINTP:5024';
ALTER DATABASE TurismoDW SET SAFETY FULL;   -- alta seguridad con failover automático
```

Como las tres instancias corren bajo cuentas de servicio virtuales distintas (`NT Service\MSSQL$DW`, `NT Service\MSSQL$MIRROR`, `NT Service\MSSQL$SQLEXPRESS`), cada una debe poder conectarse al endpoint de las otras:

```sql
-- Ejecutar en cada instancia, creando los logins de las otras dos
CREATE LOGIN [NT Service\MSSQL$MIRROR] FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQL$MIRROR];
```

> Es el paso que más falla en la práctica. `Mirroring.zip` lo menciona como *«GRANT Connect Mirroring»*: sin ese permiso la sesión queda en estado `DISCONNECTED` sin decir por qué.

Verificar:

```sql
SELECT DB_NAME(database_id)   AS BaseDatos,
       mirroring_role_desc    AS Rol,
       mirroring_state_desc   AS Estado,
       mirroring_safety_level_desc AS Seguridad,
       mirroring_partner_name AS Socio,
       mirroring_witness_name AS Testigo
FROM sys.database_mirroring
WHERE mirroring_guid IS NOT NULL;
```

Ese mismo resultado es el que alimenta `dw.vw_EstadoSistema` y aparece en la página 6 del dashboard.

---

## Resultado: riesgos cerrados

| Riesgo original | Estado tras la migración |
|---|---|
| Enterprise Evaluation caduca | **Eliminado.** Developer no caduca. |
| Mirroring imposible con Express | **Eliminado.** Dos Developer + Express como testigo. |
| Límite de 10 GB por base | **Eliminado.** Developer no tiene límite. |
| UAC repetido | **Reducido a la instalación.** Después, el ETL y Power BI corren sin elevación. |
