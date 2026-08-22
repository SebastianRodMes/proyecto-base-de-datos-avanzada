<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    70-provisionar-aws.ps1
    ----------------------------------------------------------------------
    Crea la infraestructura destino de la migracion en AWS us-east-1:

        - Grupo de seguridad abierto SOLO a la IP publica de esta maquina
        - Grupo de subredes de RDS sobre la VPC por defecto
        - RDS for PostgreSQL 16      (origen relacional migrado)
        - RDS for SQL Server 2022 EX (destino analitico: TurismoDW)
        - Bucket S3                  (landing zone de JSON/XML + respaldos)
        - Rol IAM + option group     (habilita native backup/restore S3)

    Por que Express y no Standard
    -----------------------------
    El DW real pesa alrededor de 2 GB de datos mas indices, muy por debajo
    del tope de 10 GB por base que impone Express, y cuesta ~0.018 USD/h
    contra ~0.44 USD/h de Standard con licencia. Si el piloto choca con un
    limite de Express, ese limite es un hallazgo del entregable y se escala
    la instancia; no se paga Standard "por si acaso".

    Las contrasenas se generan aqui y se guardan en .secrets\ (ignorado por
    git). Nunca se imprimen en consola ni se escriben en el repositorio.

    Uso:
        .\07-migracion\70-provisionar-aws.ps1
        .\07-migracion\70-provisionar-aws.ps1 -Esperar      # bloquea hasta 'available'
        .\07-migracion\70-provisionar-aws.ps1 -SoloEstado   # solo consulta
#>

[CmdletBinding()]
param(
    [string] $Perfil        = 'turismodw',
    [string] $Region        = 'us-east-1',
    [string] $Prefijo       = 'turismodw',
    [string] $ClaseSql      = 'db.t3.micro',
    [string] $ClasePg       = 'db.t4g.micro',
    [int]    $AlmacenamientoGB = 20,
    [switch] $Esperar,
    [switch] $SoloEstado
)

$ErrorActionPreference = 'Stop'
$env:AWS_PROFILE = $Perfil
$env:AWS_DEFAULT_REGION = $Region

$Raiz       = Split-Path -Parent $PSScriptRoot
$DirSecreto = Join-Path $Raiz '.secrets'
$DirEvid    = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirSecreto, $DirEvid | Out-Null

$IdPg     = "$Prefijo-pg"
$IdSql    = "$Prefijo-sql"
$NomSg    = "$Prefijo-sg"
$NomSubnet= "$Prefijo-subnets"
$NomOpt   = "$Prefijo-backup-restore"
$NomRol   = "$Prefijo-s3-role"

