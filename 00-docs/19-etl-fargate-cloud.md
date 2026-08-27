# ETL 100% en la nube — AWS ECS Fargate

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 4**

El ETL ya **no depende de ninguna PC**: corre como una **tarea de ECS Fargate** que **EventBridge Scheduler dispara cada 5 minutos**. Lee de RDS PostgreSQL y Atlas, y actualiza el DW en RDS for SQL Server, todo dentro de AWS. Verificado de punta a punta (ejecución #19: `COMPLETADO`, 25 etapas, integridad OK, marcas avanzadas, 1m13s).

> Reemplaza a la tarea programada local de Windows descrita en `18-etl-cloud-automatico.md`, que quedó **deshabilitada** (`Disable-ScheduledTask TurismoDW-ETL-Cloud`). Aquella servía como puente; esta es la solución definitiva sin dependencia del equipo.

---

## 1. Arquitectura

```text
EventBridge Scheduler ──(cada 5 min)──> ECS Fargate task (turismodw-etl)
   rate(5 minutes)                          │  imagen en ECR (Python + bcp/ODBC18)
   rol: turismodw-scheduler                 │  subred pública + IP pública (egress)
                                            │  SG turismodw-etl-task -> RDS (SG-to-SG)
                                            ▼
                 lee  RDS PostgreSQL (turismodw-pg)  +  Atlas (turismo_nosql)
                 escribe  RDS SQL Server (turismodw-sql / TurismoDW)
                 logs -> CloudWatch /ecs/turismodw-etl
```

Al correr **dentro de AWS**, la conexión a RDS usa la red interna: el TLS de PostgreSQL ya no se resetea (ese problema era del ISP local), por eso se **reactivó `rds.force_ssl=1`** y todo el canal va cifrado.

---

## 2. Recursos creados (cuenta 063876841411, us-east-1)

| Recurso | Identificador |
|---|---|
| Imagen del contenedor | `Dockerfile.etl` → ECR `063876841411.dkr.ecr.us-east-1.amazonaws.com/turismodw-etl:latest` |
| Cluster ECS | `turismodw` |
| Task definition | `turismodw-etl` (Fargate, 0.5 vCPU / 1 GB) |
| Programador | EventBridge Schedule `turismodw-etl-cada-5min` (`rate(5 minutes)`) |
| Credenciales | Secrets Manager `turismodw-etl-cloud` (PG_PASSWORD, SQL_PASSWORD, MONGO_URI) |
| Rol de ejecución | `turismodw-ecs-exec` (pull ECR + leer secreto + logs) |
| Rol del scheduler | `turismodw-scheduler` (ecs:RunTask + iam:PassRole) |
| SG de la task | `sg-0bd56d77c472a0cc6` (con regla SG→RDS en 1433 y 5432 sobre `turismodw-sg`) |
| Logs | CloudWatch `/ecs/turismodw-etl` (retención 14 días) |
| Red | VPC por defecto `vpc-0a9da1c44073ba4b2`, 3 subredes públicas, IP pública para egress |

La imagen (`Dockerfile.etl`) incluye Python 3.11, ODBC Driver 18, `bcp`/`sqlcmd` y el código de `05-etl/`, `04-sqlserver/` y `03-archivos/entrada/`. Las credenciales **no** están en la imagen: llegan por variables de entorno (no secretas) y desde Secrets Manager (contraseñas).

---

## 3. Operación

Todos los comandos usan la ruta completa de `aws` para evitar problemas de PATH. Reemplazá por tu ruta si difiere.

```powershell
$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"

# Ver los logs de la última corrida (en vivo)
& $aws logs tail /ecs/turismodw-etl --follow --profile turismodw --region us-east-1

# Correr el ETL YA, sin esperar al ciclo de 5 min
& $aws ecs run-task --cluster turismodw --task-definition turismodw-etl --launch-type FARGATE `
  --network-configuration "awsvpcConfiguration={subnets=[subnet-031d7a8e4c81a93d6,subnet-0b3b11c48fe282e1f,subnet-0d9da50cb422cb5e8],securityGroups=[sg-0bd56d77c472a0cc6],assignPublicIp=ENABLED}" `
  --profile turismodw --region us-east-1

# Pausar / reanudar el disparo automático (desde la consola es un toggle):
#   Consola -> EventBridge -> Schedules -> turismodw-etl-cada-5min -> Disable/Enable
```

**Cambiar la frecuencia:** editar el schedule `turismodw-etl-cada-5min` y cambiar `rate(5 minutes)` por, por ejemplo, `rate(1 hour)`.

**Actualizar el código del ETL:** reconstruir y volver a subir la imagen, luego forzar una corrida:
```powershell
docker build -f Dockerfile.etl -t turismodw-etl:latest .
& $aws ecr get-login-password --profile turismodw --region us-east-1 | docker login --username AWS --password-stdin 063876841411.dkr.ecr.us-east-1.amazonaws.com
docker tag turismodw-etl:latest 063876841411.dkr.ecr.us-east-1.amazonaws.com/turismodw-etl:latest
docker push 063876841411.dkr.ecr.us-east-1.amazonaws.com/turismodw-etl:latest
```

---

## 4. Costo

| Componente | Costo aproximado |
|---|---|
| **RDS encendidas 24/7** (para que el ETL siempre tenga a qué conectarse) | **~37 USD/mes** (dominante) |
| Fargate (≈1.5 min por corrida, cada 5 min) | ~2–4 USD/mes |
| ECR + Secrets Manager + CloudWatch Logs | ~1 USD/mes |

> El costo real lo manda tener las **RDS siempre encendidas**: es el precio de que el ETL funcione sin tu equipo. Si en algún momento no se necesita 24/7, se pausa el schedule y se apagan las RDS con `07-migracion/78-detener-recursos.ps1` (mientras estén apagadas, el ETL fallará en cada ciclo; conviene deshabilitar el schedule).

---

## 5. Salvaguarda (no tocar)

La task corre `--modo INCREMENTAL`, que respeta las marcas de agua de `etl.Marca`. **Nunca** limpiar las marcas de `MONGODB`: duplicaría `dw.FactResena` y `dw.FactInteraccionWeb` en silencio (ver `11-traspaso-cloud.md` §3.4).

---

## 6. Cómo desmontar todo (si se quiere revertir)

```powershell
$aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"; $P = "--profile","turismodw","--region","us-east-1"
& $aws scheduler delete-schedule --name turismodw-etl-cada-5min @P
& $aws ecs deregister-task-definition --task-definition turismodw-etl:1 @P   # opcional
& $aws ecs delete-cluster --cluster turismodw @P
& $aws ecr delete-repository --repository-name turismodw-etl --force @P
& $aws secretsmanager delete-secret --secret-id turismodw-etl-cloud --force-delete-without-recovery @P
# Roles, SG y log group se pueden borrar aparte; no cuestan nada si quedan.
```

El laboratorio local y el resto de la migración no se ven afectados.
