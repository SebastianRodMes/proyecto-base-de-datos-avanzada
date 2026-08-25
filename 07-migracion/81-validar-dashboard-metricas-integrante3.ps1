<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semanas 3 y 4
    Integrante 3: Erick - Dashboard y Metricas de Negocio

    81-validar-dashboard-metricas-integrante3.ps1
    ----------------------------------------------------------------------
    Ejecuta la certificacion completa de las 52 metricas y KPIs del catalogo
    de negocio contra SQL Server (local o RDS Cloud).
    Comprueba los rangos logicos, la paridad DAX vs SQL y emite el informe
    de consistencia en 00-docs/05-evidencias/migracion/dashboard-metricas-negocio.txt.

    Uso:
        .\07-migracion\81-validar-dashboard-metricas-integrante3.ps1 -Local
        .\07-migracion\81-validar-dashboard-metricas-integrante3.ps1
        .\07-migracion\81-validar-dashboard-metricas-integrante3.ps1 -SoloEvidencia
#>

[CmdletBinding()]
param(
    [switch] $Local,
    [switch] $SoloEvidencia,
    [string] $Servidor,
    [string] $Usuario,
    [string] $Clave
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
$archivoSql = Join-Path $Raiz '04-sqlserver\46b-validacion-metricas-negocio.sql'
$archivoEvidencia = Join-Path $Raiz '00-docs\05-evidencias\migracion\dashboard-metricas-negocio.txt'

Write-Host ''
Write-Host ('=' * 78)
Write-Host " ITI-821 | Validacion de Metricas de Negocio y Dashboard | Integrante 3"
Write-Host ('=' * 78)

$srv = $Servidor
$usr = $Usuario
$pwd = $Clave
$modoEntorno = if ($Local) { "LOCAL (Docker / On-Premise)" } else { "CLOUD (Amazon RDS SQL Server)" }

if ($Local) {
    if (-not $srv) { $srv = 'localhost,1433' }
    if (-not $usr) { $usr = 'sa' }
    if (-not $pwd) { $pwd = 'TurismoDW#2026' }
}
else {
    if (-not $srv) {
        if (Test-Path (Join-Path $PSScriptRoot 'comun.ps1')) {
            . (Join-Path $PSScriptRoot 'comun.ps1')
            try {
                $ctx = Obtener-Contexto -Raiz $Raiz
                $srv = "$($ctx.SqlEndpoint),1433"
                $usr = $ctx.SqlUsuario
                $pwd = $ctx.SqlClave
            }
            catch {
                Write-Host "[AVISO] No se pudo obtener contexto cloud automático: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "[INFO]  Utilizando parámetros por defecto para modo local..." -ForegroundColor Cyan
                $srv = 'localhost,1433'
                $usr = 'sa'
                $pwd = 'TurismoDW#2026'
                $modoEntorno = "LOCAL (Fallback)"
            }
        }
    }
}

Write-Host "[INFO]  Entorno evaluado : $modoEntorno" -ForegroundColor Cyan
Write-Host "[INFO]  Servidor destino : $srv" -ForegroundColor Cyan
Write-Host "[INFO]  Script T-SQL     : $archivoSql" -ForegroundColor Cyan

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $Texto = '') {
    $registro.Add($Texto)
    Write-Host $Texto
}

Anotar '====================================================================='
Anotar ' REPORTE DE CERTIFICACION DE METRICAS DE NEGOCIO (INTEGRANTE 3: ERICK)'
Anotar ' ITI-821 · Escenario 8: Turismo Inteligente · Semanas 3 y 4'
Anotar (' Fecha Ejecucion UTC : ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
Anotar " Entorno Evaluado    : $modoEntorno"
Anotar " Servidor Destino    : $srv"
Anotar ' Base de Datos       : TurismoDW'
Anotar '====================================================================='
Anotar ''

if (-not $SoloEvidencia) {
    $cmdArgs = @(
        '-S', $srv,
        '-U', $usr,
        '-P', $pwd,
        '-C',
        '-N',
        '-d', 'TurismoDW',
        '-i', $archivoSql,
        '-b'
    )

    $preferenciaAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $salida = & sqlcmd @cmdArgs 2>&1
        $codigo = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $preferenciaAnterior
    }

    foreach ($linea in $salida) {
        Anotar ([string]$linea)
    }

    Anotar ''
    Anotar ('=' * 78)
    Anotar " CODIGO DE SALIDA SQLCMD: $codigo"
    Anotar ('=' * 78)

    # Guardar evidencia
    $dirEvidencia = Split-Path -Parent $archivoEvidencia
    if (-not (Test-Path $dirEvidencia)) {
        New-Item -ItemType Directory -Force -Path $dirEvidencia | Out-Null
    }
    $registro | Set-Content -LiteralPath $archivoEvidencia -Encoding utf8
    Write-Host "`n[OK]    Evidencia guardada exitosamente en:" -ForegroundColor Green
    Write-Host "        $archivoEvidencia" -ForegroundColor Green
}
else {
    Write-Host "[INFO]  Modo SoloEvidencia activado. Leyendo evidencia existente..." -ForegroundColor Cyan
    if (Test-Path $archivoEvidencia) {
        Get-Content $archivoEvidencia | ForEach-Object { Write-Host $_ }
    }
    else {
        Write-Host "[AVISO] No existe el archivo de evidencia previo." -ForegroundColor Yellow
    }
}
