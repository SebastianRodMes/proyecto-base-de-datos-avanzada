<#
=====================================================================
 ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
 Integrante 4 - Prueba de recuperacion y consistencia
 --------------------------------------------------------------------
 Ejecuta un reemplazo controlado de rol entre las dos replicas Always On,
 repunta el endpoint estable de Power BI, calcula el RTO, compara KPIs y
 finalmente detiene el nodo anterior para demostrar que el nuevo principal
 continua sirviendo datos.
=====================================================================
#>

[CmdletBinding()]
param(
    [string] $ComposeFile = (Join-Path $PSScriptRoot '..\docker\docker-compose.yml'),
    [string] $RutaEvidencia = (Join-Path $PSScriptRoot '..\00-docs\05-evidencias\evidencia-failover.txt'),
    [bool] $ProbarCaidaNodoAnterior = $true
)

$ErrorActionPreference = 'Stop'
$ComposeFile = (Resolve-Path $ComposeFile).Path
$RaizProyecto = Split-Path (Split-Path $ComposeFile -Parent) -Parent

function Ejecutar-Sql([string] $Servidor, [string] $Consulta) {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $salida = & sqlcmd -S $Servidor -U sa -P $script:SqlPassword -C -b -Q $Consulta 2>&1
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = $anterior
    if ($codigo -ne 0) { throw "SQL fallo en ${Servidor}:`n$($salida | Out-String)" }
    return $salida
}

function Consultar-Escalar([string] $Servidor, [string] $Consulta) {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $salida = & sqlcmd -S $Servidor -U sa -P $script:SqlPassword -C -b -h -1 -W -Q "SET NOCOUNT ON; $Consulta" 2>&1
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = $anterior
    if ($codigo -ne 0) { throw "Consulta fallo en ${Servidor}:`n$($salida | Out-String)" }
    return (($salida | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1).Trim())
}

function Obtener-Kpis([string] $Servidor) {
    $consulta = @"
SET NOCOUNT ON;
USE TurismoDW;
SELECT CONCAT(
  CONVERT(nvarchar(128),@@SERVERNAME),'|',
  CONVERT(varchar(30),(SELECT COUNT_BIG(*) FROM dw.FactReserva)),'|',
  CONVERT(varchar(50),CONVERT(decimal(20,2),(SELECT SUM(MontoTotal) FROM dw.FactReserva))),'|',
  CONVERT(varchar(50),CONVERT(decimal(20,2),(SELECT SUM(MontoConfirmado) FROM dw.FactReserva))),'|',
  CONVERT(varchar(30),CONVERT(decimal(10,4),
    (SELECT 100.0*SUM(CONVERT(bigint,HabitacionesOcupadas)) /
            NULLIF(SUM(CONVERT(bigint,HabitacionesDisponibles)),0)
     FROM dw.FactOcupacionDiaria))),'|',
  CONVERT(varchar(30),(SELECT COUNT_BIG(*) FROM dw.FactResena)),'|',
  CONVERT(varchar(30),(SELECT COUNT_BIG(*) FROM dw.FactInteraccionWeb)),'|',
  CONVERT(varchar(30),(SELECT CHECKSUM_AGG(BINARY_CHECKSUM(
      ReservaId,ClienteKey,FechaInicioKey,MontoTotal)) FROM dw.FactReserva))
);
"@
    $linea = Consultar-Escalar $Servidor $consulta
    $v = $linea -split '\|'
    if ($v.Count -ne 8) { throw "Respuesta KPI inesperada desde ${Servidor}: $linea" }
    return [pscustomobject]@{
        Nodo = $v[0]
        Reservas = $v[1]
        MontoTotal = $v[2]
        MontoConfirmado = $v[3]
        PctOcupacion = $v[4]
        Resenas = $v[5]
        Interacciones = $v[6]
        ChecksumReservas = $v[7]
    }
}

function Formatear-Kpis([object] $Kpis) {
    return ($Kpis | Format-List | Out-String).Trim()
}

function Esperar-Endpoint([int] $Timeout = 120) {
    $limite = (Get-Date).AddSeconds($Timeout)
    do {
        try { return Obtener-Kpis 'localhost,14330' }
        catch { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $limite)
    throw 'El endpoint HA no respondio dentro del tiempo limite.'
}

function Esperar-SaludContenedor([string] $Contenedor, [int] $Timeout = 180) {
    $limite = (Get-Date).AddSeconds($Timeout)
    do {
        $salud = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $Contenedor).Trim()
        if ($salud -eq 'healthy') { return }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $limite)
    throw "El contenedor $Contenedor no recupero salud."
}

