<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
    Integrante 1: Alex Herrera

    72-piloto-migracion.ps1
    ----------------------------------------------------------------------
    Migracion piloto de un subconjunto del 10 %, entregable obligatorio de
    la Semana 3.

    Para que sirve realmente un piloto
    ----------------------------------
    No para mover datos: para PROBAR LAS HERRAMIENTAS contra el destino
    real antes de comprometerse. Un piloto que copia unas filas y concluye
    "funciono" no aporta nada.

    Este responde cuatro preguntas que no se pueden contestar leyendo
    documentacion, y que cambian el plan de la Semana 4 segun el resultado:

      P1. Acepta RDS los filegroups por proposito?
          Si -> los scripts 41..45 y 47b migran SIN modificacion.
          No -> hay que degradar a PRIMARY y adaptarlos al vuelo.

      P2. Sirve la restauracion nativa desde S3 como ruta alterna?
          El inventario dice que NO deberia: rds_restore_database recrea
          los archivos por su tamano ASIGNADO (8 832 MB de datos mas
          3 072 MB de log = 11,9 GB), por encima del tope de 10 GB de
          Express. Se prueba para documentar el rechazo con el mensaje
          real del motor, no con una suposicion.

      P3. Aguanta el bcp de ODBC 17 el TLS obligatorio de RDS?
          El proyecto usa las herramientas de ODBC 17, que no aceptan la
          opcion -u. Si RDS exigiera validar el certificado del lado del
          cliente, habria que migrar a ODBC 18.

      P4. Sobrevive el indice GIN sobre JSONB en PostgreSQL?

    El subconjunto es DETERMINISTA (reserva_id % 10 = 0) y no aleatorio:
    dos corridas del piloto tienen que ser comparables entre si.

    Uso:
        .\07-migracion\72-piloto-migracion.ps1
        .\07-migracion\72-piloto-migracion.ps1 -SinMongo
#>

