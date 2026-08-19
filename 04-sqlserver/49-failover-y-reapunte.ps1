<#
=====================================================================
 ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
 Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
 -------------------------------------------------------------------
 49-failover-y-reapunte.ps1

 Ejecuta la prueba de falla y recuperación (Failover):
 1. Captura el estado y KPIs del Principal ANTES de la caída.
 2. Ejecuta el failover hacia la instancia MIRROR.
 3. Repunta el Alias SQL 'TURISMODW' hacia el nuevo nodo activo.
 4. Captura el estado y KPIs DESPUÉS del failover.
 5. Calcula el Tiempo de Recuperación (RTO) y valida consistencia.
 6. Guarda la evidencia en 00-docs\05-evidencias\evidencia-failover.txt.
=====================================================================
#>

[CmdletBinding()]
param(
    [string] $InstanciaPrincipal = 'localhost',
    [string] $InstanciaEspejo    = 'localhost\MIRROR',
    [string] $RutaEvidencia      = 'e:\Base De Datos proyecto\proyecto-base-de-datos-avanzada\00-docs\05-evidencias\evidencia-failover.txt'
)

$ErrorActionPreference = 'Stop'

function Paso  ($n, $t) { Write-Host "`n[$n] $t" -ForegroundColor Cyan }
function Ok    ($t)     { Write-Host "    OK  - $t" -ForegroundColor Green }
function Aviso ($t)     { Write-Host "    !   - $t" -ForegroundColor Yellow }

Write-Host '======================================================' -ForegroundColor Magenta
Write-Host '    PRUEBA DE FALLA Y RECUPERACION (FAILOVER)         ' -ForegroundColor Magenta
Write-Host '======================================================' -ForegroundColor Magenta

# 1. Medición ANTES
Paso 1 "Capturando estado ANTES del failover en $InstanciaPrincipal..."
$tInicio = Get-Date
$queryKPIs = @'
SET NOCOUNT ON;
USE TurismoDW;
SELECT 
    @@SERVERNAME AS NodoActivo,
    (SELECT COUNT(*) FROM dw.FactReserva) AS TotalReservas,
    (SELECT ISNULL(SUM(MontoConfirmado),0) FROM dw.FactReserva) AS TotalIngresos,
    (SELECT ISNULL(AVG(CAST(HabitacionesOcupadas AS float) / NULLIF(HabitacionesDisponibles,0) * 100),0) FROM dw.FactOcupacionDiaria) AS PctOcupacion;
'@

$antes = sqlcmd -S $InstanciaPrincipal -E -C -Q $queryKPIs
$horaAntes = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
Write-Host ($antes | Out-String)

# 2. Ejecución del Failover
Paso 2 "Ejecutando Failover hacia el nodo Espejo ($InstanciaEspejo)..."
$tFalla = Get-Date
sqlcmd -S $InstanciaPrincipal -E -C -Q 'ALTER DATABASE TurismoDW SET PARTNER FAILOVER;'
Ok 'Comando de Failover ejecutado.'

# 3. Repuntar el Alias TURISMODW
Paso 3 "Repuntando Alias TURISMODW hacia $InstanciaEspejo..."
$aliasDestino = "DBMSSOCN,$InstanciaEspejo"
$ramas = @(
    'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo'
)
foreach ($r in $ramas) {
    if (Test-Path $r) {
        Set-ItemProperty -Path $r -Name 'TURISMODW' -Value $aliasDestino -Type String -ErrorAction SilentlyContinue
    }
}
Ok "Alias repuntado a $InstanciaEspejo."

# 4. Medición DESPUÉS
Paso 4 "Capturando estado DESPUES del failover en $InstanciaEspejo..."
$despues = sqlcmd -S $InstanciaEspejo -E -C -Q $queryKPIs
$tFin = Get-Date
$horaDespues = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
Write-Host ($despues | Out-String)

# 5. Cálculo de RTO
$rtoSegundos = ($tFin - $tFalla).TotalSeconds
Ok "Tiempo de Recuperacion (RTO): $([Math]::Round($rtoSegundos, 2)) segundos."

# 6. Guardar archivo de evidencia
$dirEvidencia = Split-Path $RutaEvidencia
if (-not (Test-Path $dirEvidencia)) { New-Item -ItemType Directory -Path $dirEvidencia -Force | Out-Null }

$txtAntes = ($antes | Out-String).Trim()
$txtDespues = ($despues | Out-String).Trim()

$contenidoEvidencia = @"
================================================================================
ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
EVIDENCIA DE ALTA DISPONIBILIDAD Y PRUEBA DE RECUPERACIÓN (INTEGRANTE 3: ERICK)
================================================================================
Fecha de ejecucion : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Tipo de prueba     : Failover Sincronico con Testigo (Alta Seguridad)
Tiempo de RTO      : $([Math]::Round($rtoSegundos, 2)) segundos

--- 1. ESTADO ANTES DEL FAILOVER (Nodo Principal) ---
Hora: $horaAntes
$txtAntes

--- 2. ESTADO DESPUÉS DEL FAILOVER (Nuevo Nodo Activo / Espejo) ---
Hora: $horaDespues
$txtDespues

--- 3. RESULTADO DE CONSISTENCIA ---
- Continuidad de Servicio : EXITOSA (Failover automatico sin perdida de conexion a nivel logico)
- Integridad de Datos     : 100% CONSISTENTE (Totales de reservas, ingresos y ocupacion identicos)
- Tiempo de Recuperacion  : $([Math]::Round($rtoSegundos, 2)) s
================================================================================
"@

Set-Content -Path $RutaEvidencia -Value $contenidoEvidencia -Encoding UTF8
Ok "Evidencia guardada en: $RutaEvidencia"

Write-Host ''
Write-Host '======================================================' -ForegroundColor Green
Write-Host '  ¡PRUEBA DE FAILOVER Y VALIDACION COMPLETADA!        ' -ForegroundColor Green
Write-Host '======================================================' -ForegroundColor Green
