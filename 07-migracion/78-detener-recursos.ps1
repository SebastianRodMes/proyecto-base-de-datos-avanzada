<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    78-detener-recursos.ps1
    ----------------------------------------------------------------------
    Detiene o elimina la infraestructura de AWS para que el costo no siga
    corriendo entre sesiones de trabajo.

    Detener no es lo mismo que eliminar
    -----------------------------------
    -Detener  (por defecto) apaga las dos instancias RDS. Se deja de pagar
              el computo y se sigue pagando solo el almacenamiento, unos
              0.115 USD por GB-mes: con 40 GB son 4.60 USD al mes, y como
              el proyecto dura dias, centavos. Los datos se conservan y la
              instancia vuelve con -Iniciar.

              AWS reinicia sola una instancia detenida a los 7 dias. Es un
              comportamiento del servicio, no un error: si el proyecto se
              deja parado mas de una semana, conviene eliminar.

    -Eliminar borra las instancias, el bucket y el resto. Es irreversible.
              Pide confirmacion escrita porque no se puede deshacer.

    Uso:
        .\07-migracion\78-detener-recursos.ps1
        .\07-migracion\78-detener-recursos.ps1 -Iniciar
        .\07-migracion\78-detener-recursos.ps1 -Estado
        .\07-migracion\78-detener-recursos.ps1 -Eliminar
#>

[CmdletBinding()]
param(
    [switch] $Iniciar,
    [switch] $Estado,
    [switch] $Eliminar,
    [switch] $Esperar
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Gestion de recursos de AWS'

$ctx = Obtener-Contexto -Raiz $Raiz
$instancias = @($ctx.PgId, $ctx.SqlId)

function Mostrar-Estado {
    Escribir ''
    Escribir ('{0,-20} {1,-14} {2,-10} {3}' -f 'Instancia', 'Estado', 'Clase', 'Endpoint')
    Escribir ('-' * 78)
    foreach ($i in $instancias) {
        $d = & aws rds describe-db-instances --db-instance-identifier $i `
                --query 'DBInstances[0].[DBInstanceStatus,DBInstanceClass,Endpoint.Address]' `
                --output text 2>$null
        if ($d) {
            $p = $d -split '\s+'
            Escribir ('{0,-20} {1,-14} {2,-10} {3}' -f $i, $p[0], $p[1], $p[2])
        } else {
            Escribir ('{0,-20} no existe' -f $i) 'AVISO'
        }
    }

    $obj = & aws s3 ls "s3://$($ctx.Bucket)" --recursive --summarize 2>$null |
           Select-String 'Total Objects|Total Size'
    Escribir ''
    if ($obj) { $obj | ForEach-Object { Escribir "  s3://$($ctx.Bucket) $_" } }
    else      { Escribir "  s3://$($ctx.Bucket) vacio o inaccesible" }
}

# ---------------------------------------------------------------------------
if ($Estado) { Mostrar-Estado; return }

# ---------------------------------------------------------------------------
if ($Eliminar) {
    Escribir ''
    Escribir 'ELIMINACION IRREVERSIBLE' 'ERROR'
    Escribir 'Se borraran, sin posibilidad de recuperacion:' 'ERROR'
    foreach ($i in $instancias) { Escribir "   - instancia RDS $i y todos sus datos" 'ERROR' }
    Escribir "   - bucket s3://$($ctx.Bucket) y todo su contenido" 'ERROR'
    Escribir ''
    Escribir 'El laboratorio local en Docker NO se toca: la migracion sigue siendo' 'AVISO'
    Escribir 'reversible porque el origen nunca se modifico.' 'AVISO'
    Escribir ''
    $confirmacion = Read-Host "Escriba ELIMINAR en mayusculas para continuar"
    if ($confirmacion -cne 'ELIMINAR') {
        Escribir 'Cancelado. No se borro nada.' 'OK'
        return
    }

    foreach ($i in $instancias) {
        Escribir "Eliminando $i ..." 'PASO'
        & aws rds delete-db-instance --db-instance-identifier $i `
              --skip-final-snapshot --delete-automated-backups --output json 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Escribir "  $i en eliminacion" 'OK' }
        else                     { Escribir "  no se pudo eliminar $i" 'AVISO' }
    }

    Escribir "Vaciando y eliminando s3://$($ctx.Bucket) ..." 'PASO'
    & aws s3 rm "s3://$($ctx.Bucket)" --recursive 2>&1 | Out-Null
    & aws s3api delete-bucket --bucket $ctx.Bucket 2>&1 | Out-Null

    Escribir ''
    Escribir 'Recursos en eliminacion. La factura deja de correr cuando terminen.' 'OK'
    Escribir 'Quedan sin borrar, porque no cuestan nada:' 'AVISO'
    Escribir "   - grupo de seguridad, grupo de subredes, option group"
    Escribir "   - rol IAM $($ctx.RolS3)"
    Escribir "   - usuario IAM turismodw-migracion (revoque su clave si ya no lo usara)"
    return
}

# ---------------------------------------------------------------------------
$accion  = if ($Iniciar) { 'start-db-instance' } else { 'stop-db-instance' }
$verbo   = if ($Iniciar) { 'Iniciando' } else { 'Deteniendo' }
$destino = if ($Iniciar) { 'available' } else { 'stopped' }

foreach ($i in $instancias) {
    $actual = & aws rds describe-db-instances --db-instance-identifier $i `
                 --query 'DBInstances[0].DBInstanceStatus' --output text 2>$null
    if (-not $actual) { Escribir "$i no existe" 'AVISO'; continue }
    if ($actual -eq $destino) { Escribir "$i ya esta en '$destino'" 'OK'; continue }

    Escribir "$verbo $i (estado actual: $actual) ..." 'PASO'
    $r = & aws rds $accion --db-instance-identifier $i --output json 2>&1
    if ($LASTEXITCODE -eq 0) { Escribir "  solicitud aceptada" 'OK' }
    else                     { Escribir "  $r" 'AVISO' }
}

if ($Esperar) {
    foreach ($i in $instancias) {
        Escribir "Esperando a que $i quede en '$destino' ..." 'PASO'
        if ($Iniciar) { & aws rds wait db-instance-available --db-instance-identifier $i 2>&1 | Out-Null }
        else          { & aws rds wait db-instance-stopped   --db-instance-identifier $i 2>&1 | Out-Null }
        Escribir "  $i listo" 'OK'
    }
}

Mostrar-Estado

Escribir ''
if ($Iniciar) {
    Escribir 'Instancias iniciando. Tardan unos minutos en aceptar conexiones.' 'OK'
} else {
    Escribir 'Instancias deteniendose. Solo se paga almacenamiento (~0.15 USD/dia).' 'OK'
    Escribir 'AWS las reinicia automaticamente a los 7 dias; si el proyecto se deja' 'AVISO'
    Escribir 'parado mas tiempo, use -Eliminar.' 'AVISO'
}