[CmdletBinding()]
param(
    [switch] $SinPostgres,
    [switch] $SinMongo,
    [switch] $SinDw,
    # La ruta alterna (P2) necesita hablar con el SQL Server LOCAL para generar
    # el respaldo, y con el contenedor para sacarlo de adentro.
    [string] $ServidorLocalPiloto = 'localhost,1433',
    [string] $UsuarioLocalPiloto  = 'sa',
    [string] $ClaveLocalPiloto    = 'Armagedon45*',
    [string] $ContenedorSql       = 'turismodw-sqlserver-1',
    # El respaldo completo pesa mas de 1 GB y subirlo lleva su tiempo. Con este
    # interruptor se salta P2 y el piloto solo responde P1, P3 y P4.
    [switch] $SinRutaAlterna
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Migracion piloto (subconjunto del 10 %)'

$ctx = Obtener-Contexto -Raiz $Raiz
$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$resumen = Join-Path $DirEvid 'piloto-resumen.txt'

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(' MIGRACION PILOTO - SUBCONJUNTO DETERMINISTA DEL 10 %')
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1: Alex Herrera')
$registro.Add(" Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add('=====================================================================')
$registro.Add('')
$registro.Add('Criterio del subconjunto: reserva_id % 10 = 0 mas su cierre')
$registro.Add('referencial. Determinista, no aleatorio, para que dos corridas del')
$registro.Add('piloto sean comparables entre si.')

$hallazgos = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------------
# 1. PostgreSQL
# ---------------------------------------------------------------------------
if (-not $SinPostgres) {
    Anotar ''
    Anotar '=== 1. PostgreSQL -> RDS for PostgreSQL ==='
    try {
        & (Join-Path $PSScriptRoot '73-migrar-postgres.ps1') -Piloto
        $bit = Join-Path $DirEvid 'migracion-postgres-piloto.txt'
        if (Test-Path $bit) {
            $texto = Get-Content $bit -Raw
            if ($texto -match 'GIN sobre preferencia_cliente.*SOBREVIVIO') {
                $hallazgos.Add('P4  El indice GIN sobre JSONB sobrevive a pg_restore. CONFIRMADO.')
            } else {
                $hallazgos.Add('P4  El indice GIN NO se encontro en el destino. REVISAR.')
            }
        }
    } catch {
        Anotar "    FALLO: $($_.Exception.Message)"
        $hallazgos.Add("P4  La migracion de PostgreSQL fallo: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# 2. MongoDB
# ---------------------------------------------------------------------------
if (-not $SinMongo) {
    Anotar ''
    Anotar '=== 2. MongoDB -> Atlas M0 ==='
    try {
        & (Join-Path $PSScriptRoot '74-migrar-mongo.ps1') -Piloto
    } catch {
        Anotar "    FALLO: $($_.Exception.Message)"
        $hallazgos.Add("MongoDB: la migracion piloto fallo: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# 3. DW por la ruta primaria: DDL portable + bcp
# ---------------------------------------------------------------------------
if (-not $SinDw) {
    Anotar ''
    Anotar '=== 3. DW -> RDS for SQL Server, ruta primaria (DDL + bcp) ==='
    try {
        & (Join-Path $PSScriptRoot '75-migrar-dw.ps1') -Piloto

        $modo = (Invocar-Sqlcmd -Servidor "$($ctx.SqlEndpoint),1433" -Usuario $ctx.SqlUsuario `
                                -Clave $ctx.SqlClave -Base 'TurismoDW' -Silencioso `
                                -Consulta "SET NOCOUNT ON; SELECT TOP 1 Modo FROM dbo.MigracionModo;").Salida
        if ($modo -match 'FILEGROUPS') {
            $hallazgos.Add('P1  RDS ACEPTA los filegroups por proposito. Los scripts 41..45 y 47b migran sin modificacion.')
        } elseif ($modo -match 'PRIMARY') {
            $hallazgos.Add('P1  RDS RECHAZA los filegroups. Se degrada a PRIMARY y 75-migrar-dw.ps1 adapta 41..45 quitando ON FG_*. La particion logica se conserva.')
        }
        $hallazgos.Add('P3  El bcp de ODBC 17 completo la carga contra el TLS de RDS. No hizo falta migrar a ODBC 18.')
    } catch {
        Anotar "    FALLO: $($_.Exception.Message)"
        $hallazgos.Add("P1/P3  La migracion del DW fallo: $($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------------------
# 4. Ruta alterna: restauracion nativa desde S3
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 4. Ruta alterna: BACKUP local -> S3 -> rds_restore_database ==='
Anotar ''
Anotar '    Se prueba para DOCUMENTAR el resultado, no porque se dependa de ella.'
Anotar '    El inventario predice que va a fallar: la restauracion recrea los'
Anotar '    archivos por su tamano asignado (11,9 GB) y Express topa en 10 GB.'
Anotar ''

if ($SinRutaAlterna) {
    Anotar '    OMITIDA por -SinRutaAlterna. P2 queda sin responder.'
    $hallazgos.Add('P2  NO SE PROBO: se corrio el piloto con -SinRutaAlterna.')
    $registro | Set-Content -Path $resumen -Encoding utf8
    Escribir ''
    Escribir "Resumen del piloto: $resumen" 'OK'
    return
}

try {
    # El respaldo NO existe hasta que este bloque lo crea. Una version previa
    # de este script asumia que 75-migrar-dw.ps1 lo dejaba en S3; no es asi,
    # 75 migra por DDL mas bcp y nunca toca S3. El resultado era que P2
    # fallaba siempre por archivo inexistente, y el mensaje de RDS parecia un
    # rechazo de la ruta alterna cuando en realidad era un archivo que nadie
    # habia subido. Ahora el respaldo se genera aqui.
    $rutaBakContenedor = '/var/opt/mssql/data/TurismoDW.bak'
    $rutaBakLocal      = Join-Path $env:TEMP 'TurismoDW.bak'

    Anotar '    4a. BACKUP DATABASE en el contenedor local ...'
    $sqlBackup = "BACKUP DATABASE TurismoDW TO DISK = N'$rutaBakContenedor' " +
                 "WITH INIT, COMPRESSION, STATS = 25;"
    $rb = Invocar-Sqlcmd -Servidor $ServidorLocalPiloto -Usuario $UsuarioLocalPiloto `
                         -Clave $ClaveLocalPiloto -Base 'master' -Consulta $sqlBackup -Silencioso
    if (-not $rb.Ok) { throw "BACKUP DATABASE fallo: $($rb.Salida)" }

    Anotar '    4b. Extrayendo el respaldo del contenedor y subiendolo a S3 ...'
    & docker cp "${ContenedorSql}:$rutaBakContenedor" $rutaBakLocal 2>&1 | Out-Null
    if (-not (Test-Path $rutaBakLocal)) { throw "No se pudo extraer $rutaBakContenedor del contenedor." }
    $mb = (Get-Item $rutaBakLocal).Length / 1MB
    Anotar ("        respaldo de {0:N1} MB" -f $mb)

    & aws s3 cp $rutaBakLocal "s3://$($ctx.Bucket)/bak/TurismoDW.bak" --no-progress 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "aws s3 cp fallo al subir el respaldo." }
    Remove-Item $rutaBakLocal -ErrorAction SilentlyContinue
    & docker exec $ContenedorSql rm -f $rutaBakContenedor 2>&1 | Out-Null
    Anotar '        subido a s3://.../bak/TurismoDW.bak'

    Anotar '    4c. rds_restore_database contra RDS ...'
    $consultaRestore = @"
EXEC msdb.dbo.rds_restore_database
     @restore_db_name='TurismoDW_bak',
     @s3_arn_to_restore_from='arn:aws:s3:::$($ctx.Bucket)/bak/TurismoDW.bak';
"@
    $r = Invocar-Sqlcmd -Servidor "$($ctx.SqlEndpoint),1433" -Usuario $ctx.SqlUsuario `
                        -Clave $ctx.SqlClave -Base 'master' -Consulta $consultaRestore -Silencioso

    if ($r.Ok) {
        Anotar '    La tarea de restauracion fue aceptada por RDS. Estado:'
        $est = Invocar-Sqlcmd -Servidor "$($ctx.SqlEndpoint),1433" -Usuario $ctx.SqlUsuario `
                              -Clave $ctx.SqlClave -Base 'master' -Silencioso `
                              -Consulta "EXEC msdb.dbo.rds_task_status @db_name='TurismoDW_bak';"
        Anotar $est.Salida
        $hallazgos.Add('P2  RDS acepto la tarea de restauracion nativa desde S3. Revisar rds_task_status para el desenlace.')
    } else {
        $motivo = ($r.Salida -split "`n" | Where-Object { $_ -match 'Msg|error|not' } | Select-Object -First 3) -join ' '
        Anotar "    RDS rechazo la restauracion: $motivo"
        $hallazgos.Add("P2  La restauracion nativa desde S3 NO sirve aqui. Motivo del motor: $motivo")
    }
} catch {
    Anotar "    No se pudo probar la ruta alterna: $($_.Exception.Message)"
    $hallazgos.Add("P2  No se pudo probar la restauracion nativa: $($_.Exception.Message)")
}

# ---------------------------------------------------------------------------
# Hallazgos
# ---------------------------------------------------------------------------
Anotar ''
Anotar '====================================================================='
Anotar ' HALLAZGOS DEL PILOTO'
Anotar '====================================================================='
Anotar ''
if ($hallazgos.Count -eq 0) {
    Anotar '    El piloto no produjo hallazgos. Revise las bitacoras individuales.'
} else {
    foreach ($h in $hallazgos) { Anotar "    $h" }
}

Anotar ''
Anotar 'Bitacoras individuales:'
Anotar '    00-docs/05-evidencias/migracion/migracion-postgres-piloto.txt'
Anotar '    00-docs/05-evidencias/migracion/migracion-mongo-piloto.txt'
Anotar '    00-docs/05-evidencias/migracion/migracion-dw-piloto.txt'

$registro | Set-Content -Path $resumen -Encoding utf8
Escribir ''
Escribir "Resumen del piloto: $resumen" 'OK'
Escribir ''
Escribir 'Si los hallazgos son favorables, siga con la migracion completa:' 'OK'
Escribir '    .\07-migracion\73-migrar-postgres.ps1'
Escribir '    .\07-migracion\74-migrar-mongo.ps1'
Escribir '    .\07-migracion\75-migrar-dw.ps1'
