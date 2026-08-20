<#
=====================================================================
 ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
 Integrantes 3 y 4 - Alta disponibilidad y validacion
 --------------------------------------------------------------------
 50-configurar-alwayson-docker.ps1

 Configura dos replicas SQL Server 2022 Developer en Docker como un
 Availability Group sincronico de CLUSTER_TYPE = NONE. Esta variante
 permite probar un failover manual en una sola computadora sin instalar
 un cluster Windows/Pacemaker. El endpoint estable de cliente queda en
 localhost,14330 y es el que debe consumir Power BI.

 Database Mirroring no esta soportado por SQL Server sobre Linux; por eso
 los scripts 48a..48d siguen reservados para las instancias Windows del
 Integrante 3 y este script implementa la alternativa Always On local.
=====================================================================
#>

[CmdletBinding()]
param(
    [string] $ComposeFile = (Join-Path $PSScriptRoot '..\docker\docker-compose.yml'),
    [int] $TimeoutSincronizacionSegundos = 1200,
    [string] $RutaEvidencia = (Join-Path $PSScriptRoot '..\00-docs\05-evidencias\alwayson-configuracion.txt')
)

$ErrorActionPreference = 'Stop'
$ComposeFile = (Resolve-Path $ComposeFile).Path
$RaizProyecto = Split-Path (Split-Path $ComposeFile -Parent) -Parent

function Paso([string] $Texto) {
    Write-Host "`n==> $Texto" -ForegroundColor Cyan
}

function Ejecutar-DockerCompose([string[]] $Argumentos) {
    & docker compose -f $ComposeFile @Argumentos
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose fallo: $($Argumentos -join ' ')"
    }
}

function Esperar-Salud([string] $Servicio, [int] $Timeout = 180) {
    $limite = (Get-Date).AddSeconds($Timeout)
    do {
        $id = (& docker compose -f $ComposeFile --profile ha ps -q $Servicio).Trim()
        if ($id) {
            $salud = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $id).Trim()
            if ($salud -eq 'healthy') { return $id }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $limite)
    throw "El servicio $Servicio no alcanzo el estado healthy."
}

function Obtener-Password([string] $Contenedor) {
    $linea = & docker inspect $Contenedor --format '{{range .Config.Env}}{{println .}}{{end}}' |
        Where-Object { $_ -like 'MSSQL_SA_PASSWORD=*' } | Select-Object -First 1
    if (-not $linea) { throw "No se encontro MSSQL_SA_PASSWORD en $Contenedor." }
    return $linea.Substring('MSSQL_SA_PASSWORD='.Length)
}

function Ejecutar-Sql([string] $Servidor, [string] $Consulta, [switch] $Silencioso) {
    # Windows PowerShell convierte cualquier texto de stderr en ErrorRecord.
    # sqlcmd envia tambien mensajes informativos (por ejemplo, el cambio de
    # contexto) a ese canal cuando se usa -r 1. La autoridad es su exit code.
    $preferenciaAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $salida = & sqlcmd -S $Servidor -U sa -P $script:SqlPassword -C -b -Q $Consulta 2>&1
    $codigoSalida = $LASTEXITCODE
    $ErrorActionPreference = $preferenciaAnterior
    if ($codigoSalida -ne 0) {
        throw "SQL fallo en ${Servidor}:`n$($salida | Out-String)"
    }
    if (-not $Silencioso) { $salida | ForEach-Object { Write-Host $_ } }
    return $salida
}

function Escapar-Literal([string] $Valor) {
    return $Valor.Replace("'", "''")
}

function Consultar-Escalar([string] $Servidor, [string] $Consulta) {
    $preferenciaAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $salida = & sqlcmd -S $Servidor -U sa -P $script:SqlPassword -C -b -h -1 -W -Q "SET NOCOUNT ON; $Consulta" 2>&1
    $codigoSalida = $LASTEXITCODE
    $ErrorActionPreference = $preferenciaAnterior
    if ($codigoSalida -ne 0) {
        throw "Consulta escalar fallo en ${Servidor}:`n$($salida | Out-String)"
    }
    return (($salida | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1).Trim())
}

