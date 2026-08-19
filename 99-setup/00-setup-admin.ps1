<#
=====================================================================
 ITI-821 - Escenario 8 Turismo Inteligente - Semana 3
 Integrante 1: Alex Herrera
 -------------------------------------------------------------------
 00-setup-admin.ps1

 Prepara la instancia de SQL Server que alojara la base analitica:
 rutas de datos, TCP/IP en el puerto 1433, firewall y el alias de
 cliente TURISMODW.

 REQUIERE EJECUTARSE EN UNA CONSOLA DE POWERSHELL COMO ADMINISTRADOR.

 Uso:
   .\00-setup-admin.ps1                        # instancia por defecto (MSSQLSERVER)
   .\00-setup-admin.ps1 -Instancia DW          # instancia con nombre
   .\00-setup-admin.ps1 -Instancia SQLEXPRESS  # host provisional

 Que instancia indicar:
   Tras instalar Developer Edition siguiendo 01-instalar-developer.md,
   la instancia principal se llama DW:
       .\00-setup-admin.ps1 -Instancia DW

 Tras el failover del Integrante 3, se vuelve a correr apuntando el
 alias al nodo espejo, y ni el ETL ni el .pbix se tocan:
       .\00-setup-admin.ps1 -Instancia MIRROR -DestinoAlias BOSGAME-WINTP
=====================================================================
#>

[CmdletBinding()]
param(
    # Nombre de la instancia. 'MSSQLSERVER' es la instancia por defecto.
    [string] $Instancia = 'MSSQLSERVER',

    # Puerto TCP estatico. Por aqui se conectan Power BI y el ETL.
    [int]    $Puerto = 1433,

    # Raiz de los archivos de datos, log, respaldos y trabajo del ETL.
    [string] $RutaDatos = 'D:\DB\mssql\TurismoDW',

    # Servidor al que apunta el alias TURISMODW.
    [string] $DestinoAlias = 'localhost'
)

$ErrorActionPreference = 'Stop'

function Paso  ($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok    ($t)     { Write-Host "    OK  - $t" -ForegroundColor Green }
function Aviso ($t)     { Write-Host "    !   - $t" -ForegroundColor Yellow }
function Malo  ($t)     { Write-Host "    X   - $t" -ForegroundColor Red }

# --- Verificacion de privilegios ---------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
                [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Este script debe ejecutarse en una consola de PowerShell como Administrador."
}

# --- Resolver la instancia ----------------------------------------------------
# El servicio y la clave del registro se llaman distinto segun sea la instancia
# por defecto o una con nombre. Resolverlo aqui evita tener que editar el script
# a mano, que era como estaba antes y es una fuente segura de errores.
if ($Instancia -eq 'MSSQLSERVER') {
    $servicio    = 'MSSQLSERVER'
    $servidorSql = '.'
} else {
    $servicio    = "MSSQL`$$Instancia"
    $servidorSql = ".\$Instancia"
}

$claveInstancias = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
$idInstancia = (Get-ItemProperty $claveInstancias -ErrorAction SilentlyContinue).$Instancia

if (-not $idInstancia) {
    Malo "La instancia '$Instancia' no existe en esta maquina."
    Write-Host ""
    Write-Host "    Instancias instaladas:" -ForegroundColor Yellow
    (Get-ItemProperty $claveInstancias -ErrorAction SilentlyContinue).PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' } |
        ForEach-Object {
            $ed = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($_.Value)\Setup" `
                    -ErrorAction SilentlyContinue).Edition
            Write-Host ("      {0,-16} {1}" -f $_.Name, $ed) -ForegroundColor Yellow
        }
    Write-Host ""
    throw "Indique una instancia valida con -Instancia."
}

$claveRaiz = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$idInstancia"
$edicion   = (Get-ItemProperty "$claveRaiz\Setup" -ErrorAction SilentlyContinue).Edition

Write-Host "=== Instancia destino ===" -ForegroundColor Cyan
Write-Host "    Instancia : $Instancia   ($idInstancia)"
Write-Host "    Servicio  : $servicio"
Write-Host "    Edicion   : $edicion"

# Avisos por edicion, para que la limitacion no aparezca a mitad de camino.
if ($edicion -like '*Evaluation*') {
    Aviso "Edicion Evaluation: caduca a los 180 dias de instalada."
    Aviso "Si el servicio no arranca, es casi seguro que la licencia vencio."
    Aviso "Solucion: instalar Developer Edition. Ver 01-instalar-developer.md"
}
if ($edicion -like '*Express*') {
    Aviso "Edicion Express: base limitada a 10 GB."
    Aviso "Express solo puede ser TESTIGO de Mirroring, nunca principal ni espejo."
    Aviso "Sirve para validar el ETL, no para la entrega final."
}

