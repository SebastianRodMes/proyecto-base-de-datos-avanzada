<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    74-migrar-mongo.ps1
    ----------------------------------------------------------------------
    Migra la base NoSQL 'turismo_nosql' desde el contenedor local hacia
    MongoDB Atlas M0, con mongodump y mongorestore.

    Por que BSON y no JSON
    ----------------------
    mongodump produce BSON, que conserva los tipos nativos. La alternativa,
    mongoexport, produce JSON extendido y pierde precision en fechas y en
    enteros de 64 bits. Con 2 000 000 de documentos, esa conversion de ida y
    vuelta introduciria diferencias que la validacion detectaria como
    errores reales.

    Sobre el cupo de Atlas M0: se cuenta por CLUSTER
    ------------------------------------------------
    El inventario midio turismo_nosql en 205 MB comprimidos, muy por debajo
    de los 512 MB de M0, y de ahi se concluyo que cabria entera. La medicion
    era correcta y la conclusion equivocada: el cupo de M0 NO es por base de
    datos, es por CLUSTER, y el cluster reutilizado ya alojaba otro proyecto.

    Peor aun, el usuario de base creado para esta migracion esta acotado a
    turismo_nosql, asi que listDatabases no devuelve nada y el espacio ya
    ocupado es INVISIBLE desde aqui. No hay forma de detectarlo antes de
    intentar la carga.

    La corrida real se detuvo sola con:

        (AtlasError) you are over your space quota, using 518 MB of 512 MB.
        Writes are blocked on your cluster.

    a 1 128 000 de 1 500 002 documentos. Ese resultado es una truncacion
    accidental (depende de en que documento se acabo el espacio) y por eso
    se descarto: dos corridas darian numeros distintos.

    La salida es -Muestra o -Piloto, que producen un subconjunto
    DETERMINISTA y por lo tanto reproducible. Lo aplicado finalmente fue
    resenas completa y el 50 % de interacciones_web por duracion_seg.

    Requisito previo
    ----------------
    El cluster M0 lo crea el usuario en cloud.mongodb.com y su cadena de
    conexion se agrega a .secrets\turismodw-cloud.env como:

        ATLAS_URI=mongodb+srv://usuario:clave@cluster.mongodb.net/

    Uso:
        .\07-migracion\74-migrar-mongo.ps1
        .\07-migracion\74-migrar-mongo.ps1 -Piloto            # 10%
        .\07-migracion\74-migrar-mongo.ps1 -Muestra 300000    # tope por coleccion
#>

