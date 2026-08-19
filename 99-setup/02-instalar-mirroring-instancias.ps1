# =====================================================================
# ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
# Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
# -------------------------------------------------------------------
# 02-instalar-mirroring-instancias.ps1
#
# Instala desatendidamente las instancias secundarias necesarias para
# el Database Mirroring (MIRROR y WITNESS) mediante ConfigurationFile.ini,
# habilita TCP/IP, configura el Firewall y crea el Alias TURISMODW.
# =====================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Green
Write-Host '     INSTALACION AUTOMATICA DE INSTANCIAS PARA MIRRORING           ' -ForegroundColor Green
Write-Host '===================================================================' -ForegroundColor Green
Write-Host ''

$setupPath = 'C:\SQL2025\Evaluation_ESN\setup.exe'
if (-not (Test-Path -Path $setupPath)) {
    Write-Host "ERROR: No se encontro el instalador de SQL Server en $setupPath" -ForegroundColor Red
    exit 1
}

$dirActual = $PSScriptRoot
$iniMirror  = Join-Path -Path $dirActual -ChildPath 'ConfigurationFile_MIRROR.ini'
$iniWitness = Join-Path -Path $dirActual -ChildPath 'ConfigurationFile_WITNESS.ini'
$claveInstancias = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'

# --- 1. Instalar instancia MIRROR (Espejo) -----------------------------------
Write-Host '[1/5] Verificando instancia MIRROR (Espejo)...' -ForegroundColor Cyan
$mirrorInst = (Get-ItemProperty -Path $claveInstancias -ErrorAction SilentlyContinue).MIRROR

if (-not $mirrorInst) {
    Write-Host '      Instalando instancia MIRROR... Espere por favor (tarda 3 a 5 minutos)...' -ForegroundColor Yellow
    
    $proc = Start-Process -FilePath $setupPath -ArgumentList "/ConfigurationFile=`"$iniMirror`"" -Wait -PassThru
    
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Host '      OK: Instancia MIRROR instalada exitosamente.' -ForegroundColor Green
    } else {
        Write-Host "      ERROR: Fallo la instalacion de MIRROR. Codigo de salida: $($proc.ExitCode)" -ForegroundColor Red
    }
} else {
    Write-Host '      OK: Instancia MIRROR ya existe.' -ForegroundColor Green
}

# --- 2. Instalar instancia WITNESS (Testigo) ---------------------------------
Write-Host '[2/5] Verificando instancia WITNESS (Testigo)...' -ForegroundColor Cyan
$witnessInst = (Get-ItemProperty -Path $claveInstancias -ErrorAction SilentlyContinue).WITNESS

if (-not $witnessInst) {
    Write-Host '      Instalando instancia WITNESS... Espere por favor (tarda 3 a 5 minutos)...' -ForegroundColor Yellow
    
    $proc = Start-Process -FilePath $setupPath -ArgumentList "/ConfigurationFile=`"$iniWitness`"" -Wait -PassThru
    
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Host '      OK: Instancia WITNESS instalada exitosamente.' -ForegroundColor Green
    } else {
        Write-Host "      ERROR: Fallo la instalacion de WITNESS. Codigo de salida: $($proc.ExitCode)" -ForegroundColor Red
    }
} else {
    Write-Host '      OK: Instancia WITNESS ya existe.' -ForegroundColor Green
}

# --- 3. Habilitar TCP y Servicios --------------------------------------------
Write-Host '[3/5] Iniciando y asegurando servicios SQL Server...' -ForegroundColor Cyan
$servicios = @('MSSQLSERVER', 'MSSQL$MIRROR', 'MSSQL$WITNESS')

foreach ($s in $servicios) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        Set-Service -Name $s -StartupType Automatic
        Start-Service -Name $s -ErrorAction SilentlyContinue
        Write-Host "      OK: Servicio $s activo y en Automatico." -ForegroundColor Green
    }
}

# --- 4. Configurar Firewall de Windows ---------------------------------------
Write-Host '[4/5] Configurando reglas en el Firewall de Windows...' -ForegroundColor Cyan
$puertos = @(
    @{ Name = 'SQL Server (T-SQL)'; Port = 1433 },
    @{ Name = 'SQL Mirroring Principal'; Port = 5022 },
    @{ Name = 'SQL Mirroring Espejo'; Port = 5023 },
    @{ Name = 'SQL Mirroring Testigo'; Port = 5024 }
)

foreach ($p in $puertos) {
    $ruleName = "TurismoDW - $($p.Name) ($($p.Port))"
    netsh advfirewall firewall delete rule name="$ruleName" | Out-Null
    netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$($p.Port) profile=any | Out-Null
    Write-Host "      OK: Puerto $($p.Port) abierto ($($p.Name))." -ForegroundColor Green
}

# --- 5. Configurar Alias TURISMODW -------------------------------------------
Write-Host '[5/5] Configurando Alias de cliente SQL TURISMODW...' -ForegroundColor Cyan
$aliasDestino = 'DBMSSOCN,localhost,1433'
$ramas = @(
    'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo'
)

foreach ($r in $ramas) {
    if (-not (Test-Path -Path $r)) { New-Item -ItemType Directory -Path $r -Force | Out-Null }
    Set-ItemProperty -Path $r -Name 'TURISMODW' -Value $aliasDestino -Type String
}
Write-Host '      OK: Alias TURISMODW configurado apuntando a localhost,1433.' -ForegroundColor Green

# --- 6. Asegurar Permisos en Rutas D:\DB\mssql -------------------------------
$rutas = @(
    'D:\DB\mssql\TurismoDW\data',
    'D:\DB\mssql\TurismoDW\log',
    'D:\DB\mssql\TurismoDW\backup',
    'D:\DB\mssql\TurismoDW\etl',
    'D:\DB\mssql\Mirror\data',
    'D:\DB\mssql\Mirror\log',
    'D:\DB\mssql\Mirror\backup'
)
foreach ($r in $rutas) {
    if (-not (Test-Path -Path $r)) { New-Item -ItemType Directory -Path $r -Force | Out-Null }
}
icacls 'D:\DB\mssql' /grant '*S-1-1-0:(OI)(CI)F' /T | Out-Null
Write-Host '      OK: Permisos asignados en D:\DB\mssql.' -ForegroundColor Green

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Green
Write-Host '  INSTANCIAS Y ENTORNO CONFIGURADOS CON EXITO                      ' -ForegroundColor Green
Write-Host '===================================================================' -ForegroundColor Green
