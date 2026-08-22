<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
    Integrante 1: Alex Herrera

    71-inventario-objetos.ps1
    ----------------------------------------------------------------------
    Genera el inventario de objetos a migrar consultando los TRES motores
    de origen en vivo: SQL Server, PostgreSQL y MongoDB.

    Entregable de Semana 3: "Crear inventario de objetos a migrar: tablas,
    colecciones, vistas, procedimientos, indices".

    Se lee del catalogo del motor y no de los scripts DDL a proposito. Un
    inventario transcrito del codigo fuente describe lo que se penso crear;
    para decidir que migra y que no, solo sirve lo que realmente existe.

    Salida:
        00-docs/05-evidencias/migracion/inventario-sqlserver.txt
        00-docs/05-evidencias/migracion/inventario-postgresql.txt
        00-docs/05-evidencias/migracion/inventario-mongodb.txt

    Uso:
        .\07-migracion\71-inventario-objetos.ps1
#>

[CmdletBinding()]
param(
    [string] $ServidorSql = 'localhost,1433',
    [string] $UsuarioSql  = 'sa',
    [string] $ClaveSql    = 'Armagedon45*',
    [string] $BaseSql     = 'TurismoDW',
    [string] $ContenedorPg    = 'turismodw-postgres-1',
    [string] $ContenedorMongo = 'turismodw-mongo-1',
    [string] $BasePg    = 'turismo',
    [string] $BaseMongo = 'turismo_nosql'
)

$ErrorActionPreference = 'Stop'

$Raiz    = Split-Path -Parent $PSScriptRoot
$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null

