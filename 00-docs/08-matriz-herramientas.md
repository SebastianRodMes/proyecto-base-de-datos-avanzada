# Matriz de herramientas de migración

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Herramientas evaluadas para mover cada componente de TurismoDW hacia AWS, con el veredicto y la razón de cada decisión. Acompaña a `00-docs/07-estrategia-migracion.md`.

---

## 1. Criterios de evaluación

Toda herramienta se juzgó contra cinco criterios, en este orden de prioridad:

| # | Criterio | Por qué pesa aquí |
|---:|---|---|
| 1 | **Reproducibilidad** | El profesor debe poder repetir la migración. Una herramienta gráfica que exige quince clics no es evidencia |
| 2 | **Fidelidad** | Los conteos y los checksums tienen que cuadrar contra el origen; una herramienta que convierte tipos silenciosamente rompe la validación |
| 3 | **Costo** | Proyecto de curso, presupuesto real cercano a cero |
| 4 | **Disponibilidad inmediata** | Lo que ya está instalado y autenticado gana sobre lo que hay que instalar y aprender |
| 5 | **Trazabilidad del error** | Cuando falla, tiene que decir qué fila y por qué |

> **La reproducibilidad manda sobre la comodidad.** El Asistente de Importación y Exportación de SSMS habría movido el DW en veinte minutos de clics, y no habría quedado nada que otro integrante pudiera volver a ejecutar. Todo lo elegido en este documento es línea de comandos guionizable.

---

## 2. Resumen de decisiones

| Componente | Herramienta elegida | Alternativa probada | Descartadas |
|---|---|---|---|
| PostgreSQL → RDS PostgreSQL | `pg_dump -Fc` + `pg_restore` | — | AWS DMS, `\copy`, snapshot |
| MongoDB → Atlas M0 | `mongodump` + `mongorestore` | — | Atlas Live Migration, `mongoexport` |
| SQL Server → RDS SQL Server | DDL portable + `bcp` | `rds_restore_database` desde S3 | SSMA, SCT, asistente de SSMS |
| JSON/XML → S3 | `aws s3 sync` | — | Cargar a tablas |
| Orquestación | PowerShell + AWS CLI | — | CloudFormation, Terraform |

---

## 3. PostgreSQL → Amazon RDS for PostgreSQL 16

| Herramienta | Alcance | Costo | Veredicto | Razón |
|---|---|---|---|---|
| **`pg_dump -Fc` + `pg_restore`** | Esquema y datos completos | $0 | **Elegida** | Formato *custom* comprimido, restauración paralelizable con `-j`, y conserva **el índice GIN sobre `JSONB`** que es el único objeto realmente delicado del origen |
| AWS DMS | Carga completa más CDC continuo | ~$0.018/h + instancia de replicación | Descartada | Tres razones: el usuario IAM no tiene permisos de DMS; exige una instancia de replicación que duplica el costo; y **CDC no aporta nada aquí** porque el origen es un laboratorio congelado durante la copia, no un sistema transaccional vivo |
| `psql \copy` por tabla | Solo datos | $0 | Descartada | Obligaría a recrear a mano las 13 tablas, 14 claves foráneas, 13 secuencias y 5 índices. `pg_dump` ya lo hace |
| Restauración de *snapshot* | Instancia completa | $0 | No aplica | Requiere que el origen ya esté en RDS |

> **Sobre el índice GIN.** `preferencia_cliente.datos_adicionales` es una columna `JSONB` con un índice GIN encima (`turismo_ddl.sql:167`). Es el objeto con más probabilidad de perderse en una migración descuidada, porque muchas herramientas de copia mueven filas y no índices. `pg_restore` lo recrea desde el volcado, y `73-migrar-postgres.ps1` lo verifica explícitamente contra `pg_indexes` después de restaurar.

---

## 4. MongoDB → MongoDB Atlas M0