Push-Location $RaizProyecto
try {
    $PrincipalId = (& docker compose -f $ComposeFile --profile ha ps -q sqlserver).Trim()
    $SecundarioId = (& docker compose -f $ComposeFile --profile ha ps -q sqlserver-secondary).Trim()
    if (-not $PrincipalId -or -not $SecundarioId) { throw 'Las dos replicas HA deben estar iniciadas.' }

    $lineaPassword = & docker inspect $PrincipalId --format '{{range .Config.Env}}{{println .}}{{end}}' |
        Where-Object { $_ -like 'MSSQL_SA_PASSWORD=*' } | Select-Object -First 1
    $script:SqlPassword = $lineaPassword.Substring('MSSQL_SA_PASSWORD='.Length)

    $Principal = 'localhost,1433'
    $Secundario = 'localhost,1434'
    $Endpoint = 'localhost,14330'

    Write-Host '==> Verificando sincronizacion previa' -ForegroundColor Cyan
    $estadoPrevio = Consultar-Escalar $Secundario @"
SELECT COALESCE(MAX(synchronization_state_desc),'NO_DISPONIBLE')
FROM sys.dm_hadr_database_replica_states
WHERE is_local=1 AND database_id=DB_ID(N'TurismoDW');
"@
    if ($estadoPrevio -ne 'SYNCHRONIZED') { throw "La replica secundaria esta $estadoPrevio; se cancela el failover." }

    $antes = Obtener-Kpis $Endpoint
    $horaAntes = Get-Date
    Write-Host (Formatear-Kpis $antes)

    Write-Host '==> Ejecutando promocion manual de la replica sincronizada' -ForegroundColor Cyan
    $inicioFalla = Get-Date
    $promocionTerminada = $false
    try {
        # CLUSTER_TYPE=NONE no tiene un recurso de cluster que arbitre el
        # cambio. SQL Server 2022 requiere dejar offline el grupo anterior y
        # promover explicitamente el secundario. SYNCHRONIZED + ausencia de
        # escrituras permite comprobar despues que no hubo perdida real.
        Ejecutar-Sql $Principal "ALTER AVAILABILITY GROUP [ag_TurismoDW] OFFLINE;" | Out-Null
        Ejecutar-Sql $Secundario "ALTER AVAILABILITY GROUP [ag_TurismoDW] FORCE_FAILOVER_ALLOW_DATA_LOSS;" | Out-Null
        $promocionTerminada = $true
    }
    catch {
        if (-not $promocionTerminada) {
            try { Ejecutar-Sql $Principal "ALTER AVAILABILITY GROUP [ag_TurismoDW] ONLINE;" | Out-Null }
            catch { Write-Warning 'No fue posible devolver el grupo anterior a ONLINE automaticamente.' }
        }
        throw
    }

    try { Ejecutar-Sql $Principal "ALTER AVAILABILITY GROUP [ag_TurismoDW] SET (ROLE=SECONDARY);" | Out-Null }
    catch { Write-Warning 'El nodo anterior reasignara su rol al reconectarse; la promocion ya termino.' }

    $env:SQL_HA_BACKEND = 'sqlserver-secondary'
    & docker compose -f $ComposeFile --profile ha up -d --no-deps --force-recreate sql-ha-endpoint
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo repuntar el endpoint HA.' }

    $despues = Esperar-Endpoint 180
    $finRecuperacion = Get-Date
    $rto = [math]::Round(($finRecuperacion - $inicioFalla).TotalSeconds, 3)
    Write-Host "    RTO: $rto segundos" -ForegroundColor Green
    Write-Host (Formatear-Kpis $despues)

    $campos = 'Reservas','MontoTotal','MontoConfirmado','PctOcupacion','Resenas','Interacciones','ChecksumReservas'
    $diferencias = @($campos | Where-Object { [string]$antes.$_ -ne [string]$despues.$_ })
    $nodoCambio = $antes.Nodo -ne $despues.Nodo
    $consistente = $diferencias.Count -eq 0

    $pruebaCaida = 'NO EJECUTADA'
    $kpisConNodoAnteriorDetenido = $null
    if ($ProbarCaidaNodoAnterior) {
        Write-Host '==> Deteniendo el nodo anterior y comprobando continuidad' -ForegroundColor Cyan
        & docker stop $PrincipalId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo detener el nodo anterior.' }
        try {
            $kpisConNodoAnteriorDetenido = Esperar-Endpoint 60
            $pruebaCaida = if ($kpisConNodoAnteriorDetenido.Nodo -eq $despues.Nodo) { 'EXITOSA' } else { 'REVISAR' }
        }
        finally {
            & docker start $PrincipalId | Out-Null
            if ($LASTEXITCODE -eq 0) { Esperar-SaludContenedor $PrincipalId 240 }
        }
    }

    Write-Host '==> Restaurando la redundancia en el nodo anterior' -ForegroundColor Cyan
    Ejecutar-Sql $Principal "ALTER DATABASE [TurismoDW] SET HADR RESUME;" | Out-Null
    $limiteResincronizacion = (Get-Date).AddMinutes(3)
    do {
        $estadoReplicaAnterior = Consultar-Escalar $Principal @"
SELECT COALESCE(MAX(synchronization_state_desc),'NO_DISPONIBLE')
FROM sys.dm_hadr_database_replica_states
WHERE is_local=1 AND database_id=DB_ID(N'TurismoDW');
"@
        if ($estadoReplicaAnterior -eq 'SYNCHRONIZED') { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $limiteResincronizacion)
    if ($estadoReplicaAnterior -ne 'SYNCHRONIZED') {
        $pruebaCaida = 'REVISAR: el nodo anterior no resincronizo'
    }

    $estadoFinal = Ejecutar-Sql $Secundario @"
SET NOCOUNT ON;
SELECT @@SERVERNAME AS Nodo,ars.role_desc AS Rol,
       drs.synchronization_state_desc AS Sincronizacion,
       drs.synchronization_health_desc AS Salud
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id=ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars
  ON ars.group_id=ar.group_id AND ars.replica_id=ar.replica_id AND ars.is_local=1
JOIN sys.dm_hadr_database_replica_states drs
  ON drs.group_id=ar.group_id AND drs.replica_id=ar.replica_id AND drs.is_local=1
WHERE ag.name=N'ag_TurismoDW' AND drs.database_id=DB_ID(N'TurismoDW');
"@
    $estadoFinalTexto = (($estadoFinal | ForEach-Object { ([string]$_).TrimEnd() }) -join [Environment]::NewLine).Trim()

    $resultado = if ($consistente -and $nodoCambio -and $pruebaCaida -ne 'REVISAR') { 'EXITOSO' } else { 'REVISAR' }
    $contenido = @"
================================================================================
ITI-821 - EVIDENCIA REAL DE FAILOVER Y RECUPERACION
================================================================================
Fecha de ejecucion      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Estrategia              : Always On, 2 replicas sincronicas, CLUSTER_TYPE=NONE
Tipo de prueba          : Reemplazo controlado + caida del nodo anterior
Endpoint de Power BI    : localhost,14330
Hora antes              : $($horaAntes.ToString('yyyy-MM-dd HH:mm:ss.fff'))
Hora recuperacion       : $($finRecuperacion.ToString('yyyy-MM-dd HH:mm:ss.fff'))
RTO medido              : $rto segundos
Nodo cambio             : $nodoCambio ($($antes.Nodo) -> $($despues.Nodo))
Consistencia de KPIs    : $consistente
Campos diferentes       : $(if($diferencias.Count){$diferencias -join ', '}else{'ninguno'})
Caida nodo anterior     : $pruebaCaida
RESULTADO FINAL         : $resultado

--- ANTES DEL FAILOVER ---
$(Formatear-Kpis $antes)

--- DESPUES DEL FAILOVER ---
$(Formatear-Kpis $despues)

--- CON EL NODO ANTERIOR DETENIDO ---
$(if($kpisConNodoAnteriorDetenido){Formatear-Kpis $kpisConNodoAnteriorDetenido}else{'No ejecutado'})

--- ESTADO DEL NUEVO PRINCIPAL ---
$estadoFinalTexto
Estado del nodo anterior al cerrar la prueba: $estadoReplicaAnterior
================================================================================
"@
    $directorio = Split-Path $RutaEvidencia -Parent
    if (-not (Test-Path $directorio)) { New-Item -ItemType Directory -Force -Path $directorio | Out-Null }
    Set-Content -LiteralPath $RutaEvidencia -Value $contenido -Encoding UTF8

    if ($resultado -ne 'EXITOSO') { throw "La prueba termino con resultado $resultado. Revise $RutaEvidencia" }
    Write-Host "`nPrueba completada. Evidencia: $RutaEvidencia" -ForegroundColor Green
}
finally {
    Pop-Location
}