Push-Location $RaizProyecto
try {
    Paso 'Iniciando las replicas SQL Server'
    Ejecutar-DockerCompose @('--profile', 'ha', 'up', '-d',
                             'sqlserver', 'sqlserver-secondary')

    $PrincipalId = Esperar-Salud 'sqlserver' 240
    $SecundarioId = Esperar-Salud 'sqlserver-secondary' 240
    $script:SqlPassword = Obtener-Password $PrincipalId

    $Principal = 'localhost,1433'
    $Secundario = 'localhost,1434'

    $hadrPrincipal = Consultar-Escalar $Principal "SELECT CONVERT(int,SERVERPROPERTY('IsHadrEnabled'));"
    $hadrSecundario = Consultar-Escalar $Secundario "SELECT CONVERT(int,SERVERPROPERTY('IsHadrEnabled'));"
    if ($hadrPrincipal -ne '1' -or $hadrSecundario -ne '1') {
        throw "Always On no quedo habilitado (principal=$hadrPrincipal, secundario=$hadrSecundario)."
    }

    $NombrePrincipal = Consultar-Escalar $Principal "SELECT CONVERT(nvarchar(128),@@SERVERNAME);"
    $NombreSecundario = Consultar-Escalar $Secundario "SELECT CONVERT(nvarchar(128),@@SERVERNAME);"
    Write-Host "    Principal : $NombrePrincipal"
    Write-Host "    Secundario: $NombreSecundario"

    $agExistente = Consultar-Escalar $Principal "SELECT COUNT(*) FROM sys.availability_groups WHERE name=N'ag_TurismoDW';"

    # Si el grupo ya existe, conserva como destino del endpoint a la replica
    # que actualmente sea PRIMARY. Esto hace seguro reejecutar el setup tras
    # una prueba de failover.
    $rolPrincipal = Consultar-Escalar $Principal @"
SELECT COALESCE(MAX(ars.role_desc),'SIN_AG')
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id=ars.group_id
WHERE ars.is_local=1 AND ag.name=N'ag_TurismoDW';
"@
    $rolSecundario = Consultar-Escalar $Secundario @"
SELECT COALESCE(MAX(ars.role_desc),'SIN_AG')
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ag.group_id=ars.group_id
WHERE ars.is_local=1 AND ag.name=N'ag_TurismoDW';
"@
    $env:SQL_HA_BACKEND = if ($rolSecundario -eq 'PRIMARY') { 'sqlserver-secondary' } else { 'sqlserver' }
    Ejecutar-DockerCompose @('--profile', 'ha', 'up', '-d', '--no-deps', '--force-recreate', 'sql-ha-endpoint')
    Write-Host "    Endpoint logico -> $env:SQL_HA_BACKEND"

    if ($agExistente -eq '1') {
        Write-Host '    El grupo ag_TurismoDW ya existe; se conserva y se verifica su estado.' -ForegroundColor Yellow
    }
    else {
        Paso 'Creando certificados y endpoints de replica'
        & docker exec -u 0 $PrincipalId sh -c 'chown 10001:0 /var/opt/mssql/ha && chmod 770 /var/opt/mssql/ha && rm -f /var/opt/mssql/ha/ag-primary.cer /var/opt/mssql/ha/ag-secondary.cer'
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo preparar el volumen compartido HA.' }

        $sqlCertPrincipal = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name=N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD=N'TurismoDW_AG_MasterKey_2026!';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name=N'AG_Primary_Cert')
    CREATE CERTIFICATE [AG_Primary_Cert] WITH SUBJECT=N'TurismoDW AG primary endpoint';
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name=N'Hadr_endpoint')
    CREATE ENDPOINT [Hadr_endpoint]
      STATE=STARTED AS TCP (LISTENER_PORT=5022, LISTENER_IP=ALL)
      FOR DATABASE_MIRRORING
      (AUTHENTICATION=CERTIFICATE [AG_Primary_Cert], ENCRYPTION=REQUIRED ALGORITHM AES, ROLE=ALL);
ELSE
    ALTER ENDPOINT [Hadr_endpoint] STATE=STARTED;
BACKUP CERTIFICATE [AG_Primary_Cert] TO FILE=N'/var/opt/mssql/ha/ag-primary.cer';
"@
        Ejecutar-Sql $Principal $sqlCertPrincipal -Silencioso | Out-Null

        $sqlCertSecundario = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name=N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD=N'TurismoDW_AG_MasterKey_2026!';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name=N'AG_Secondary_Cert')
    CREATE CERTIFICATE [AG_Secondary_Cert] WITH SUBJECT=N'TurismoDW AG secondary endpoint';
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name=N'Hadr_endpoint')
    CREATE ENDPOINT [Hadr_endpoint]
      STATE=STARTED AS TCP (LISTENER_PORT=5022, LISTENER_IP=ALL)
      FOR DATABASE_MIRRORING
      (AUTHENTICATION=CERTIFICATE [AG_Secondary_Cert], ENCRYPTION=REQUIRED ALGORITHM AES, ROLE=ALL);
ELSE
    ALTER ENDPOINT [Hadr_endpoint] STATE=STARTED;
