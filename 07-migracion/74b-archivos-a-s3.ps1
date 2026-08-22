<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    74b-archivos-a-s3.ps1
    ----------------------------------------------------------------------
    Migra la cuarta fuente del escenario —los archivos JSON y XML— hacia
    Amazon S3, como landing zone cruda.

    Por que S3 y no una tabla
    -------------------------
    Los archivos de 03-archivos/entrada/ son una FUENTE del ETL, no un
    resultado. Convertirlos en tablas al migrar destruiria la evidencia de
    que la solucion integra cuatro tipos de origen distintos (relacional,
    documental, JSON y XML). En S3 siguen siendo archivos, el ETL los sigue
    leyendo igual, y ademas quedan versionados fuera de la maquina.

    Se usa 'aws s3 sync' y no 'cp': es idempotente y no vuelve a subir lo
    que no cambio, asi que correr el script dos veces no cuesta ancho de
    banda ni deja duplicados.

    Estructura en el bucket:
        raw/preferencias/   los tres lotes JSON  (RF-10)
        raw/paquetes/       los dos catalogos XML (RF-11)
        bak/                respaldos .bak, los deja 75-migrar-dw.ps1

    Uso:
        .\07-migracion\74b-archivos-a-s3.ps1
        .\07-migracion\74b-archivos-a-s3.ps1 -Verificar
#>

[CmdletBinding()]
param([switch] $Verificar)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Archivos JSON y XML hacia S3'

$ctx = Obtener-Contexto -Raiz $Raiz
$Entrada = Join-Path $Raiz '03-archivos\entrada'
$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$salida = Join-Path $DirEvid 'migracion-archivos-s3.txt'

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(' MIGRACION DE ARCHIVOS JSON Y XML A AMAZON S3')
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1: Alex Herrera')
$registro.Add(" Fecha  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add(" Bucket : s3://$($ctx.Bucket)")
$registro.Add('=====================================================================')

# ---------------------------------------------------------------------------
# 1. Origen
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 1. Archivos en el origen ==='
Anotar ''
$archivos = Get-ChildItem $Entrada -File | Sort-Object Name
$bytesOrigen = 0
foreach ($a in $archivos) {
    Anotar ('    {0,-28} {1,9:N1} KB' -f $a.Name, ($a.Length / 1KB))
    $bytesOrigen += $a.Length
}
Anotar ('    {0,-28} {1,9:N1} KB  ({2} archivos)' -f 'TOTAL', ($bytesOrigen / 1KB), $archivos.Count)

if ($Verificar) {
    Anotar ''
    Anotar '=== Contenido actual del bucket ==='
    $lista = & aws s3 ls "s3://$($ctx.Bucket)/raw/" --recursive --summarize 2>&1
    $lista | ForEach-Object { Anotar "    $_" }
    return
}

# ---------------------------------------------------------------------------
# 2. Subida
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 2. Subida con aws s3 sync ==='
Anotar ''

$reloj = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($grupo in @(
    @{ Patron = '*.json'; Destino = 'raw/preferencias/'; Nombre = 'JSON de preferencias (RF-10)' },
    @{ Patron = '*.xml';  Destino = 'raw/paquetes/';     Nombre = 'XML de paquetes (RF-11)'    })) {

    Anotar "    $($grupo.Nombre) -> s3://$($ctx.Bucket)/$($grupo.Destino)"
    $r = & aws s3 sync $Entrada "s3://$($ctx.Bucket)/$($grupo.Destino)" `
              --exclude '*' --include $grupo.Patron --no-progress 2>&1
    if ($LASTEXITCODE -ne 0) {
        Anotar "      FALLO: $r"
        throw "aws s3 sync fallo para $($grupo.Patron)"
    }
    $subidos = ($r | Where-Object { $_ -match 'upload:' }).Count
    if ($subidos -gt 0) { $r | Where-Object { $_ -match 'upload:' } | ForEach-Object { Anotar "      $_" } }
    else                { Anotar '      sin cambios (sync no resubio nada)' }
}

$reloj.Stop()
Anotar ''
Anotar ("    subida completa en {0:N1} s" -f $reloj.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# 3. Verificacion contra el origen
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 3. Verificacion: cada archivo, con su tamano ==='
Anotar ''

$enS3 = & aws s3 ls "s3://$($ctx.Bucket)/raw/" --recursive 2>&1
$mapaS3 = @{}
foreach ($linea in $enS3) {
    if ($linea -match '^\s*\S+\s+\S+\s+(\d+)\s+(.+)$') {
        $mapaS3[(Split-Path $Matches[2] -Leaf)] = [int64]$Matches[1]
    }
}

Anotar ('    {0,-28} {1,12} {2,12}  {3}' -f 'Archivo', 'Local', 'S3', 'Veredicto')
Anotar ('    ' + ('-' * 68))

$diferencias = 0
foreach ($a in $archivos) {
    $tamS3 = $mapaS3[$a.Name]
    if ($null -eq $tamS3) {
        Anotar ('    {0,-28} {1,12:N0} {2,12}  {3}' -f $a.Name, $a.Length, 'AUSENTE', 'FALTA')
        $diferencias++
    } elseif ($tamS3 -ne $a.Length) {
        Anotar ('    {0,-28} {1,12:N0} {2,12:N0}  {3}' -f $a.Name, $a.Length, $tamS3, 'DIFIERE')
        $diferencias++
    } else {
        Anotar ('    {0,-28} {1,12:N0} {2,12:N0}  {3}' -f $a.Name, $a.Length, $tamS3, 'OK')
    }
}

Anotar ''
if ($diferencias -eq 0) {
    Anotar "    LANDING ZONE VERIFICADA: los $($archivos.Count) archivos estan en S3 con el tamano exacto."
} else {
    Anotar "    HAY $diferencias ARCHIVOS CON PROBLEMAS."
}

Anotar ''
Anotar '    Nota: el ETL sigue leyendo los archivos desde el disco local. Migrar'
Anotar '    la lectura a S3 exigiria agregar boto3 al ETL y reescribir'
Anotar '    extract_files.py, cambio que no aporta al objetivo de la Semana 4 y'
Anotar '    que ademas rompería la corrida on-premise. S3 cumple aqui el papel'
Anotar '    de landing zone y de respaldo fuera de la maquina, que es para lo'
Anotar '    que se contrato.'

$registro | Set-Content -Path $salida -Encoding utf8
Escribir ''
Escribir "Evidencia: $salida" 'OK'
