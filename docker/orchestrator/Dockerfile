# =====================================================================
# Orquestador del "levanta y listo" de TurismoDW.
# Corre los generadores/seed y el ETL contra los otros contenedores.
#
# Trae: Python 3.12 + deps del ETL, ODBC Driver 17 y las herramientas de
# linea de SQL Server (bcp y sqlcmd) que el ETL invoca por nombre, y el
# cliente psql para diagnostico.
# =====================================================================
FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# --- Repositorio de Microsoft (Debian 12) + ODBC 17 + mssql-tools -----
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg apt-transport-https ca-certificates postgresql-client \
    && curl -sSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        msodbcsql17 mssql-tools unixodbc-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# bcp y sqlcmd (v17) al PATH: el ETL los llama por nombre.
ENV PATH="/opt/mssql-tools/bin:${PATH}"

# --- Dependencias de Python del ETL -----------------------------------
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY init.sh /init.sh
RUN chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