BACKUP CERTIFICATE [AG_Secondary_Cert] TO FILE=N'/var/opt/mssql/ha/ag-secondary.cer';
"@
        Ejecutar-Sql $Secundario $sqlCertSecundario -Silencioso | Out-Null

        $PasswordLogin = Escapar-Literal (([guid]::NewGuid().ToString('N')) + 'aA1!')
        $sqlEntradaPrincipal = @"
USE master;
IF EXISTS (SELECT 1 FROM sys.certificates WHERE name=N'AG_Secondary_Remote_Cert')
    DROP CERTIFICATE [AG_Secondary_Remote_Cert];
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'ag_secondary_user')
    DROP USER [ag_secondary_user];
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'ag_secondary_login')
    DROP LOGIN [ag_secondary_login];
CREATE LOGIN [ag_secondary_login] WITH PASSWORD=N'$PasswordLogin', CHECK_POLICY=OFF;
CREATE USER [ag_secondary_user] FOR LOGIN [ag_secondary_login];
CREATE CERTIFICATE [AG_Secondary_Remote_Cert]
  AUTHORIZATION [ag_secondary_user]
  FROM FILE=N'/var/opt/mssql/ha/ag-secondary.cer';
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [ag_secondary_login];
"@
        Ejecutar-Sql $Principal $sqlEntradaPrincipal -Silencioso | Out-Null

        $PasswordLogin = Escapar-Literal (([guid]::NewGuid().ToString('N')) + 'aA1!')
        $sqlEntradaSecundario = @"
USE master;
IF EXISTS (SELECT 1 FROM sys.certificates WHERE name=N'AG_Primary_Remote_Cert')
    DROP CERTIFICATE [AG_Primary_Remote_Cert];
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'ag_primary_user')
    DROP USER [ag_primary_user];
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'ag_primary_login')
    DROP LOGIN [ag_primary_login];
CREATE LOGIN [ag_primary_login] WITH PASSWORD=N'$PasswordLogin', CHECK_POLICY=OFF;
CREATE USER [ag_primary_user] FOR LOGIN [ag_primary_login];
CREATE CERTIFICATE [AG_Primary_Remote_Cert]
  AUTHORIZATION [ag_primary_user]
  FROM FILE=N'/var/opt/mssql/ha/ag-primary.cer';
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [ag_primary_login];
"@
        Ejecutar-Sql $Secundario $sqlEntradaSecundario -Silencioso | Out-Null

        Paso 'Creando backup base y el Availability Group'
        $consultaBackup = @"
BACKUP DATABASE [TurismoDW]
 TO DISK=N'/var/opt/mssql/ha/TurismoDW_pre_ag.bak'
 WITH INIT, COMPRESSION, CHECKSUM, STATS=20;
"@
        $backupTerminado = $false
        foreach ($intento in 1..12) {
            try {
                Ejecutar-Sql $Principal $consultaBackup | Out-Null
                $backupTerminado = $true
                break
            }
            catch {
                if ($_.Exception.Message -notmatch 'Msg 3023') { throw }
                Write-Host "    Backup ocupado; reintento $intento/12 en 10 segundos..." -ForegroundColor Yellow
                Start-Sleep -Seconds 10
            }
        }
        if (-not $backupTerminado) { throw 'No fue posible completar el backup base despues de 12 intentos.' }

        # Las cargas BCP pueden dejar cambios bulk-logged. El AG no admite la
        # base hasta cerrar esa cadena con al menos un backup de log.
        Ejecutar-Sql $Principal @"
BACKUP LOG [TurismoDW]
 TO DISK=N'/var/opt/mssql/ha/TurismoDW_pre_ag.trn'
 WITH INIT, COMPRESSION, CHECKSUM, STATS=20;
"@ | Out-Null

        $p = Escapar-Literal $NombrePrincipal
        $s = Escapar-Literal $NombreSecundario
        $sqlCrearAg = @"
USE master;
CREATE AVAILABILITY GROUP [ag_TurismoDW]
WITH (CLUSTER_TYPE=NONE)
FOR DATABASE [TurismoDW]
REPLICA ON
 N'$p' WITH
 (
   ENDPOINT_URL=N'TCP://sqlserver:5022',
   AVAILABILITY_MODE=SYNCHRONOUS_COMMIT,
   FAILOVER_MODE=MANUAL,
   SEEDING_MODE=AUTOMATIC,
   SESSION_TIMEOUT=10,
   PRIMARY_ROLE(ALLOW_CONNECTIONS=ALL),
   SECONDARY_ROLE(ALLOW_CONNECTIONS=ALL)
 ),
 N'$s' WITH
 (
   ENDPOINT_URL=N'TCP://sqlserver-secondary:5022',
   AVAILABILITY_MODE=SYNCHRONOUS_COMMIT,
   FAILOVER_MODE=MANUAL,
   SEEDING_MODE=AUTOMATIC,
   SESSION_TIMEOUT=10,
   PRIMARY_ROLE(ALLOW_CONNECTIONS=ALL),
   SECONDARY_ROLE(ALLOW_CONNECTIONS=ALL)
 );