| Herramienta | Alcance | Costo | Veredicto | Razón |
|---|---|---|---|---|
| **`mongodump` + `mongorestore`** | Colecciones, documentos e índices | $0 | **Elegida** | Formato BSON: conserva los tipos nativos sin convertir. Recrea los 6 índices explícitos. Permite `--query` para migrar un subconjunto, que es exactamente lo que exige el tope de 512 MB de M0 |
| Atlas Live Migration | Réplica continua hasta el corte | $0 en M10+ | Descartada | **No está disponible en M0**, que es el nivel gratuito elegido. Además exige que Atlas alcance el origen por red, y el MongoDB de este proyecto vive dentro de una red de Docker en una máquina doméstica |
| `mongoexport` + `mongoimport` | Documentos como JSON | $0 | Descartada | JSON extendido pierde precisión en fechas y en enteros de 64 bits. Con 2 000 000 de documentos, la conversión de ida y vuelta introduce diferencias que la validación detectaría como errores reales |
| Amazon DocumentDB | Servicio gestionado compatible | ~$0.09/h + bastión EC2 | Descartada | Sin capa gratuita, y solo accesible dentro de la VPC: obligaría a levantar una instancia EC2 como puente, sumando costo y superficie |

> **La restricción de M0 era real, pero no donde se buscaba.** El inventario midió `turismo_nosql` en **205 MB** comprimidos —139 MB de datos más 66 MB de índices— muy por debajo de los 512 MB de M0, y de ahí se concluyó que cabría entera. La medición era correcta; el límite estaba en otro sitio: **el cupo de M0 se cuenta por cluster, no por base de datos**, y el cluster reutilizado ya alojaba los datos de otro proyecto.
>
> La migración se detuvo sola con `using 518 MB of 512 MB. Writes are blocked`. Se resolvió migrando `resenas` completa y un **50 % determinista** de `interacciones_web` con `--query '{"duracion_seg": {"$mod": [2, 0]}}'`.
>
> **Y ahí se ve por qué la capacidad de muestrear pesó al elegir `mongodump`.** Cuando apareció el límite, el plan B no exigió cambiar de herramienta ni rehacer el script: fue un parámetro más en la misma invocación. Atlas Live Migration, que era la alternativa más automática, no habría ofrecido esa salida.

---

## 5. SQL Server → Amazon RDS for SQL Server 2022 Express

Este es el componente con más candidatos y el único donde se ejecutan **dos rutas y se comparan**.

| Herramienta | Alcance | Costo | Veredicto | Razón |
|---|---|---|---|---|
| **DDL portable + `bcp`** | Esquema adaptado y datos | $0 | **Elegida (primaria)** | Determinista y controlable tabla por tabla. Reutiliza el `bcp` que el ETL ya usa (`load_sqlserver.py:82`), con sus mismos delimitadores y su archivo `.err` de rechazos. Y sobre todo: **permite adaptar el esquema durante la migración**, que es justo lo que hacen falta los filegroups |
| **`rds_backup_database` / `rds_restore_database` vía S3** | Base completa binaria | $0 (S3) | **Alternativa, se prueba en el piloto** | Mucho más rápida y fiel. Pero arrastra la estructura física del origen, incluidos los 14 filegroups, que es precisamente lo que RDS puede rechazar. Se prueba para documentar el resultado, no se depende de ella |
| AWS SCT (*Schema Conversion Tool*) | Conversión de esquema | $0 | Descartada | Su valor está en migraciones **heterogéneas** (Oracle→PostgreSQL, SQL Server→Aurora). De SQL Server a SQL Server no hay nada que convertir: las incompatibilidades son de infraestructura (filegroups, rutas, HA), no de dialecto, y SCT no las resuelve |
| SSMA (*SQL Server Migration Assistant*) | Migración hacia SQL Server | $0 | Descartada | Misma razón inversa: migra **hacia** SQL Server desde otros motores |
| Asistente de importación/exportación de SSMS | Datos | $0 | Descartada | No guionizable. Falla el criterio 1 |
| `Generate Scripts` de SSMS | Esquema y datos como `INSERT` | $0 | Descartada | 8 695 473 sentencias `INSERT` individuales. Inviable |
| AWS DMS homogéneo | Carga completa más CDC | ~$0.018/h | Descartada | Sin permisos, y el argumento de CDC del punto 3 aplica igual |

### 5.1 La pregunta que decide todo: ¿acepta RDS los filegroups?

