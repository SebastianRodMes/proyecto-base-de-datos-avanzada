# Pendientes y operación de la nube

Documento de cierre para las Semanas 3 y 4. Resume **lo que falta**, cómo **encender
y apagar** las instancias en la nube, y las **credenciales** para conectar Power BI.

---

## 1. Qué falta para terminar

| Pendiente | Responsable | Estado |
|---|---|---|
| Capturas del dashboard en la nube (páginas 1 y 6) | Integrante 1 / Alex | **Hecho** el 25 de agosto |
| Video de demostración | Equipo | No iniciado |
| Presentación final ante el grupo | Equipo | Lista para presentar |

Todo lo demás está terminado: migración a la nube, ETL e integración, almacén de datos
validado, dashboard conectado, tema de investigación (ML de reseñas) y manual de usuario.

> **Las capturas ya no bloquean nada.** Se destrabó la conexión a RDS, se refrescó el
> modelo contra la nube y quedaron en:
>
> - `00-docs/05-evidencias/migracion/powerbi-cloud-pagina1-resumen.png`
> - `00-docs/05-evidencias/migracion/powerbi-cloud-pagina6-estado.png`
>
> Son las dos que van en los marcos reservados de la **diapositiva 6** de
> `Presentación de flujo.pptx`. Con eso, el único pendiente real del proyecto es el
> video.
>
> Lo que muestran, por si hay que defenderlas: `30.2 %` de ocupación —que coincide con
> el `30.19 %` que reportó el ETL—, `84` registros rechazados desglosados 44 + 38 + 2,
> y en la página 6 `EC2AMAZ-HN6CSJ3` con `RDS Single-AZ / GESTIONADO POR AWS`. Ese
> nombre de nodo **cambia** cada vez que AWS reemplaza la máquina; no es un error.
>
> El refresco tarda unos 6 minutos porque las 17 tablas son de modo *import* y las de
> hechos esperan en `ASYNC_NETWORK_IO`: el límite es la WAN hasta `us-east-1`, no la
> instancia. Si se rehace en vivo, conviene tenerlo hecho de antes.

Las presentaciones ya están armadas:

- `00-docs/Presentación de flujo.pptx` — presentación ejecutiva del proyecto completo.
  Tiene **marcos reservados** en la diapositiva 6 (2 capturas de Power BI) y en la
  diapositiva 8 (video). Solo hay que pegar las imágenes y el video encima.
- `08-investigacion-ml/Reseñas.pptx` — presentación del tema de investigación (ML).

---

## 2. Credenciales de Power BI (almacén en la nube)

| Campo | Valor |
|---|---|
| Tipo de autenticación | **Base de datos** (SQL Server) |
| Servidor | `turismodw-sql.cyjcymmugyxk.us-east-1.rds.amazonaws.com,1433` |
| Base de datos | `TurismoDW` |
| Usuario | `turismoadmin` |
| Contraseña | En `.secrets/turismodw-cloud.env`, línea `RDS_SQL_PASSWORD=` |

La contraseña **no se versiona**: vive solo en el archivo de secretos local.

---

## 3. Encender la RDS y autorizar la IP

La conexión de Power BI falla con **"tiempo de espera agotado"** si la instancia está
apagada o si la IP del cliente no está autorizada. Para habilitarla:

**Datos:**

- Instancia: `turismodw-sql` · Región: `us-east-1`
- Grupo de seguridad: `sg-0918cbca9545be043` · Puerto: `1433`

**Con los scripts del repositorio** (necesitan AWS CLI y el perfil `turismodw`):

```powershell
# Encender las instancias
.\07-migracion\78-detener-recursos.ps1 -Iniciar

# Reautorizar la IP pública actual en el grupo de seguridad
.\07-migracion\70-provisionar-aws.ps1
```

**Con AWS CLI directo:**

```bash
aws rds start-db-instance --db-instance-identifier turismodw-sql --profile turismodw --region us-east-1

aws ec2 authorize-security-group-ingress --group-id sg-0918cbca9545be043 --protocol tcp --port 1433 --cidr <TU_IP>/32 --profile turismodw --region us-east-1
```

**Desde la consola web:**

1. RDS → Databases → `turismodw-sql` → Actions → **Start**. Esperar a estado **Available** (~5–10 min).
2. EC2 → Security Groups → `sg-0918cbca9545be043` → Inbound rules → **Add rule**: MSSQL (1433), Source `<TU_IP>/32` → Save.

**Verificar la conexión antes de abrir Power BI:**

```powershell
Test-NetConnection turismodw-sql.cyjcymmugyxk.us-east-1.rds.amazonaws.com -Port 1433
```

Debe devolver `TcpTestSucceeded: True`. Luego, en Power BI Desktop → **Actualizar**.

> La IP pública del cliente puede cambiar al reiniciar el router. Si vuelve a fallar con
> timeout, hay que reautorizar la nueva IP.

---

## 4. Apagar la RDS al terminar

Para no generar costo, las instancias se apagan cuando no se están usando:

```powershell
.\07-migracion\78-detener-recursos.ps1
```

O con AWS CLI directo:

```bash
aws rds stop-db-instance --db-instance-identifier turismodw-sql --profile turismodw --region us-east-1
aws rds stop-db-instance --db-instance-identifier turismodw-pg  --profile turismodw --region us-east-1
```

> **Estado al cerrar este documento:** las instancias RDS están **apagadas**
> (la prueba de conexión al puerto 1433 dio *timeout*, que es el comportamiento
> esperado con la instancia detenida). Para las capturas de Power BI hay que
> encenderlas siguiendo la sección 3, y volver a apagarlas al terminar.

> MongoDB Atlas queda encendido de forma permanente (no genera costo en el plan
> gratuito) y es la fuente que usa el prototipo de Machine Learning.

---

## 5. Infraestructura

La infraestructura en la nube vive en la cuenta de AWS del equipo y en MongoDB Atlas.
El detalle completo del traspaso —qué secretos hacen falta, cómo reactivar el entorno y
de quién es cada pendiente— está en `00-docs/11-traspaso-cloud.md`.
