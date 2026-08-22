<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    comun.ps1
    ----------------------------------------------------------------------
    Funciones compartidas por los scripts 72 a 79. Se carga con dot-source:

        . (Join-Path $PSScriptRoot 'comun.ps1')

    No hace nada por si solo. Centraliza tres cosas que de otro modo se
    repetirian en ocho scripts: la lectura de credenciales, el registro de
    mensajes y la invocacion de herramientas externas.
#>

# ---------------------------------------------------------------------------
# Registro
# ---------------------------------------------------------------------------
function Escribir {
    param([string] $Texto, [string] $Nivel = 'INFO')
    $color = switch ($Nivel) {
        'OK'    { 'Green' }
        'AVISO' { 'Yellow' }
        'ERROR' { 'Red' }
        'PASO'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Nivel.PadRight(5), $Texto) -ForegroundColor $color
}

function Escribir-Titulo {
    param([string] $Texto)
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host " $Texto"
    Write-Host ('=' * 78)
}

# ---------------------------------------------------------------------------
# Credenciales de la infraestructura cloud
# ---------------------------------------------------------------------------
function Obtener-Contexto {
    <#
        Lee .secrets\turismodw-cloud.env, que genera 70-provisionar-aws.ps1,
        y devuelve un objeto con los endpoints ya resueltos.

        Ese archivo esta fuera del control de versiones (.gitignore -> .secrets/).
        Si no existe, no se adivina nada: se aborta con la instruccion exacta
        de que correr.
    #>
    param([string] $Raiz)

    $archivo = Join-Path $Raiz '.secrets\turismodw-cloud.env'
    if (-not (Test-Path $archivo)) {
        throw "No existe .secrets\turismodw-cloud.env. Corra antes 07-migracion\70-provisionar-aws.ps1."
    }

    $v = @{}
    Get-Content $archivo | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
        $k, $val = $_ -split '=', 2
        $v[$k.Trim()] = $val.Trim()
    }

    $env:AWS_PROFILE        = $v['AWS_PERFIL']
    $env:AWS_DEFAULT_REGION = $v['AWS_REGION']

    # Los endpoints no se guardan en el archivo de secretos: se consultan a
    # AWS cada vez, porque cambian si la instancia se recrea.
    $epPg = (& aws rds describe-db-instances --db-instance-identifier $v['RDS_PG_ID'] `
                --query 'DBInstances[0].Endpoint.Address' --output text 2>$null)
    $epSql = (& aws rds describe-db-instances --db-instance-identifier $v['RDS_SQL_ID'] `
                --query 'DBInstances[0].Endpoint.Address' --output text 2>$null)

    [pscustomobject]@{
        Perfil       = $v['AWS_PERFIL']
        Region       = $v['AWS_REGION']
        Cuenta       = $v['AWS_CUENTA']
        Bucket       = $v['S3_BUCKET']
        RolS3        = $v['IAM_ROL_S3']
        PgId         = $v['RDS_PG_ID']
        PgEndpoint   = $epPg
        PgUsuario    = $v['RDS_PG_USER']
        PgClave      = $v['RDS_PG_PASSWORD']
        SqlId        = $v['RDS_SQL_ID']
        SqlEndpoint  = $epSql
        SqlUsuario   = $v['RDS_SQL_USER']
        SqlClave     = $v['RDS_SQL_PASSWORD']
        MongoUri     = $v['ATLAS_URI']
    }
}

function Probar-Endpoint {
    <#
        Verifica que un endpoint de RDS este disponible antes de intentar
        migrar contra el. Sin esto, un script que corre mientras la instancia
        todavia dice 'creating' falla con un error de red que no explica nada.
    #>
    param([string] $Identificador)

    $estado = (& aws rds describe-db-instances --db-instance-identifier $Identificador `
                  --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null)
    if (-not $estado) { throw "La instancia $Identificador no existe." }
    if ($estado -ne 'available') {
        throw "La instancia $Identificador esta en estado '$estado'. Espere a 'available' (aws rds wait db-instance-available --db-instance-identifier $Identificador)."
    }
    return $true
}

# ---------------------------------------------------------------------------
# Herramientas externas
# ---------------------------------------------------------------------------
function Probar-Herramienta {
    <#
        Comprueba que un ejecutable este en el PATH y devuelve su ruta.
        Se llama al inicio de cada script para fallar temprano y con un
        mensaje util, en vez de a media migracion.
    #>
    param([string] $Nombre, [string] $Sugerencia = '')

    $cmd = Get-Command $Nombre -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $msg = "No se encontro '$Nombre' en el PATH."
        if ($Sugerencia) { $msg += " $Sugerencia" }
        throw $msg
    }
    return $cmd.Source
}

function Invocar-Sqlcmd {
    <#
        Envuelve sqlcmd con las banderas que necesita un endpoint de RDS:
        -C confia en el certificado del servidor y -N pide canal cifrado,
        que RDS exige. -b hace que un error de T-SQL devuelva codigo != 0,
        sin lo cual un script fallido pasaria por exitoso.
    #>
    param(
        [string]   $Servidor,
        [string]   $Usuario,
        [string]   $Clave,
        [string]   $Base = 'master',
        [string]   $Archivo,
        [string]   $Consulta,
        [string[]] $Variables = @(),
        [switch]   $Silencioso
    )

    $argumentos = @('-S', $Servidor, '-U', $Usuario, '-P', $Clave, '-C', '-N', '-b', '-d', $Base)
    if ($Archivo)  { $argumentos += @('-i', $Archivo) }
    if ($Consulta) { $argumentos += @('-Q', $Consulta) }
    foreach ($var in $Variables) { $argumentos += @('-v', $var) }

    $salida = & sqlcmd @argumentos 2>&1
    $codigo = $LASTEXITCODE
    if (-not $Silencioso) { $salida | ForEach-Object { Write-Host "    $_" } }
    [pscustomobject]@{ Ok = ($codigo -eq 0); Codigo = $codigo; Salida = ($salida | Out-String) }
}

function Medir-Paso {
    <#
        Ejecuta un bloque midiendo el tiempo y reportando el resultado.
        Sirve para que la evidencia registre cuanto tardo cada etapa de la
        migracion, que es dato del informe y no adorno.
    #>
    param([string] $Nombre, [scriptblock] $Bloque)

    Escribir "$Nombre ..." 'PASO'
    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resultado = & $Bloque
        $reloj.Stop()
        Escribir ("$Nombre completado en {0:N1} s" -f $reloj.Elapsed.TotalSeconds) 'OK'
        return $resultado
    } catch {
        $reloj.Stop()
        Escribir ("$Nombre fallo tras {0:N1} s: {1}" -f $reloj.Elapsed.TotalSeconds, $_.Exception.Message) 'ERROR'
        throw
    }
}