"@
        Ejecutar-Sql $Principal $sqlCrearAg -Silencioso | Out-Null
        Ejecutar-Sql $Secundario @"
USE master;
ALTER AVAILABILITY GROUP [ag_TurismoDW] JOIN WITH (CLUSTER_TYPE=NONE);
ALTER AVAILABILITY GROUP [ag_TurismoDW] GRANT CREATE ANY DATABASE;
"@ -Silencioso | Out-Null
    }

    Paso 'Esperando que TurismoDW quede SYNCHRONIZED en la replica secundaria'
    $inicioEspera = Get-Date
    do {
        $estado = Consultar-Escalar $Secundario @"
SELECT COALESCE(MAX(synchronization_state_desc),'INICIALIZANDO')
FROM sys.dm_hadr_database_replica_states
WHERE is_local=1 AND database_id=DB_ID(N'TurismoDW');
"@
        $transcurrido = [int]((Get-Date) - $inicioEspera).TotalSeconds
        Write-Host "    ${transcurrido}s - $estado"
        if ($estado -eq 'SYNCHRONIZED') { break }
        if ($transcurrido -ge $TimeoutSincronizacionSegundos) {
            $detalle = Ejecutar-Sql $Secundario "SELECT * FROM sys.dm_hadr_automatic_seeding;" -Silencioso
            throw "La replica no sincronizo dentro del tiempo limite.`n$($detalle | Out-String)"
        }
        Start-Sleep -Seconds 10
    } while ($true)

    Paso 'Validando replicas y endpoint estable localhost,14330'
    $consultaEstado = @"
SET NOCOUNT ON;
SELECT @@SERVERNAME AS Nodo,
       ag.name AS Grupo,
       ars.role_desc AS Rol,
       drs.synchronization_state_desc AS Sincronizacion,
       drs.synchronization_health_desc AS Salud,
       DB_NAME(drs.database_id) AS BaseDatos
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id=ag.group_id
JOIN sys.dm_hadr_availability_replica_states ars
  ON ars.group_id=ar.group_id AND ars.replica_id=ar.replica_id AND ars.is_local=1
JOIN sys.dm_hadr_database_replica_states drs
  ON drs.group_id=ar.group_id AND drs.replica_id=ar.replica_id AND drs.is_local=1
WHERE ag.name=N'ag_TurismoDW' AND drs.database_id=DB_ID(N'TurismoDW');
"@
    $estadoPrincipal = Ejecutar-Sql $Principal $consultaEstado -Silencioso
    $estadoSecundario = Ejecutar-Sql $Secundario $consultaEstado -Silencioso
    $pruebaEndpoint = Ejecutar-Sql 'localhost,14330' "SET NOCOUNT ON; SELECT @@SERVERNAME Nodo,COUNT_BIG(*) Reservas FROM TurismoDW.dw.FactReserva;" -Silencioso
    $estadoPrincipalTexto = (($estadoPrincipal | ForEach-Object { ([string]$_).TrimEnd() }) -join [Environment]::NewLine).Trim()
    $estadoSecundarioTexto = (($estadoSecundario | ForEach-Object { ([string]$_).TrimEnd() }) -join [Environment]::NewLine).Trim()
    $pruebaEndpointTexto = (($pruebaEndpoint | ForEach-Object { ([string]$_).TrimEnd() }) -join [Environment]::NewLine).Trim()

    $contenido = @"
================================================================================
CONFIGURACION ALWAYS ON - TURISMODW
================================================================================
Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Topologia: 2 replicas sincronicas, CLUSTER_TYPE=NONE, failover manual
Endpoint logico de cliente: localhost,14330

--- PRINCIPAL ---
$estadoPrincipalTexto
--- SECUNDARIO ---
$estadoSecundarioTexto
--- PRUEBA DEL ENDPOINT ---
$pruebaEndpointTexto
================================================================================
"@
    $directorio = Split-Path $RutaEvidencia -Parent
    if (-not (Test-Path $directorio)) { New-Item -ItemType Directory -Path $directorio -Force | Out-Null }
    Set-Content -LiteralPath $RutaEvidencia -Value $contenido -Encoding UTF8
    Write-Host "`nConfiguracion completada. Evidencia: $RutaEvidencia" -ForegroundColor Green
}
finally {
    Pop-Location
}
