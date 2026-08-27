<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    ----------------------------------------------------------------------
    run-etl-cloud.ps1  —  Ejecuta el ETL apuntando a la infraestructura de
    AWS (RDS PostgreSQL + Atlas + RDS SQL Server), SIN tocar el .env local.

    Como funciona
    -------------
    config.py carga el .env con os.environ.setdefault: las variables que ya
    existen en el proceso GANAN sobre el archivo. Este wrapper vuelca
    05-etl/.env.aws al entorno del proceso antes de invocar a Python, de modo
    que el ETL corre contra la nube y el .env local queda intacto. No hay que
    copiar ni restaurar nada.

    Pensado para correr desatendido (tarea programada). Por defecto usa el
    modo INCREMENTAL: solo procesa lo insertado en las fuentes cloud desde la
    ultima corrida, usando las marcas de agua de etl.Marca. NUNCA limpia las
    marcas de MONGODB (eso duplicaria las tablas de Mongo; ver 11-traspaso).

    Uso:
        .\05-etl\run-etl-cloud.ps1                      # incremental, todas las fuentes
        .\05-etl\run-etl-cloud.ps1 -Modo FULL          # recarga completa cloud
        .\05-etl\run-etl-cloud.ps1 -ArgsExtra '--solo-pg'   # solo PostgreSQL
#>

[CmdletBinding()]
param(
    [ValidateSet('INCREMENTAL','FULL')]
    [string] $Modo = 'INCREMENTAL',
    [string] $ArgsExtra = ''
)

$ErrorActionPreference = 'Stop'
$DirEtl   = $PSScriptRoot
$EnvAws   = Join-Path $DirEtl '.env.aws'
$Python   = Join-Path $DirEtl '.venv\Scripts\python.exe'
$DirLogs  = Join-Path $DirEtl 'logs'
$RunEtl   = Join-Path $DirEtl 'run_etl.py'

if (-not (Test-Path $EnvAws)) { throw "No existe $EnvAws. Genere la configuracion cloud (ver 11-traspaso-cloud.md 3.4)." }
if (-not (Test-Path $Python)) { throw "No existe el venv en $Python. Cree con: python -m venv .venv; .\.venv\Scripts\pip install -r requirements.txt" }

New-Item -ItemType Directory -Force -Path $DirLogs | Out-Null
$sello = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $DirLogs "etl-cloud-$sello.log"

# --- Volcar .env.aws al entorno del proceso (gana sobre .env via setdefault) ---
Get-Content $EnvAws | ForEach-Object {
    $l = $_.Trim()
    if (-not $l -or $l.StartsWith('#') -or ($l -notmatch '=')) { return }
    $k, $v = $l -split '=', 2
    $k = $k.Trim(); $v = $v.Trim().Trim('"').Trim("'")
    Set-Item -Path "Env:$k" -Value $v
}

# Conexion a RDS for PostgreSQL sin TLS, a proposito.
#
# Esta red (ISP domestico) RESETEA el handshake TLS del protocolo PostgreSQL
# ("SSL SYSCALL error: Connection reset by peer"), mientras el texto plano si
# alcanza el servidor. El TLS de SQL Server (1433) no se ve afectado. Como no
# se puede arreglar desde el cliente, se desactivo rds.force_ssl en el
# parameter group 'turismodw-pg16' y aqui se pide conexion en claro. El riesgo
# esta acotado: el security group solo admite la IP registrada y los datos son
# de laboratorio. libpq/psycopg2 honran PGSSLMODE.
#
# Para volver a TLS cuando se corra desde una red que lo permita: poner
# rds.force_ssl=1 en el parameter group y cambiar esto a 'require'.
if (-not $env:PGSSLMODE) { $env:PGSSLMODE = 'disable' }

# bcp sin cifrado, obligado por la version de las herramientas instaladas.
#
# Esta maquina tiene el bcp de ODBC 17, que NO soporta -u ni -N: no puede
# cifrar. config.py agrega -u cuando SQL_CIFRADO esta activo, pensando en el
# bcp de ODBC 18 (que cifra por omision y usa -u para confiar en el cert de
# RDS). Con bcp 17, ese -u produce "unknown option u" y la carga falla.
#
# RDS for SQL Server NO fuerza TLS (verificado: sqlcmd y pyodbc conectan sin
# cifrar), asi que se apaga SQL_CIFRADO: bcp no recibe -u y la cadena ODBC no
# pide Encrypt. El canal queda en claro, acotado por el security group a una
# sola IP. Para cifrar habria que instalar las herramientas de ODBC 18 y
# volver a poner SQL_CIFRADO=yes.
$env:SQL_CIFRADO = ''

# El directorio intermedio de bcp debe existir (bcp transmite desde el cliente).
if ($env:TURISMO_DIR_TRABAJO) { New-Item -ItemType Directory -Force -Path $env:TURISMO_DIR_TRABAJO | Out-Null }

$extra = @()
if ($ArgsExtra) { $extra = $ArgsExtra -split '\s+' }

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ETL cloud ($Modo) -> $($env:SQL_SERVIDOR)" -ForegroundColor Cyan
Write-Host "  log: $log" -ForegroundColor Gray

Push-Location $DirEtl
try {
    & $Python $RunEtl --modo $Modo @extra 2>&1 | Tee-Object -FilePath $log
    $codigo = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ETL cloud finalizo con codigo $codigo" -ForegroundColor $(if ($codigo -eq 0) {'Green'} else {'Yellow'})
exit $codigo