Los scripts `41` a `45` y `47b` llevan `ON FG_DIM`, `ON FG_FACT`, `ON FG_STG` y `ON FG_IDX` incrustados en casi cada `CREATE TABLE` y `CREATE INDEX`, y `ps_TurismoAnio` está mapeado a ocho filegroups anuales.

```text
   RDS acepta ADD FILEGROUP con ruta D:\rdsdbdata\DATA\ ?
                       |
         +-------------+-------------+
         |                           |
        SI                          NO
         |                           |
  Modo FILEGROUPS             Modo PRIMARY
         |                           |
  41..45 y 47b corren        75-migrar-dw.ps1 adapta
  SIN MODIFICACION           los scripts quitando ON FG_*
         |                           |
  Migracion literal          Particion LOGICA intacta:
  del esquema                funcion, limites, eliminacion
                             de particiones y alineacion
                             de columnstore siguen igual.
                             Solo se pierde la separacion
                             FISICA por archivo, que en RDS
                             no aporta nada porque todo vive
                             sobre un unico volumen EBS.
```

`40-crear-basedatos.rds.sql` prueba la rama buena, cae a la degradada si falla, y deja el veredicto en `dbo.MigracionModo` para que `75-migrar-dw.ps1` sepa cómo seguir. **El resultado de esa bifurcación es contenido del entregable**, no un detalle de implementación.

> **Respondida en la ejecución: RDS los acepta.** `dbo.MigracionModo` quedó en `FILEGROUPS` y los 12 filegroups de usuario —4 por propósito y 8 anuales— se reprodujeron con archivos bajo `D:dsdbdata\DATA\`. Los scripts `41`–`45` y `47b` corrieron **sin una sola modificación**, y el adaptador que quita las cláusulas `ON FG_*` quedó escrito y probado pero sin usar.
>
> La creencia de que un SQL Server gestionado obliga a `PRIMARY` viene de **Azure SQL Database**, y no se traslada a RDS.

---

## 6. Archivos JSON y XML → Amazon S3

| Herramienta | Veredicto | Razón |
|---|---|---|
| **`aws s3 sync`** | **Elegida** | Idempotente, verifica por tamaño y fecha, y no vuelve a subir lo que no cambió |
| Cargar el contenido a tablas | Descartada | Destruiría la evidencia de que la solución integra cuatro tipos de fuente. S3 como *landing zone* cruda es la forma correcta, y el ETL sigue leyendo archivos igual que on-premise |

---

## 7. Orquestación de la infraestructura

| Herramienta | Veredicto | Razón |
|---|---|---|
| **PowerShell + AWS CLI** | **Elegida** | Es el lenguaje que ya usa todo el repositorio (`49`, `50`, `51`, `00-setup-admin.ps1`). No agrega dependencias y el equipo lo sabe leer |
| CloudFormation / Terraform | Descartadas | Correctas para infraestructura duradera. Para seis recursos que viven tres días, el costo de aprendizaje y el estado remoto no se pagan |

---

## 8. Herramientas del laboratorio ya disponibles

Verificadas en la máquina antes de decidir. Que algo ya estuviera instalado y autenticado pesó en el criterio 4:

| Herramienta | Versión | Uso en la migración |
|---|---|---|
| AWS CLI | 2.36.7 | Provisión y S3 |
| `sqlcmd` / `bcp` | 16.0.1000.6 (ODBC 17) | Esquema y carga masiva del DW |
| `mongosh` | 2.5.6 | Verificación de Atlas |
| Python | 3.11.9 | ETL |
| Docker | 28.0.4 | Entorno origen |
| SSMS | 21 | Inspección manual |
| Power BI Desktop | Instalación de Microsoft Store | Repunte del modelo |
| Azure CLI | **no instalado** | Confirma que Azure no era una opción realista |

---

## 9. Documentos relacionados

- `00-docs/07-estrategia-migracion.md` — estrategia, arquitectura destino, riesgos y reversión
- `00-docs/09-inventario-migracion.md` — inventario de objetos con veredicto de portabilidad
- `07-migracion/` — implementación de todo lo decidido aquí