function Escribir($texto, $nivel = 'INFO') {
    $color = switch ($nivel) { 'OK' {'Green'} 'AVISO' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
    Write-Host ("[{0}] {1}" -f $nivel.PadRight(5), $texto) -ForegroundColor $color
}

# Ruta del ejecutable de aws-cli, resuelta UNA vez.
#
# Por que se resuelve la ruta y la funcion no se llama 'Aws'
# ----------------------------------------------------------
# PowerShell no distingue mayusculas al resolver comandos, y ademas busca
# funciones ANTES que ejecutables. Una funcion llamada 'Aws' hace que
# '& aws ...' dentro de su propio cuerpo se resuelva a la funcion misma:
# recursion infinita, que PowerShell corta con "call depth overflow".
# Ya paso en la primera corrida de este script.
#
# Se arregla por partida doble: la funcion se llama Invocar-Aws, y ademas
# se invoca la ruta del .exe en vez del nombre del comando.
$script:AwsExe = (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue |
                  Select-Object -First 1).Source
if (-not $script:AwsExe) {
    throw "No se encontro el ejecutable de aws-cli en el PATH."
}

# aws-cli devuelve JSON; esta funcion lo convierte y propaga errores reales.
function Invocar-Aws {
    # No se llama $Args: ese nombre choca con la variable automatica de
    # PowerShell y el enlace de parametros se vuelve impredecible.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Argumentos)
    $salida = & $script:AwsExe @Argumentos 2>&1
    $codigo = $LASTEXITCODE
    $texto  = ($salida | Out-String).Trim()
    if ($codigo -ne 0) { return [pscustomobject]@{ Ok = $false; Error = $texto } }
    if ([string]::IsNullOrWhiteSpace($texto)) { return [pscustomobject]@{ Ok = $true; Data = $null } }
    try   { return [pscustomobject]@{ Ok = $true; Data = ($texto | ConvertFrom-Json) } }
    catch { return [pscustomobject]@{ Ok = $true; Data = $texto } }
}

function Nueva-Clave([int] $largo = 24) {
    # Alfabeto sin / " @ ' \ ni espacio: caracteres que RDS rechaza o que
    # rompen las cadenas de conexion de ODBC y de psycopg2.
    $abc = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_.!*'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $b   = [byte[]]::new($largo)
    $rng.GetBytes($b)
    -join ($b | ForEach-Object { $abc[$_ % $abc.Length] })
}

Write-Host ('=' * 78)
Write-Host ' ITI-821 | Escenario 8 | Provision de infraestructura AWS'
Write-Host ' Integrante 1: Alex Herrera'
Write-Host ('=' * 78)

# ---------------------------------------------------------------------------
# 0. Identidad y contexto
# ---------------------------------------------------------------------------
$id = Invocar-Aws sts get-caller-identity --output json
if (-not $id.Ok) { throw "No hay credenciales AWS validas en el perfil '$Perfil'. $($id.Error)" }
$Cuenta = $id.Data.Account
Escribir "Cuenta AWS   : $Cuenta" 'OK'
Escribir "Identidad    : $($id.Data.Arn)"
Escribir "Region       : $Region"

$Bucket = "$Prefijo-migracion-$Cuenta"

if ($SoloEstado) {
    foreach ($inst in @($IdPg, $IdSql)) {
        $r = Invocar-Aws rds describe-db-instances --db-instance-identifier $inst `
             --query 'DBInstances[0].{Estado:DBInstanceStatus,Endpoint:Endpoint.Address,Puerto:Endpoint.Port,Clase:DBInstanceClass}' `
             --output json
        if ($r.Ok) { Escribir ("{0,-16} {1}" -f $inst, ($r.Data | ConvertTo-Json -Compress)) 'OK' }
        else       { Escribir ("{0,-16} no existe" -f $inst) 'AVISO' }
    }
    # exit 0 explicito: consultar una instancia inexistente deja
    # $LASTEXITCODE en 254 (el codigo de aws-cli para "no encontrado"), y el
    # script heredaria ese valor haciendo pasar una consulta normal por fallo.
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Red: VPC por defecto, grupo de seguridad y grupo de subredes
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 1. Red ---'

$vpc = (Invocar-Aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text).Data
Escribir "VPC por defecto: $vpc"

$miIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 20).Trim()
Escribir "IP publica de esta maquina: $miIp"

$sg = (Invocar-Aws ec2 describe-security-groups --filters "Name=group-name,Values=$NomSg" "Name=vpc-id,Values=$vpc" `
        --query 'SecurityGroups[0].GroupId' --output text).Data
if (-not $sg -or $sg -eq 'None') {
    $sg = (Invocar-Aws ec2 create-security-group --group-name $NomSg --vpc-id $vpc `
            --description 'TurismoDW: acceso a RDS desde la maquina del laboratorio' `
            --query 'GroupId' --output text).Data
    Escribir "Grupo de seguridad creado: $sg" 'OK'
} else {
    Escribir "Grupo de seguridad existente: $sg"
}

# Reglas de entrada: solo esta IP, solo los dos puertos que se usan.
foreach ($puerto in @(1433, 5432)) {
    $r = Invocar-Aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp `
         --port $puerto --cidr "$miIp/32" --output json
    if ($r.Ok) { Escribir "  regla abierta: tcp/$puerto desde $miIp/32" 'OK' }
    elseif ($r.Error -match 'InvalidPermission.Duplicate') { Escribir "  regla tcp/$puerto ya existia" }
    else { Escribir "  no se pudo abrir tcp/$puerto : $($r.Error)" 'AVISO' }
}

$sng = Invocar-Aws rds describe-db-subnet-groups --db-subnet-group-name $NomSubnet --output json
if (-not $sng.Ok) {
    $subredes = (Invocar-Aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" `
                  --query 'Subnets[].SubnetId' --output text).Data -split '\s+'
    $r = Invocar-Aws rds create-db-subnet-group --db-subnet-group-name $NomSubnet `
         --db-subnet-group-description 'TurismoDW: subredes de la VPC por defecto' `
         --subnet-ids @subredes --output json
    if ($r.Ok) { Escribir "Grupo de subredes creado: $NomSubnet ($($subredes.Count) subredes)" 'OK' }
    else       { throw "No se pudo crear el grupo de subredes: $($r.Error)" }
} else {
    Escribir "Grupo de subredes existente: $NomSubnet"
}

# ---------------------------------------------------------------------------
# 2. S3: landing zone de archivos crudos y area de respaldos
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 2. Almacenamiento S3 ---'

$b = Invocar-Aws s3api head-bucket --bucket $Bucket --output json
if (-not $b.Ok) {
    # us-east-1 es la unica region que NO admite LocationConstraint.
    $r = Invocar-Aws s3api create-bucket --bucket $Bucket --output json
    if ($r.Ok) { Escribir "Bucket creado: s3://$Bucket" 'OK' }
    else       { throw "No se pudo crear el bucket: $($r.Error)" }
    Invocar-Aws s3api put-public-access-block --bucket $Bucket `
        --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' `
        --output json | Out-Null
    Escribir '  acceso publico bloqueado' 'OK'
} else {
    Escribir "Bucket existente: s3://$Bucket"
}

# ---------------------------------------------------------------------------
# 3. IAM + option group: habilita native backup/restore contra S3.
#    Es la ruta alterna de migracion del DW que el piloto va a comparar
#    contra la ruta DDL + bcp.
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 3. IAM y option group para backup/restore nativo ---'

$tmp = [System.IO.Path]::GetTempPath()
$confianza = Join-Path $tmp 'turismodw-trust.json'
$politica  = Join-Path $tmp 'turismodw-s3.json'

@'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Principal": { "Service": "rds.amazonaws.com" },
      "Action": "sts:AssumeRole" }
  ]
}
'@ | Set-Content -Path $confianza -Encoding ascii