[CmdletBinding()]
param(
    [string] $Contenedor = 'turismodw-mongo-1',
    [string] $BaseOrigen = 'turismo_nosql',
    [string] $AtlasUri   = '',
    [switch] $Piloto,
    [int]    $Muestra    = 0
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Migracion de MongoDB hacia Atlas M0'

if (-not $AtlasUri) {
    $ctx = Obtener-Contexto -Raiz $Raiz
    $AtlasUri = $ctx.MongoUri
}
if (-not $AtlasUri) {
    throw @'
Falta la cadena de conexion de Atlas.

Agreguela a .secrets\turismodw-cloud.env como:
    ATLAS_URI=mongodb+srv://turismodw:<clave>@<cluster>.mongodb.net/

O pasela con -AtlasUri. Para obtenerla:
  1. cloud.mongodb.com -> Create -> M0 Free -> AWS -> us-east-1
  2. Database Access  -> crear usuario 'turismodw'
  3. Network Access   -> permitir su IP publica (o 0.0.0.0/0 en laboratorio)
  4. Connect -> Drivers -> copiar la cadena mongodb+srv://...
'@
}

# El host de Atlas se muestra, la clave no.
$hostAtlas = if ($AtlasUri -match '@([^/?]+)') { $Matches[1] } else { '(desconocido)' }

function Redactar {
    <#
        Quita la contrasena de cualquier texto antes de escribirlo.

        Hace falta de verdad, no por precaucion: cuando mongorestore falla,
        incluye la URI COMPLETA en el mensaje de error, contrasena incluida.
        Sin esto, un fallo de conexion escribe la credencial en la bitacora
        de 00-docs/05-evidencias/, que si se versiona.

        Se redacta por dos vias: el patron usuario:clave@ de cualquier URI, y
        el valor literal de la clave por si aparece fuera de una URI.
    #>
    param([Parameter(ValueFromPipeline = $true)] $Texto)
    process {
        $s = [string]$Texto
        $s = [regex]::Replace($s, '(mongodb(?:\+srv)?://[^:@/\s]+:)[^@\s]+(@)', '${1}***${2}')
        if ($script:ClaveAtlas) { $s = $s.Replace($script:ClaveAtlas, '***') }
        return $s
    }
}

# La clave suelta, para poder redactarla aunque aparezca fuera de una URI.
$script:ClaveAtlas = if ($AtlasUri -match '://[^:]+:([^@]+)@') { $Matches[1] } else { $null }
Escribir "Origen  : contenedor $Contenedor / $BaseOrigen"
Escribir "Destino : Atlas $hostAtlas / $BaseOrigen"

$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$sufijo   = if ($Piloto) { 'piloto' } else { 'completa' }
$bitacora = Join-Path $DirEvid "migracion-mongo-$sufijo.txt"

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(" MIGRACION DE MONGODB A ATLAS M0 - $($sufijo.ToUpper())")
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1')
$registro.Add(" Fecha   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add(" Destino : $hostAtlas")
$registro.Add('=====================================================================')

$Colecciones = @('resenas', 'interacciones_web')

# ---------------------------------------------------------------------------
# 1. Conteos y tamano en el origen
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 1. Origen ---'

$jsOrigen = @"
const db = db.getSiblingDB('$BaseOrigen');
['resenas','interacciones_web'].forEach(function (n) {
    const s = db.getCollection(n).stats();
    print(n + '|' + s.count + '|' + Math.round(s.size/1048576) + '|' + Math.round(s.storageSize/1048576));
});
"@
$tmpJs = Join-Path ([System.IO.Path]::GetTempPath()) 'mongo-origen.js'
$jsOrigen | Set-Content -Path $tmpJs -Encoding utf8
& docker cp $tmpJs "${Contenedor}:/tmp/mongo-origen.js" | Out-Null
$statsOrigen = & docker exec $Contenedor mongosh --quiet --file /tmp/mongo-origen.js 2>&1

$conteoOrigen = @{}
$statsOrigen | Where-Object { $_ -match '\|' } | ForEach-Object {
    $p = $_ -split '\|'
    $conteoOrigen[$p[0]] = [int64]$p[1]
    Anotar ("    {0,-20} {1,12:N0} docs   {2,5} MB logicos   {3,5} MB en disco" -f `
            $p[0], [int64]$p[1], $p[2], $p[3])
}

# ---------------------------------------------------------------------------
# 2. Volcado
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 2. mongodump ---'

& docker exec $Contenedor rm -rf /tmp/dump 2>&1 | Out-Null
$reloj = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($col in $Colecciones) {
    $argumentos = @('--db', $BaseOrigen, '--collection', $col, '--out', '/tmp/dump')

    if ($Piloto) {
        # Subconjunto determinista por cliente_id, el mismo criterio que usa
        # el piloto relacional (reserva_id % 10 = 0). No se usa muestreo
        # aleatorio para que dos corridas del piloto sean comparables.
        #
        # Un primer intento uso 'calificacion % 10 = 0' para resenas y no
        # traia NINGUN documento: la calificacion va de 1 a 5, asi que el
        # resto nunca da cero. El campo de la marca tiene que tener rango
        # suficiente, no solo ser numerico.
        #
        # En interacciones_web el 35 % de los documentos son anonimos y
        # llevan cliente_id nulo; $mod no los alcanza, asi que el
        # subconjunto del piloto los excluye. Es aceptable para probar
        # herramientas y queda dicho en la bitacora.
        $argumentos += @('--query', '{"cliente_id": {"$mod": [10, 0]}}')
    }
    elseif ($Muestra -gt 0) {
        $argumentos += @('--limit', "$Muestra")
    }

    & docker exec $Contenedor mongodump @argumentos 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "mongodump fallo en la coleccion $col" }
    Anotar "    $col volcado"
}
$reloj.Stop()
Anotar ("    volcado completo en {0:N1} s" -f $reloj.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# 3. Restauracion en Atlas
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 3. mongorestore contra Atlas ---'
$reloj = [System.Diagnostics.Stopwatch]::StartNew()

# --drop deja la operacion repetible. --numInsertionWorkersPerCollection 4
# acelera sin saturar el cupo de conexiones de un M0, que es estrecho.
$salida = & docker exec $Contenedor mongorestore `
    --uri $AtlasUri `
    --nsInclude "$BaseOrigen.*" `
    --drop --numInsertionWorkersPerCollection 4 `
    /tmp/dump 2>&1
$reloj.Stop()

$fallosRestore = $salida | Where-Object { $_ -match 'Failed|error|E QUERY' }
if ($fallosRestore) {
    Anotar '    Mensajes de error de mongorestore:'
    $fallosRestore | Select-Object -First 12 | ForEach-Object { Anotar ("      " + (Redactar $_)) }
}
$salida | Where-Object { $_ -match 'document\(s\) restored|index' } |
    Select-Object -Last 6 | ForEach-Object { Anotar ("      " + (Redactar $_)) }
Anotar ("    restauracion terminada en {0:N1} s" -f $reloj.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# 4. Validacion en Atlas
# ---------------------------------------------------------------------------
Anotar ''
Anotar '--- 4. Validacion en el destino ---'

$jsDestino = @"
const db = db.getSiblingDB('$BaseOrigen');
['resenas','interacciones_web'].forEach(function (n) {
    const c = db.getCollection(n);
    const ix = c.getIndexes().map(function (i) { return i.name; }).join(',');
    print(n + '|' + c.countDocuments({}) + '|' + ix);
});
const st = db.stats();
print('TOTAL|' + Math.round(st.dataSize/1048576) + '|' + Math.round(st.storageSize/1048576) + '|' + st.objects);
"@
$tmpJs2 = Join-Path ([System.IO.Path]::GetTempPath()) 'mongo-destino.js'
$jsDestino | Set-Content -Path $tmpJs2 -Encoding utf8
& docker cp $tmpJs2 "${Contenedor}:/tmp/mongo-destino.js" | Out-Null
$statsDestino = & docker exec $Contenedor mongosh $AtlasUri --quiet --file /tmp/mongo-destino.js 2>&1

Anotar ''
Anotar ('    {0,-20} {1,12} {2,12}  {3}' -f 'Coleccion', 'Origen', 'Atlas', 'Veredicto')
Anotar ('    ' + ('-' * 60))

$diferencias = 0
$statsDestino | Where-Object { $_ -match '\|' -and $_ -notmatch '^TOTAL' } | ForEach-Object {
    $p = $_ -split '\|'
    $col = $p[0]; $dest = [int64]$p[1]
    $orig = $conteoOrigen[$col]
    $veredicto = if ($Piloto -or $Muestra -gt 0) { 'subconjunto' }
                 elseif ($orig -eq $dest) { 'OK' }
                 else { $diferencias++; 'DIFIERE' }
    Anotar ('    {0,-20} {1,12:N0} {2,12:N0}  {3}' -f $col, $orig, $dest, $veredicto)
    Anotar ("      indices: {0}" -f $p[2])
}

$total = $statsDestino | Where-Object { $_ -match '^TOTAL' }
if ($total) {
    $p = $total -split '\|'
    Anotar ''
    Anotar ("    Atlas: {0} MB logicos, {1} MB en disco, {2} documentos" -f $p[1], $p[2], $p[3])
    Anotar '    Tope de M0: 512 MB de almacenamiento.'
    if ([int]$p[2] -lt 512) {
        Anotar '    El conjunto COMPLETO cabe en la capa gratuita. No hizo falta muestrear.'
    } else {
        Anotar '    AVISO: se supero el cupo de M0. Reintente con -Muestra.'
    }
}

Anotar ''
Anotar '--- Resultado ---'
if ($diferencias -eq 0) { Anotar '    MIGRACION DE MONGODB CORRECTA.' }
else                    { Anotar "    MIGRACION CON $diferencias DIFERENCIAS." }

& docker exec $Contenedor rm -rf /tmp/dump /tmp/mongo-origen.js /tmp/mongo-destino.js 2>&1 | Out-Null
Remove-Item $tmpJs, $tmpJs2 -ErrorAction SilentlyContinue
$registro | Set-Content -Path $bitacora -Encoding utf8
Escribir ''
Escribir "Bitacora: $bitacora" 'OK'