function Escribir($texto, $nivel = 'INFO') {
    $color = switch ($nivel) { 'OK' {'Green'} 'AVISO' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
    Write-Host ("[{0}] {1}" -f $nivel.PadRight(5), $texto) -ForegroundColor $color
}

Write-Host ('=' * 78)
Write-Host ' ITI-821 | Escenario 8 | Inventario de objetos a migrar'
Write-Host ' Integrante 1: Alex Herrera'
Write-Host ('=' * 78)

# ---------------------------------------------------------------------------
# 1. SQL Server
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 1. SQL Server (TurismoDW) ---'

$salidaSql = Join-Path $DirEvid 'inventario-sqlserver.txt'
$scriptSql = Join-Path $PSScriptRoot 'sql\71-inventario-sqlserver.sql'

$encabezado = @"
=====================================================================
 INVENTARIO DE OBJETOS A MIGRAR - SQL SERVER
 ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1
 Generado  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
 Servidor  : $ServidorSql
 Base      : $BaseSql
=====================================================================
"@

# -W recorta el relleno a la derecha. No se combinan -y/-Y porque sqlcmd los
# rechaza junto con -W; el ancho ya viene acotado por los CONVERT del script.
& sqlcmd -S $ServidorSql -U $UsuarioSql -P $ClaveSql -C -d $BaseSql `
         -i $scriptSql -W -s ' | ' 2>&1 |
    ForEach-Object { $_ } |
    Set-Content -Path "$salidaSql.tmp" -Encoding utf8

if ($LASTEXITCODE -ne 0) {
    Escribir "sqlcmd devolvio codigo $LASTEXITCODE. Revise $salidaSql.tmp" 'AVISO'
}
$encabezado, (Get-Content "$salidaSql.tmp") | Set-Content -Path $salidaSql -Encoding utf8
Remove-Item "$salidaSql.tmp" -ErrorAction SilentlyContinue
Escribir "-> $salidaSql" 'OK'

# ---------------------------------------------------------------------------
# 2. PostgreSQL
#    Se entra por docker exec: el compose no expone psql en el host y usar
#    el cliente del propio contenedor evita depender de que este instalado.
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 2. PostgreSQL (turismo) ---'

$salidaPg = Join-Path $DirEvid 'inventario-postgresql.txt'

$sqlPg = @'
\echo ''
\echo '=== 0. Version y tamano de la base ==='
SELECT version() AS version;
SELECT pg_size_pretty(pg_database_size(current_database())) AS tamano_total;

\echo ''
\echo '=== 1. Tablas, filas reales y tamano ==='
SELECT c.relname AS tabla,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = c.relname AND table_schema = 'public') AS columnas,
       c.reltuples::bigint AS filas_estimadas,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind = 'r'
 ORDER BY pg_total_relation_size(c.oid) DESC;

\echo ''
\echo '=== 2. Conteo exacto de filas por tabla ==='
SELECT 'cliente' AS tabla, count(*) FROM cliente
UNION ALL SELECT 'preferencia_cliente', count(*) FROM preferencia_cliente
UNION ALL SELECT 'hotel',               count(*) FROM hotel
UNION ALL SELECT 'tipo_habitacion',     count(*) FROM tipo_habitacion
UNION ALL SELECT 'tour',                count(*) FROM tour
UNION ALL SELECT 'paquete_turistico',   count(*) FROM paquete_turistico
UNION ALL SELECT 'paquete_hotel',       count(*) FROM paquete_hotel
UNION ALL SELECT 'paquete_tour',        count(*) FROM paquete_tour
UNION ALL SELECT 'reserva',             count(*) FROM reserva
UNION ALL SELECT 'reserva_habitacion',  count(*) FROM reserva_habitacion
UNION ALL SELECT 'reserva_tour',        count(*) FROM reserva_tour
UNION ALL SELECT 'importacion_datos',   count(*) FROM importacion_datos
UNION ALL SELECT 'error_importacion',   count(*) FROM error_importacion
ORDER BY 2 DESC;

\echo ''
\echo '=== 3. Columnas de tipo JSONB (delicadas al migrar) ==='
SELECT table_name, column_name, data_type
  FROM information_schema.columns
 WHERE table_schema = 'public' AND data_type IN ('jsonb','json')
 ORDER BY table_name;

\echo ''
\echo '=== 4. Indices (el GIN sobre JSONB es el critico) ==='
SELECT tablename, indexname, indexdef
  FROM pg_indexes
 WHERE schemaname = 'public'
 ORDER BY tablename, indexname;

\echo ''
\echo '=== 5. Claves foraneas ==='
SELECT tc.constraint_name, tc.table_name AS origen,
       ccu.table_name AS destino, kcu.column_name AS columna
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name
  JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
 WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
 ORDER BY tc.table_name;

\echo ''
\echo '=== 6. Secuencias ==='
SELECT sequence_name, data_type FROM information_schema.sequences
 WHERE sequence_schema = 'public' ORDER BY sequence_name;

\echo ''
\echo '=== 7. Vistas, funciones y procedimientos ==='
SELECT table_name AS vista FROM information_schema.views WHERE table_schema='public';
SELECT routine_name, routine_type FROM information_schema.routines
 WHERE routine_schema = 'public' ORDER BY routine_name;

\echo ''
\echo '=== 8. Extensiones instaladas ==='
SELECT extname, extversion FROM pg_extension ORDER BY extname;

\echo ''
\echo '=== 9. Resumen contable ==='
SELECT 'tablas' AS categoria, count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'
UNION ALL SELECT 'indices',     count(*) FROM pg_indexes WHERE schemaname='public'
UNION ALL SELECT 'secuencias',  count(*) FROM information_schema.sequences WHERE sequence_schema='public'
UNION ALL SELECT 'claves foraneas', count(*) FROM information_schema.table_constraints WHERE constraint_type='FOREIGN KEY' AND table_schema='public'
UNION ALL SELECT 'vistas',      count(*) FROM information_schema.views WHERE table_schema='public'
UNION ALL SELECT 'rutinas',     count(*) FROM information_schema.routines WHERE routine_schema='public';
'@

$tmpPg = Join-Path ([System.IO.Path]::GetTempPath()) 'inv-pg.sql'
$sqlPg | Set-Content -Path $tmpPg -Encoding utf8

& docker cp $tmpPg "${ContenedorPg}:/tmp/inv-pg.sql" | Out-Null
$resPg = & docker exec $ContenedorPg psql -U postgres -d $BasePg -f /tmp/inv-pg.sql 2>&1

@"
=====================================================================
 INVENTARIO DE OBJETOS A MIGRAR - POSTGRESQL
 ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1
 Generado  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
 Contenedor: $ContenedorPg
 Base      : $BasePg
=====================================================================
"@ | Set-Content -Path $salidaPg -Encoding utf8
$resPg | Add-Content -Path $salidaPg -Encoding utf8
Remove-Item $tmpPg -ErrorAction SilentlyContinue
Escribir "-> $salidaPg" 'OK'

# ---------------------------------------------------------------------------
# 3. MongoDB
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 3. MongoDB (turismo_nosql) ---'

$salidaMongo = Join-Path $DirEvid 'inventario-mongodb.txt'

$jsMongo = @'
const db = db.getSiblingDB("turismo_nosql");

print("");
print("=== 0. Version del servidor ===");
print(db.version());

print("");
print("=== 1. Colecciones, documentos y tamano ===");
db.getCollectionNames().sort().forEach(function (n) {
    const s = db.getCollection(n).stats();
    print(
        n.padEnd(24) +
        " docs=" + String(s.count).padStart(10) +
        " datos=" + String(Math.round(s.size / 1048576)).padStart(6) + " MB" +
        " indices=" + String(Math.round(s.totalIndexSize / 1048576)).padStart(5) + " MB" +
        " total=" + String(Math.round((s.size + s.totalIndexSize) / 1048576)).padStart(6) + " MB"
    );
});

print("");
print("=== 2. Indices por coleccion ===");
db.getCollectionNames().sort().forEach(function (n) {
    print("-- " + n);
    db.getCollection(n).getIndexes().forEach(function (i) {
        print("   " + i.name.padEnd(32) + " " + JSON.stringify(i.key));
    });
});

print("");
print("=== 3. Forma del documento (campos de una muestra) ===");
db.getCollectionNames().sort().forEach(function (n) {
    const d = db.getCollection(n).findOne();
    if (!d) { return; }
    print("-- " + n);
    Object.keys(d).forEach(function (k) {
        let t = Array.isArray(d[k]) ? "array" : (d[k] === null ? "null" : typeof d[k]);
        if (d[k] instanceof Date) { t = "date"; }
        print("   " + k.padEnd(22) + " " + t);
    });
});

print("");
print("=== 4. Tamano total de la base (define si cabe en Atlas M0, tope 512 MB) ===");
const st = db.stats();
print("dataSize   : " + Math.round(st.dataSize   / 1048576) + " MB");
print("indexSize  : " + Math.round(st.indexSize  / 1048576) + " MB");
print("storageSize: " + Math.round(st.storageSize / 1048576) + " MB");
print("objetos    : " + st.objects);

print("");
print("=== 5. Resumen contable ===");
print("colecciones: " + db.getCollectionNames().length);
let ix = 0;
db.getCollectionNames().forEach(function (n) { ix += db.getCollection(n).getIndexes().length; });
print("indices    : " + ix);
'@

$tmpMongo = Join-Path ([System.IO.Path]::GetTempPath()) 'inv-mongo.js'
$jsMongo | Set-Content -Path $tmpMongo -Encoding utf8

& docker cp $tmpMongo "${ContenedorMongo}:/tmp/inv-mongo.js" | Out-Null
$resMongo = & docker exec $ContenedorMongo mongosh --quiet --file /tmp/inv-mongo.js 2>&1

@"
=====================================================================
 INVENTARIO DE OBJETOS A MIGRAR - MONGODB
 ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1
 Generado  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
 Contenedor: $ContenedorMongo
 Base      : $BaseMongo
=====================================================================
"@ | Set-Content -Path $salidaMongo -Encoding utf8
$resMongo | Add-Content -Path $salidaMongo -Encoding utf8
Remove-Item $tmpMongo -ErrorAction SilentlyContinue
Escribir "-> $salidaMongo" 'OK'

# ---------------------------------------------------------------------------
# 4. Archivos planos
# ---------------------------------------------------------------------------
Escribir ''
Escribir '--- 4. Archivos JSON y XML ---'
$dirEntrada = Join-Path $Raiz '03-archivos\entrada'
$archivos = Get-ChildItem -Path $dirEntrada -File | Sort-Object Name
$archivos | ForEach-Object {
    Escribir ("  {0,-28} {1,8:N0} KB" -f $_.Name, ($_.Length / 1KB))
}

@"

=== 5. Archivos planos de origen ===
"@ | Add-Content -Path $salidaMongo -Encoding utf8
$archivos | ForEach-Object {
    ("{0,-28} {1,8:N0} KB" -f $_.Name, ($_.Length / 1KB)) |
        Add-Content -Path $salidaMongo -Encoding utf8
}

Escribir ''
Escribir 'Inventario completo. Tres archivos en 00-docs/05-evidencias/migracion/' 'OK'
Escribir 'Siguiente: consolidar en 00-docs/09-inventario-migracion.md'
