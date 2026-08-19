#!/usr/bin/env bash
# =====================================================================
# init.sh - construye y puebla TurismoDW una sola vez.
#
# Idempotente: si TurismoDW ya tiene datos, no hace nada. Asi 'docker
# compose up' repetido no vuelve a generar los 2 millones de reservas.
#
# Orden:
#   0. esperar a SQL Server
#   1. crear la base (DDL Linux) + esquema (scripts 40..45)
#   2. sembrar MongoDB (Postgres ya viene poblado por su propio initdb)
#   3. correr el ETL
# =====================================================================
set -euo pipefail

PROY=/proyecto
SQLDIR=/sql
SQLCMD="sqlcmd -S ${SQL_SERVIDOR} -U ${SQL_USUARIO} -P ${SQL_PASSWORD} -b"

echo "==> Esperando a SQL Server (${SQL_SERVIDOR})..."
for i in $(seq 1 60); do
    if $SQLCMD -Q "SELECT 1" >/dev/null 2>&1; then break; fi
    sleep 3
    if [ "$i" = "60" ]; then echo "SQL Server no respondio a tiempo."; exit 1; fi
done
echo "==> SQL Server responde."

# --- Idempotencia: si ya hay datos, salir -----------------------------
CNT=$($SQLCMD -h -1 -W -d master -Q \
    "SET NOCOUNT ON; IF DB_ID('TurismoDW') IS NOT NULL EXEC('SELECT COUNT_BIG(*) FROM TurismoDW.dw.FactReserva') ELSE SELECT CAST(-1 AS bigint)" \
    2>/dev/null | head -n1 | tr -dc '0-9-' || echo "-1")
if [ -n "${CNT}" ] && [ "${CNT}" -gt 0 ] 2>/dev/null; then
    echo "==> TurismoDW ya poblada (${CNT} reservas). Nada que hacer."
    exit 0
fi

mkdir -p /work/etl

# --- Esperar a PostgreSQL por TCP (defensa ante healthcheck flojo) -----
echo "==> Esperando a PostgreSQL (${PG_HOST}:${PG_PORT})..."
for i in $(seq 1 120); do
    if pg_isready -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" >/dev/null 2>&1; then break; fi
    sleep 5
    if [ "$i" = "120" ]; then echo "PostgreSQL no respondio a tiempo."; exit 1; fi
done
echo "==> PostgreSQL responde."

# --- 1. Crear base + esquema ------------------------------------------
echo "==> Creando base TurismoDW (DDL Linux)..."
$SQLCMD -i "${SQLDIR}/40-crear-basedatos.linux.sql"

for f in 41-esquema-staging 42-esquema-estrella 43-etl-control 44-transformacion 45-vistas-powerbi; do
    echo "==> Ejecutando ${f}.sql ..."
    $SQLCMD -d TurismoDW -i "${PROY}/04-sqlserver/${f}.sql"
done

# --- 2. Sembrar MongoDB (lee IDs desde Postgres, ya poblado) ----------
echo "==> Sembrando MongoDB (500k resenas + 1.5M interacciones)..."
python "${PROY}/02-mongodb/20-seed_resenas.py" --limpiar

# --- 3. ETL ------------------------------------------------------------
echo "==> Corriendo el ETL..."
cd "${PROY}/05-etl"
python run_etl.py

echo "======================================================================"
echo " TurismoDW construida y poblada. Listo para conectar desde SSMS."
echo "======================================================================"
