<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    73-migrar-postgres.ps1
    ----------------------------------------------------------------------
    Migra la base operacional 'turismo' desde el contenedor local hacia
    Amazon RDS for PostgreSQL 16, con pg_dump en formato custom.

    Por que se ejecuta dentro del contenedor
    ----------------------------------------
    pg_dump y pg_restore no estan instalados en el host Windows, pero si en
    la imagen postgres:16, y el contenedor tiene salida a internet. Correr
    las herramientas ahi evita pedirle al equipo que instale el cliente de
    PostgreSQL, y garantiza que la version de pg_dump coincida exactamente
    con la del servidor de origen (16.15), que es un requisito real: un
    pg_dump mas viejo que el servidor falla.

    Por que formato custom (-Fc) y no SQL plano
    -------------------------------------------
    El formato custom viene comprimido, permite restaurar en paralelo con
    -j, y sobre todo conserva la definicion completa de los objetos. Eso
    importa por el indice GIN sobre la columna JSONB de preferencia_cliente,
    que es el unico objeto realmente delicado del origen y el que mas
    facilmente se pierde con herramientas que copian filas y no estructura.

    Uso:
        .\07-migracion\73-migrar-postgres.ps1
        .\07-migracion\73-migrar-postgres.ps1 -Piloto   # 10% de reservas
#>

