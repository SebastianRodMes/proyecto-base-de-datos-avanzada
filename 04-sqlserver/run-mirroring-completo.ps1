<#
=====================================================================
 ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
 Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
 -------------------------------------------------------------------
 run-mirroring-completo.ps1

 Orquestador completo del Database Mirroring:
  Paso 1: Ejecuta 48a-principal-setup.sql en Principal (localhost)
  Paso 2: Ejecuta 48b-espejo-setup.sql en Espejo (localhost\MIRROR)
  Paso 3: Ejecuta 48c-testigo-setup.sql en Testigo (localhost\WITNESS)
  Paso 4: Ejecuta 48d-principal-establecer-sesion.sql en Principal
  Paso 5: Muestra estado sincronizado
=====================================================================
#>

[CmdletBinding()]
param(
    [string] $Principal = 'localhost',
    [string] $Espejo    = 'localhost\MIRROR',
    [string] $Testigo   = 'localhost\WITNESS'
)

$ErrorActionPreference = 'Stop'

function Paso  ($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok    ($t)     { Write-Host "    OK  - $t" -ForegroundColor Green }
function Malo  ($t)     { Write-Host "    X   - $t" -ForegroundColor Red }

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "     CONFIGURACIÓN COMPLETA DE DATABASE MIRRORING     " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Configurar Principal
Paso 1 "Configurando Principal ($Principal) y generando Backups..."
try {
    sqlcmd -S $Principal -E -C -i "$PSScriptRoot\48a-principal-setup.sql"
    Ok "Principal configurado y backups creados."
} catch {
    Malo "Error en el Principal: $_"
    exit 1
}

# 2. Configurar Espejo
Paso 2 "Configurando Espejo ($Espejo) y restaurando TurismoDW (NORECOVERY)..."
try {
    sqlcmd -S $Espejo -E -C -i "$PSScriptRoot\48b-espejo-setup.sql"
    Ok "Espejo configurado y base restaurada en modo NORECOVERY."
} catch {
    Malo "Error en el Espejo: $_"
    exit 1
}

# 3. Configurar Testigo
Paso 3 "Configurando Testigo ($Testigo) y su Endpoint..."
try {
    sqlcmd -S $Testigo -E -C -i "$PSScriptRoot\48c-testigo-setup.sql"
    Ok "Testigo configurado."
} catch {
    Malo "Error en el Testigo: $_"
    exit 1
}

# 4. Establecer Sesion en Principal
Paso 4 "Estableciendo la sesión de Mirroring con SAFETY FULL..."
try {
    sqlcmd -S $Principal -E -C -i "$PSScriptRoot\48d-principal-establecer-sesion.sql"
    Ok "Sesión de Mirroring iniciada y sincronizada."
} catch {
    Malo "Error al establecer sesión: $_"
    exit 1
}

Write-Host "`n======================================================" -ForegroundColor Green
Write-Host "  ¡DATABASE MIRRORING CONFIGURADO Y ACTIVO AL 100%!   " -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
