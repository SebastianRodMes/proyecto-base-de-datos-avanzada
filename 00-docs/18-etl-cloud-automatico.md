# ETL automático contra la nube

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 4**

> **REEMPLAZADO por `19-etl-fargate-cloud.md`.** Este enfoque (tarea programada
> de Windows en la máquina local) fue el puente inicial y quedó **deshabilitado**:
> el ETL ahora corre 100% en AWS ECS Fargate, disparado por EventBridge cada 5
> minutos, sin depender de ninguna PC. Este documento se conserva como referencia
> del método local. Para reactivar el puente local: `Enable-ScheduledTask -TaskName TurismoDW-ETL-Cloud`.

Deja el ETL apuntando a la infraestructura de AWS y lo ejecuta **cada 5 minutos**, de modo que lo que se inserte en las tablas de la nube (RDS PostgreSQL / Atlas) actualice **solo** el almacén analítico en RDS for SQL Server. Verificado de punta a punta.

---

## 1. Qué se montó

| Pieza | Ruta | Qué hace |
|---|---|---|
| Entorno virtual | `05-etl/.venv/` | Aísla las dependencias del ETL en el host (`psycopg2`, `pymongo`, `pyodbc`, `lxml`) |
| Wrapper cloud | `05-etl/run-etl-cloud.ps1` | Inyecta `05-etl/.env.aws` al entorno del proceso y corre el ETL contra AWS **sin pisar el `.env` local** |
| Tarea programada | `TurismoDW-ETL-Cloud` | Corre el wrapper en modo `INCREMENTAL` cada 5 minutos |
| Logs | `05-etl/logs/etl-cloud-*.log` | Una bitácora por corrida (ignorada por git) |

### Por qué no se pisa el `.env` local
`config.py` carga el `.env` con `os.environ.setdefault`: **las variables que ya existen en el proceso ganan**. El wrapper vuelca `.env.aws` al entorno antes de invocar Python, así el ETL corre contra la nube y el `.env` local queda intacto. No hay que copiar ni restaurar nada (a diferencia del método manual de `11-traspaso-cloud.md` §3.4).

---

## 2. Cómo se prueba el flujo automático

```powershell
# 1) Insertar una fila en el origen de la nube (ejemplo: un hotel en RDS PG)
#    -> se hace con cualquier cliente PostgreSQL contra el endpoint de RDS.
# 2) Disparar la tarea (o esperar al ciclo de 5 min)
Start-ScheduledTask -TaskName "TurismoDW-ETL-Cloud"
# 3) Verificar que el DW en la nube se actualizó
sqlcmd -S "turismodw-sql.cyjcymmugyxk.us-east-1.rds.amazonaws.com,1433" -U turismoadmin -P "<clave>" -d TurismoDW -C -Q "SELECT COUNT(*) FROM dw.DimHotel;"
```

**Resultado registrado:** se insertó `DEMO Hotel Migracion Cloud` en RDS PostgreSQL; tras una corrida de la tarea (`LastResult=0`), `dw.DimHotel` pasó de **201 a 202** en el SQL Server de la nube, con la fila nueva presente. La propagación ocurrió sin intervención manual.

---

## 3. Operar la tarea

```powershell
Get-ScheduledTask -TaskName "TurismoDW-ETL-Cloud"                 # estado
Get-ScheduledTaskInfo -TaskName "TurismoDW-ETL-Cloud"            # última corrida / resultado
Start-ScheduledTask   -TaskName "TurismoDW-ETL-Cloud"            # correr ahora
Disable-ScheduledTask -TaskName "TurismoDW-ETL-Cloud"            # pausar
Enable-ScheduledTask  -TaskName "TurismoDW-ETL-Cloud"            # reanudar
Unregister-ScheduledTask -TaskName "TurismoDW-ETL-Cloud" -Confirm:$false   # eliminar
```

Correr el wrapper a mano (fuera de la tarea):

```powershell
.\05-etl\run-etl-cloud.ps1                  # incremental (por defecto)
.\05-etl\run-etl-cloud.ps1 -Modo FULL       # recarga completa cloud
.\05-etl\run-etl-cloud.ps1 -ArgsExtra '--solo-pg'
```

> **Importante — costo.** La tarea intenta conectarse cada 5 minutos. Si se **apagan** las instancias RDS (`78-detener-recursos.ps1`) para no pagar, la tarea empezará a fallar en cada ciclo (inofensivo, solo ruido en los logs). Antes de apagar la nube conviene `Disable-ScheduledTask`, y `Enable-ScheduledTask` al volver a encenderla.

---

## 4. Dos decisiones de red que hubo que tomar

Ambas son porque el ETL corre desde un host doméstico contra RDS, y quedan documentadas por honestidad.

### 4.1 PostgreSQL sin TLS (`rds.force_ssl=0`)
Esta red **resetea el handshake TLS del protocolo PostgreSQL** (`SSL SYSCALL error: Connection reset by peer`), mientras el texto plano sí alcanza el servidor y el TLS de SQL Server (1433) no se ve afectado. Como no se puede corregir desde el cliente, se creó el parameter group **`turismodw-pg16`** con `rds.force_ssl=0` y se asoció a `turismodw-pg` (reinicio incluido). El wrapper pide `PGSSLMODE=disable`.

### 4.2 SQL Server sin cifrado en `bcp`
La máquina tiene el **`bcp` de ODBC 17**, que no soporta `-u` ni cifrado. `config.py` agrega `-u` cuando `SQL_CIFRADO` está activo (pensado para el `bcp` de ODBC 18) y con bcp 17 eso da `unknown option u`. RDS for SQL Server **no fuerza TLS** (verificado), así que el wrapper apaga `SQL_CIFRADO`: ni `bcp` recibe `-u` ni la cadena ODBC pide `Encrypt`.

**Riesgo acotado:** en ambos casos el canal va en claro, pero el security group solo admite la IP registrada y los datos son de laboratorio. Para volver a cifrar: poner `rds.force_ssl=1`, instalar las herramientas de ODBC 18 y restaurar `SQL_CIFRADO=yes` / `PGSSLMODE=require`.

---

## 5. Salvaguarda importante (no tocar)

La tarea corre **`INCREMENTAL`**, que respeta las marcas de agua de `etl.Marca`. **Nunca** limpiar las marcas de `MONGODB`: con los `_id` de Atlas distintos de los del DW, una relectura completa duplicaría `dw.FactResena` y `dw.FactInteraccionWeb` en silencio (los índices `UQ_*_Negocio` no lo impiden). Con las marcas en su máximo, el incremental lee 0 documentos de Mongo y el problema no aparece. Detalle en `11-traspaso-cloud.md` §3.4.