[CmdletBinding()]
param(
    [string] $Contenedor = 'turismodw-postgres-1',
    [string] $BaseOrigen = 'turismo',
    [string] $UsuarioOrigen = 'postgres',
    [switch] $Piloto,
    [int]    $Paralelo = 4
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Migracion de PostgreSQL hacia Amazon RDS'

$ctx = Obtener-Contexto -Raiz $Raiz
Probar-Endpoint -Identificador $ctx.PgId | Out-Null

Escribir "Origen  : contenedor $Contenedor / $BaseOrigen"
Escribir "Destino : $($ctx.PgEndpoint):5432 / turismo  (usuario $($ctx.PgUsuario))"

$DirEvid  = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$sufijo   = if ($Piloto) { 'piloto' } else { 'completa' }
$bitacora = Join-Path $DirEvid "migracion-postgres-$sufijo.txt"

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(" MIGRACION DE POSTGRESQL A AMAZON RDS - $($sufijo.ToUpper())")
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1')
$registro.Add(" Fecha   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add(" Destino : $($ctx.PgEndpoint)")
$registro.Add('=====================================================================')

# La contrasena viaja al contenedor por variable de entorno y no en la linea
# de comandos: asi no queda en el historial de procesos del contenedor.
$envDestino = "PGPASSWORD=$($ctx.PgClave)"

# ---------------------------------------------------------------------------
# 1. Conteos de origen (referencia contra la que se valida despues)
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 1. Conteos en el origen ---'

$consultaConteos = @'
SELECT 'cliente' AS t, count(*) FROM cliente
UNION ALL SELECT 'preferencia_cliente', count(*) FROM preferencia_cliente
UNION ALL SELECT 'hotel', count(*) FROM hotel
UNION ALL SELECT 'tipo_habitacion', count(*) FROM tipo_habitacion
UNION ALL SELECT 'tour', count(*) FROM tour
UNION ALL SELECT 'paquete_turistico', count(*) FROM paquete_turistico
UNION ALL SELECT 'paquete_hotel', count(*) FROM paquete_hotel
UNION ALL SELECT 'paquete_tour', count(*) FROM paquete_tour
UNION ALL SELECT 'reserva', count(*) FROM reserva
UNION ALL SELECT 'reserva_habitacion', count(*) FROM reserva_habitacion
UNION ALL SELECT 'reserva_tour', count(*) FROM reserva_tour
ORDER BY 1;
'@

$conteosOrigen = & docker exec $Contenedor psql -U $UsuarioOrigen -d $BaseOrigen -t -A -F '|' -c $consultaConteos 2>&1
$conteosOrigen | ForEach-Object { Anotar "    $_" }

$sumaOrigen = & docker exec $Contenedor psql -U $UsuarioOrigen -d $BaseOrigen -t -A `
    -c "SELECT to_char(sum(monto_total),'FM999999999990.00') FROM reserva;" 2>&1
Anotar "    suma monto_total = $($sumaOrigen -join '')"

# ---------------------------------------------------------------------------
# 2. Volcado
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 2. pg_dump en formato custom ---'

$rutaDump = '/tmp/turismo.dump'
$reloj = [System.Diagnostics.Stopwatch]::StartNew()

if ($Piloto) {
    # El piloto no puede usar --table con un WHERE: pg_dump no filtra filas.
    # Se crea una base de trabajo con el subconjunto y su cierre referencial,
    # y se vuelca esa. El subconjunto es determinista (reserva_id % 10 = 0)
    # para que dos corridas del piloto sean comparables entre si.
    Anotar '    Piloto: se construye el subconjunto del 10% con cierre referencial'
    $sqlPiloto = @'
DROP DATABASE IF EXISTS turismo_piloto;
CREATE DATABASE turismo_piloto;
'@
    & docker exec $Contenedor psql -U $UsuarioOrigen -d postgres -c $sqlPiloto 2>&1 | Out-Null

    # Estructura completa, datos filtrados.
    & docker exec $Contenedor sh -c "pg_dump -U $UsuarioOrigen -d $BaseOrigen --schema-only | psql -U $UsuarioOrigen -d turismo_piloto -q" 2>&1 | Out-Null

    # Se copia con COPY a traves de archivos intermedios: dblink no esta
    # instalado y no vale la pena agregar una extension solo para el piloto.
    # Las tablas pequenas van completas; las grandes, filtradas por reserva.
    $tablasCompletas = @('hotel','tipo_habitacion','tour','paquete_turistico',
                         'paquete_hotel','paquete_tour','importacion_datos','error_importacion')
    foreach ($t in $tablasCompletas) {
        & docker exec $Contenedor sh -c "psql -U $UsuarioOrigen -d $BaseOrigen -c \`"COPY $t TO '/tmp/$t.csv' CSV\`" && psql -U $UsuarioOrigen -d turismo_piloto -c \`"COPY $t FROM '/tmp/$t.csv' CSV\`"" 2>&1 | Out-Null
    }
    $filtros = @{
        'cliente'             = "SELECT * FROM cliente WHERE cliente_id IN (SELECT DISTINCT cliente_id FROM reserva WHERE reserva_id % 10 = 0)"
        'preferencia_cliente' = "SELECT * FROM preferencia_cliente WHERE cliente_id IN (SELECT DISTINCT cliente_id FROM reserva WHERE reserva_id % 10 = 0)"
        'reserva'             = "SELECT * FROM reserva WHERE reserva_id % 10 = 0"
        'reserva_habitacion'  = "SELECT * FROM reserva_habitacion WHERE reserva_id % 10 = 0"
        'reserva_tour'        = "SELECT * FROM reserva_tour WHERE reserva_id % 10 = 0"
    }
    foreach ($t in @('cliente','preferencia_cliente','reserva','reserva_habitacion','reserva_tour')) {
        $q = $filtros[$t]
        & docker exec $Contenedor sh -c "psql -U $UsuarioOrigen -d $BaseOrigen -c \`"COPY ($q) TO '/tmp/$t.csv' CSV\`" && psql -U $UsuarioOrigen -d turismo_piloto -c \`"COPY $t FROM '/tmp/$t.csv' CSV\`"" 2>&1 | Out-Null
    }

    & docker exec $Contenedor pg_dump -U $UsuarioOrigen -d turismo_piloto -Fc -f $rutaDump 2>&1 | Out-Null
} else {
    & docker exec $Contenedor pg_dump -U $UsuarioOrigen -d $BaseOrigen -Fc -f $rutaDump 2>&1 | Out-Null
}

if ($LASTEXITCODE -ne 0) { throw "pg_dump fallo con codigo $LASTEXITCODE" }
$reloj.Stop()

$tam = & docker exec $Contenedor sh -c "stat -c %s $rutaDump" 2>&1
Anotar ("    volcado listo: {0:N1} MB en {1:N1} s" -f ([double]($tam -join '') / 1MB), $reloj.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# 3. Restauracion en RDS
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 3. pg_restore contra RDS ---'
$reloj = [System.Diagnostics.Stopwatch]::StartNew()

# --clean --if-exists deja la restauracion repetible: si el script se vuelve
# a correr, no falla por objetos que ya existen.
# --no-owner y --no-acl porque el rol 'postgres' del origen no existe en RDS,
# donde el usuario maestro se llama distinto y no es superusuario.
$salidaRestore = & docker exec -e $envDestino $Contenedor pg_restore `
    -h $ctx.PgEndpoint -p 5432 -U $ctx.PgUsuario -d turismo `
    --clean --if-exists --no-owner --no-acl -j $Paralelo $rutaDump 2>&1
$reloj.Stop()

# pg_restore devuelve codigo != 0 por advertencias benignas (DROP de objetos
# que no existian en un destino vacio). Se reportan pero no abortan.
$errores = $salidaRestore | Where-Object { $_ -match 'error:' -and $_ -notmatch 'does not exist' }
if ($errores) {
    Anotar '    Advertencias y errores de pg_restore:'
    $errores | Select-Object -First 15 | ForEach-Object { Anotar "      $_" }
}
Anotar ("    restauracion terminada en {0:N1} s" -f $reloj.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# 4. Validacion: conteos, suma de control e indices
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 4. Validacion en el destino ---'

$conteosDestino = & docker exec -e $envDestino $Contenedor psql `
    -h $ctx.PgEndpoint -U $ctx.PgUsuario -d turismo -t -A -F '|' -c $consultaConteos 2>&1

Anotar ''
Anotar ('    {0,-24} {1,12} {2,12}  {3}' -f 'Tabla', 'Origen', 'Destino', 'Veredicto')
Anotar ('    ' + ('-' * 62))

$mapaOrigen = @{}
$conteosOrigen | Where-Object { $_ -match '\|' } | ForEach-Object {
    $p = $_ -split '\|'; $mapaOrigen[$p[0].Trim()] = [int64]$p[1].Trim()
}
$diferencias = 0
$conteosDestino | Where-Object { $_ -match '\|' } | ForEach-Object {
    $p = $_ -split '\|'
    $tabla = $p[0].Trim(); $dest = [int64]$p[1].Trim()
    $orig = $mapaOrigen[$tabla]
    $veredicto = if ($Piloto) { 'piloto' } elseif ($orig -eq $dest) { 'OK' } else { 'DIFIERE'; }
    if (-not $Piloto -and $orig -ne $dest) { $diferencias++ }
    Anotar ('    {0,-24} {1,12:N0} {2,12:N0}  {3}' -f $tabla, $orig, $dest, $veredicto)
}

$sumaDestino = & docker exec -e $envDestino $Contenedor psql `
    -h $ctx.PgEndpoint -U $ctx.PgUsuario -d turismo -t -A `
    -c "SELECT to_char(sum(monto_total),'FM999999999990.00') FROM reserva;" 2>&1
Anotar ''
Anotar "    suma monto_total origen  = $($sumaOrigen -join '')"
Anotar "    suma monto_total destino = $($sumaDestino -join '')"

# --- El indice GIN: el objeto que realmente hay que verificar -------------
Anotar ''
Anotar '--- 5. Indices en el destino (el GIN sobre JSONB es el critico) ---'
$indices = & docker exec -e $envDestino $Contenedor psql `
    -h $ctx.PgEndpoint -U $ctx.PgUsuario -d turismo -t -A -F '|' `
    -c "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='public' ORDER BY indexname;" 2>&1
$indices | Where-Object { $_ -match '\|' } | ForEach-Object { Anotar "    $_" }

$gin = $indices | Where-Object { $_ -match 'idx_pref_gin' -and $_ -match 'USING gin' }
if ($gin) {
    Anotar ''
    Anotar '    El indice GIN sobre preferencia_cliente.datos_adicionales SOBREVIVIO.'
} else {
    Anotar ''
    Anotar '    AVISO: no se encontro el indice GIN en el destino.'
    $diferencias++
}

# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- Resultado ---'
if ($diferencias -eq 0) { Anotar '    MIGRACION DE POSTGRESQL CORRECTA.' }
else                    { Anotar "    MIGRACION CON $diferencias DIFERENCIAS. Revise el detalle." }

& docker exec $Contenedor rm -f $rutaDump 2>&1 | Out-Null
$registro | Set-Content -Path $bitacora -Encoding utf8
Escribir ''
Escribir "Bitacora: $bitacora" 'OK'