@"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::$Bucket" },
    { "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:ListMultipartUploadParts","s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::$Bucket/*" }
  ]
}
"@ | Set-Content -Path $politica -Encoding ascii

$rol = Invocar-Aws iam get-role --role-name $NomRol --query 'Role.Arn' --output text
if (-not $rol.Ok) {
    $rol = Invocar-Aws iam create-role --role-name $NomRol `
           --assume-role-policy-document "file://$confianza" `
           --description 'TurismoDW: permite a RDS SQL Server leer y escribir respaldos en S3' `
           --query 'Role.Arn' --output text
    if ($rol.Ok) { Escribir "Rol IAM creado: $NomRol" 'OK' }
    else         { Escribir "No se pudo crear el rol IAM: $($rol.Error)" 'AVISO' }
} else {
    Escribir "Rol IAM existente: $NomRol"
}
$ArnRol = $rol.Data

if ($ArnRol) {
    Invocar-Aws iam put-role-policy --role-name $NomRol --policy-name "$Prefijo-s3-acceso" `
        --policy-document "file://$politica" --output json | Out-Null
    Escribir '  politica de acceso a S3 adjuntada' 'OK'

    $og = Invocar-Aws rds describe-option-groups --option-group-name $NomOpt --output json
    if (-not $og.Ok) {
        $r = Invocar-Aws rds create-option-group --option-group-name $NomOpt `
             --engine-name sqlserver-ex --major-engine-version '16.00' `
             --option-group-description 'TurismoDW: native backup/restore contra S3' --output json
        if ($r.Ok) { Escribir "Option group creado: $NomOpt" 'OK' }
        else       { Escribir "No se pudo crear el option group: $($r.Error)" 'AVISO' }
    } else {
        Escribir "Option group existente: $NomOpt"
    }

    # IAM es eventualmente consistente: el rol y su politica acaban de
    # crearse, y RDS los valida antes de que la propagacion termine. El
    # primer intento falla con "IAM role ARN value is invalid or does not
    # include the required permissions". No es un error de configuracion,
    # es una carrera. Se reintenta con espera creciente.
    $opcion = "OptionName=SQLSERVER_BACKUP_RESTORE,OptionSettings=[{Name=IAM_ROLE_ARN,Value=$ArnRol}]"
    $habilitada = $false
    foreach ($espera in @(0, 10, 20, 30)) {
        if ($espera -gt 0) {
            Escribir "  esperando $espera s a que IAM propague el rol ..."
            Start-Sleep -Seconds $espera
        }
        $r = Invocar-Aws rds add-option-to-option-group --option-group-name $NomOpt `
             --options $opcion --apply-immediately --output json
        if ($r.Ok) { $habilitada = $true; break }
        if ($r.Error -notmatch 'IAM role ARN value is invalid') {
            Escribir "  SQLSERVER_BACKUP_RESTORE: $($r.Error)" 'AVISO'
            break
        }
    }
    if ($habilitada) {
        Escribir '  opcion SQLSERVER_BACKUP_RESTORE habilitada' 'OK'
    } else {
        Escribir '  SQLSERVER_BACKUP_RESTORE no quedo habilitada.' 'AVISO'
        Escribir "  Reintente luego con: aws rds add-option-to-option-group --option-group-name $NomOpt" 'AVISO'
    }
}

Remove-Item $confianza, $politica -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4. Instancias RDS
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 4. Instancias RDS ---'

$archivoSecreto = Join-Path $DirSecreto 'turismodw-cloud.env'
if (Test-Path $archivoSecreto) {
    Escribir 'Reutilizando credenciales ya generadas en .secrets\turismodw-cloud.env'
    $prev = @{}
    Get-Content $archivoSecreto | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        $prev[$k.Trim()] = $v.Trim()
    }
    $ClavePg  = $prev['RDS_PG_PASSWORD']
    $ClaveSql = $prev['RDS_SQL_PASSWORD']
}
if (-not $ClavePg)  { $ClavePg  = Nueva-Clave 24 }
if (-not $ClaveSql) { $ClaveSql = Nueva-Clave 24 }

$UsuarioPg  = 'turismoadmin'
$UsuarioSql = 'turismoadmin'

# --- PostgreSQL ---
$existe = Invocar-Aws rds describe-db-instances --db-instance-identifier $IdPg --output json
if (-not $existe.Ok) {
    $r = Invocar-Aws rds create-db-instance `
        --db-instance-identifier $IdPg `
        --db-instance-class $ClasePg `
        --engine postgres --engine-version '16.14' `
        --master-username $UsuarioPg --master-user-password $ClavePg `
        --allocated-storage $AlmacenamientoGB --storage-type gp3 `
        --db-name turismo `
        --vpc-security-group-ids $sg --db-subnet-group-name $NomSubnet `
        --publicly-accessible --no-multi-az `
        --backup-retention-period 0 --no-deletion-protection `
        --no-auto-minor-version-upgrade `
        --tags 'Key=Proyecto,Value=TurismoDW' 'Key=Curso,Value=ITI-821' `
        --output json
    if ($r.Ok) { Escribir "RDS PostgreSQL 16 lanzada: $IdPg ($ClasePg)" 'OK' }
    else       { throw "No se pudo crear $IdPg : $($r.Error)" }
} else {
    Escribir "RDS PostgreSQL existente: $IdPg ($($existe.Data.DBInstances[0].DBInstanceStatus))"
}

# --- SQL Server Express ---
$existe = Invocar-Aws rds describe-db-instances --db-instance-identifier $IdSql --output json
if (-not $existe.Ok) {
    $argsSql = @(
        'rds','create-db-instance',
        '--db-instance-identifier', $IdSql,
        '--db-instance-class', $ClaseSql,
        '--engine','sqlserver-ex','--engine-version','16.00.4205.1.v1',
        '--master-username', $UsuarioSql, '--master-user-password', $ClaveSql,
        '--allocated-storage', $AlmacenamientoGB, '--storage-type','gp3',
        '--vpc-security-group-ids', $sg, '--db-subnet-group-name', $NomSubnet,
        '--publicly-accessible','--no-multi-az',
        '--backup-retention-period','0','--no-deletion-protection',
        '--no-auto-minor-version-upgrade',
        '--license-model','license-included',
        '--character-set-name','SQL_Latin1_General_CP1_CI_AS',
        '--tags','Key=Proyecto,Value=TurismoDW','Key=Curso,Value=ITI-821',
        '--output','json'
    )
    if ($ArnRol) { $argsSql += @('--option-group-name', $NomOpt) }

    $r = Invocar-Aws @argsSql
    if ($r.Ok) { Escribir "RDS SQL Server 2022 Express lanzada: $IdSql ($ClaseSql)" 'OK' }
    else       { throw "No se pudo crear $IdSql : $($r.Error)" }
} else {
    Escribir "RDS SQL Server existente: $IdSql ($($existe.Data.DBInstances[0].DBInstanceStatus))"
}

# ---------------------------------------------------------------------------
# 5. Guardar credenciales fuera del repositorio
# ---------------------------------------------------------------------------
@"
# Credenciales de la infraestructura cloud de TurismoDW.
# Generado por 07-migracion/70-provisionar-aws.ps1
# ESTE ARCHIVO NO SE VERSIONA (.gitignore -> .secrets/)
AWS_PERFIL=$Perfil
AWS_REGION=$Region
AWS_CUENTA=$Cuenta
S3_BUCKET=$Bucket
SG_ID=$sg
RDS_PG_ID=$IdPg
RDS_PG_USER=$UsuarioPg
RDS_PG_PASSWORD=$ClavePg
RDS_SQL_ID=$IdSql
RDS_SQL_USER=$UsuarioSql
RDS_SQL_PASSWORD=$ClaveSql
IAM_ROL_S3=$ArnRol
OPTION_GROUP=$NomOpt

# MongoDB Atlas no se provisiona desde aqui: el nivel gratuito M0 solo se
# crea desde la consola de cloud.mongodb.com. Pegue abajo la cadena que
# entrega Connect -> Drivers, sin comentar.
# ATLAS_URI=mongodb+srv://turismodw:<clave>@<cluster>.mongodb.net/
"@ | Set-Content -Path $archivoSecreto -Encoding utf8
Escribir ''
Escribir "Credenciales guardadas en .secrets\turismodw-cloud.env (ignorado por git)" 'OK'

# ---------------------------------------------------------------------------
# 6. Espera opcional y resumen
# ---------------------------------------------------------------------------
if ($Esperar) {
    Escribir ''
    Escribir '--- 5. Esperando a que las instancias queden disponibles (10-20 min) ---'
    foreach ($inst in @($IdPg, $IdSql)) {
        Escribir "  esperando $inst ..."
        & $script:AwsExe rds wait db-instance-available --db-instance-identifier $inst 2>&1 | Out-Null
        Escribir "  $inst disponible" 'OK'
    }
}

Escribir ''
Escribir '--- Resumen ---'
$resumen = foreach ($inst in @($IdPg, $IdSql)) {
    $d = Invocar-Aws rds describe-db-instances --db-instance-identifier $inst `
         --query 'DBInstances[0].{Id:DBInstanceIdentifier,Estado:DBInstanceStatus,Endpoint:Endpoint.Address,Puerto:Endpoint.Port}' `
         --output json
    if ($d.Ok) { $d.Data }
}
$resumen | Format-Table -AutoSize | Out-String | Write-Host

$resumen | ConvertTo-Json -Depth 4 |
    Set-Content -Path (Join-Path $DirEvid 'provision-aws.json') -Encoding utf8

Escribir "Bucket S3    : s3://$Bucket" 'OK'
Escribir "Evidencia    : 00-docs/05-evidencias/migracion/provision-aws.json" 'OK'
Escribir ''
Escribir 'Siguiente: 07-migracion/72-piloto-migracion.ps1 cuando ambas esten "available".'
