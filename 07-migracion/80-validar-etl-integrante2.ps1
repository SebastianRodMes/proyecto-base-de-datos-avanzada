<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semanas 3 y 4
    Integrante 2: ETL, integracion y calidad de datos

    Ejecuta una corrida incremental completa contra PostgreSQL RDS,
    MongoDB Atlas, archivos locales y SQL Server RDS. Captura calidad de
    las fuentes antes, la salida completa del ETL y la validacion del
    destino despues en una evidencia versionable sin credenciales.

    Uso:
        .\07-migracion\80-validar-etl-integrante2.ps1
        .\07-migracion\80-validar-etl-integrante2.ps1 -SoloEvidencia
#>

[CmdletBinding()]
param(
    [switch] $SoloEvidencia
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Validacion ETL y calidad | Integrante 2'
$ctx = Obtener-Contexto -Raiz $Raiz
Probar-Endpoint -Identificador $ctx.PgId | Out-Null
Probar-Endpoint -Identificador $ctx.SqlId | Out-Null

$pythonVenv = Join-Path $Raiz '.venv\Scripts\python.exe'
$python = if (Test-Path -LiteralPath $pythonVenv) { $pythonVenv } else { 'python' }
$validador = Join-Path $Raiz '05-etl\validar_calidad.py'
$etl = Join-Path $Raiz '05-etl\run_etl.py'
$evidencia = Join-Path $Raiz '00-docs\05-evidencias\migracion\etl-integrante2-calidad.txt'
$trabajo = Join-Path $env:LOCALAPPDATA 'TurismoDW\etl'
New-Item -ItemType Directory -Force -Path $trabajo | Out-Null

# La configuracion se inyecta solo al proceso actual. No se escriben secretos
# en la evidencia ni se reemplaza el .env del laboratorio local.
$env:PG_HOST = $ctx.PgEndpoint
$env:PG_PORT = '5432'
$env:PG_DB = 'turismo'
$env:PG_USER = $ctx.PgUsuario
$env:PG_PASSWORD = $ctx.PgClave
$env:MONGO_URI = $ctx.MongoUri
$env:MONGO_DB = 'turismo_nosql'
$env:SQL_SERVIDOR = $ctx.SqlEndpoint
$env:SQL_PUERTO = '1433'
$env:SQL_BASE = 'TurismoDW'
$env:SQL_DRIVER = 'ODBC Driver 17 for SQL Server'
$env:SQL_CIFRADO = 'yes'
$env:SQL_USUARIO = $ctx.SqlUsuario
$env:SQL_PASSWORD = $ctx.SqlClave
$env:TURISMO_DIR_TRABAJO = $trabajo

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $Texto = '') {
    $registro.Add($Texto)
    Write-Host $Texto
}
function Ejecutar-Capturando([string] $Titulo, [string[]] $Argumentos) {
    Anotar ''
    Anotar ('=' * 78)
    Anotar $Titulo
    Anotar ('=' * 78)
    # Windows PowerShell convierte stderr de un ejecutable nativo en un
    # ErrorRecord. Con ErrorActionPreference=Stop eso interrumpe el script
    # antes de poder guardar el traceback que justamente necesitamos como
    # evidencia. Se captura el codigo y se decide explicitamente despues.
    $preferenciaAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & $python @Argumentos 2>&1
        $codigo = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $preferenciaAnterior
    }
    foreach ($linea in $salida) { Anotar ([string]$linea) }
    Anotar "CODIGO_SALIDA|$codigo"
    return $codigo
}

Anotar 'ETL INCREMENTAL COMPLETO Y REGISTRO DE CALIDAD'
Anotar ('Fecha UTC|' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Anotar 'Fuentes|PostgreSQL RDS + MongoDB Atlas + JSON + XML'
Anotar 'Destino|SQL Server RDS / TurismoDW'
Anotar 'Credenciales|omitidas'

if (-not $SoloEvidencia) {
    $antes = Ejecutar-Capturando '1. CALIDAD ANTES DEL ETL' @($validador, '--fase', 'antes')
    if ($antes -ne 0) {
        $registro | Set-Content -LiteralPath $evidencia -Encoding utf8
        throw "Fallo la validacion previa. Evidencia parcial: $evidencia"
    }

    $codigoEtl = Ejecutar-Capturando '2. EJECUCION ETL INCREMENTAL (CUATRO FUENTES)' @(
        $etl, '--modo', 'INCREMENTAL'
    )
    if ($codigoEtl -ne 0) {
        $registro | Set-Content -LiteralPath $evidencia -Encoding utf8
        throw "Fallo el ETL. Evidencia parcial: $evidencia"
    }
}

$despues = Ejecutar-Capturando '3. CALIDAD Y BITACORA DESPUES DEL ETL' @(
    $validador, '--fase', 'despues'
)

Anotar ''
Anotar ('RESULTADO_FINAL|' + $(if ($despues -eq 0) { 'APROBADO' } else { 'REVISION_REQUERIDA' }))
$registro | Set-Content -LiteralPath $evidencia -Encoding utf8

if ($despues -ne 0) { throw "La validacion posterior fallo. Revise $evidencia" }
Escribir "Evidencia generada: $evidencia" 'OK'
