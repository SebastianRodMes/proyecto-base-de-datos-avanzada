# Entorno Docker "levanta y listo" — TurismoDW

Levanta **todo el escenario** (PostgreSQL + MongoDB + SQL Server) y **puebla
`TurismoDW`** de forma reproducible, sin depender de ningún `.bak` ni de la
máquina de nadie. Los datos son deterministas (semilla `8218`), así que
cualquier integrante obtiene exactamente el mismo conjunto.

## Uso

Desde esta carpeta (`docker/`):

```bash
docker compose up -d --build
```

**El primer arranque tarda** (genera ~2 millones de reservas y corre el ETL
completo). Seguí el avance con:

```bash
docker compose logs -f orchestrator
```

Cuando el orquestador imprima *"TurismoDW construida y poblada"*, listo.

## Conexión (SSMS u otra herramienta)

| | |
|---|---|
| Servidor | `localhost,1433` |
| Autenticación | SQL Server |
| Usuario | `sa` |
| Contraseña | `Armagedon45*` |
| Certificado de servidor de confianza | ✔ marcado |

## Comandos útiles

```bash
docker compose ps                    # estado de los servicios
docker compose logs -f orchestrator  # avance de la construcción
docker compose stop                  # apagar (los datos persisten)
docker compose up -d                 # volver a levantar (ya poblada: instantáneo)
docker compose down                  # apagar y borrar contenedores (los volúmenes quedan)
docker compose down -v               # borrar TODO, incluidos los datos (reconstruye de cero)
```

## Cómo está armado

- **postgres**: se autopobla en el primer init con `turismo_ddl.sql` +
  `10-generador-volumen.sql` (los 2M de reservas).
- **mongo**: lo siembra el orquestador con `02-mongodb/20-seed_resenas.py`.
- **sqlserver**: aloja `TurismoDW`. El esquema se crea con
  `sqlserver/40-crear-basedatos.linux.sql` (rutas Linux) + los scripts
  `41`..`45` del proyecto.
- **orchestrator**: corre **una sola vez**. Es idempotente: si `TurismoDW` ya
  tiene datos, no rehace nada. Trae ODBC 17 + `bcp`/`sqlcmd` + las
  dependencias de Python del ETL.

## Notas

- Sólo cubre los Integrantes **2 y 4** (que necesitan el DW poblado). El
  Mirroring del Integrante 3 no entra en este compose (requiere varias
  instancias con endpoints por certificado).
- Si tenías un contenedor suelto `turismo-sql` en el puerto 1433, quitalo
  antes (`docker rm -f turismo-sql`) para que no choque con este `sqlserver`.