# --- Paso 1: rutas de datos ---------------------------------------------------
Paso 1 "Creando rutas de datos en $RutaDatos"
foreach ($sub in 'data','log','backup','etl') {
    $p = Join-Path $RutaDatos $sub
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }

    # La compresion NTFS heredada de la carpeta padre hace fallar CREATE DATABASE
    # con "the file is compressed but does not reside in a read-only database".
    if ((Get-Item $p -Force).Attributes -band [IO.FileAttributes]::Compressed) {
        compact /U /S /A /I /Q "$p\*" | Out-Null
        Ok "$p (se quito la compresion NTFS)"
    } else {
        Ok $p
    }

    # La cuenta de servicio virtual necesita control total sobre estas rutas.
    icacls $p /grant "NT Service\${servicio}:(OI)(CI)F" /T | Out-Null
}
Ok "Permisos otorgados a NT Service\$servicio"

# --- Paso 2: habilitar TCP/IP y fijar el puerto -------------------------------
Paso 2 "Habilitando TCP/IP en $Instancia (puerto $Puerto)"
$tcp = "$claveRaiz\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty -Path $tcp -Name 'Enabled' -Value 1 -Type DWord

foreach ($ip in (Get-ChildItem $tcp | Select-Object -ExpandProperty PSChildName)) {
    $k = "$tcp\$ip"
    Set-ItemProperty -Path $k -Name 'TcpDynamicPorts' -Value ''        -Type String
    Set-ItemProperty -Path $k -Name 'TcpPort'         -Value "$Puerto" -Type String
    if ($ip -ne 'IPAll') { Set-ItemProperty -Path $k -Name 'Enabled' -Value 1 -Type DWord }
}
Ok "TCP/IP habilitado con puerto estatico $Puerto"

# --- Paso 3: arrancar el servicio ---------------------------------------------
Paso 3 "Iniciando el servicio $servicio"
$svc = Get-Service $servicio
Set-Service $servicio -StartupType Automatic
try {
    if ($svc.Status -eq 'Running') {
        Restart-Service $servicio -Force
        Ok "Servicio reiniciado (para aplicar el cambio de TCP)"
    } else {
        Start-Service $servicio
        Ok "Servicio iniciado"
    }
} catch {
    Malo "El servicio no arranco."
    Write-Host "          Revise el ERRORLOG en:" -ForegroundColor Red
    Write-Host "          $((Get-ItemProperty "$claveRaiz\Setup").SQLPath)\Log\ERRORLOG" -ForegroundColor Red
    if ($edicion -like '*Evaluation*') {
        Write-Host "          Causa mas probable: la licencia Evaluation expiro." -ForegroundColor Red
        Write-Host "          Solucion: instalar Developer Edition (01-instalar-developer.md)." -ForegroundColor Red
    }
    throw
}

# --- Paso 4: firewall ---------------------------------------------------------
Paso 4 "Regla de firewall entrante para el puerto $Puerto"
$regla = "SQL Server $Puerto (TurismoDW)"
if (-not (Get-NetFirewallRule -DisplayName $regla -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $regla -Direction Inbound `
        -Protocol TCP -LocalPort $Puerto -Action Allow -Profile Any | Out-Null
    Ok "Regla creada"
} else { Ok "La regla ya existia" }

# --- Paso 5: alias de cliente SQL ---------------------------------------------
# Power BI y el ETL se conectan a TURISMODW, no a un nombre fisico. Tras el
# failover del Integrante 3 basta volver a correr este script apuntando
# -DestinoAlias al nodo espejo: el .pbix no se toca.
Paso 5 "Creando el alias de cliente SQL 'TURISMODW' -> $DestinoAlias,$Puerto"
$valorAlias = "DBMSSOCN,$DestinoAlias,$Puerto"
foreach ($rama in @('HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
                    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo')) {
    if (-not (Test-Path $rama)) { New-Item -Path $rama -Force | Out-Null }
    Set-ItemProperty -Path $rama -Name 'TURISMODW' -Value $valorAlias -Type String
    Ok $rama
}
Aviso "Se registra en 64 y 32 bits: Power BI carga el proveedor de 32 bits."

# --- Paso 6: verificacion -----------------------------------------------------
Paso 6 "Verificacion de conectividad"
$q = "SET NOCOUNT ON; SELECT CONVERT(varchar(60), @@SERVERNAME) + ' | ' + CONVERT(varchar(60), SERVERPROPERTY('Edition'));"
Write-Host "    Directo   : $(& sqlcmd -S "$servidorSql" -E -C -h -1 -W -Q $q 2>&1)"
Write-Host "    Por TCP   : $(& sqlcmd -S "localhost,$Puerto" -E -C -h -1 -W -Q $q 2>&1)"
Write-Host "    Por alias : $(& sqlcmd -S 'TURISMODW' -E -C -h -1 -W -Q $q 2>&1)"

Write-Host "`n=== Preparacion completada ===" -ForegroundColor Green
Write-Host "Siguiente paso:" -ForegroundColor Green
Write-Host "  sqlcmd -S TURISMODW -E -C -i 04-sqlserver\40-crear-basedatos.sql" -ForegroundColor Green
Write-Host ""
Write-Host "Y apuntar el ETL al alias en 05-etl\.env:" -ForegroundColor Green
Write-Host "  SQL_SERVIDOR=TURISMODW" -ForegroundColor Green
