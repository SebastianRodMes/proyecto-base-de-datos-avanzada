<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    75-migrar-dw.ps1
    ----------------------------------------------------------------------
    Migra TurismoDW desde el SQL Server local hacia Amazon RDS for SQL
    Server, por la ruta primaria: DDL portable mas bcp.

    Secuencia
    ---------
      1. Crear la base en RDS         40-crear-basedatos.rds.sql
      2. Leer el modo aplicado        dbo.MigracionModo (FILEGROUPS|PRIMARY)
      3. Esquema y logica             41..45 (adaptados si modo = PRIMARY)
      4. Vista de estado para RDS     45b-vistas-estado-rds.sql
      5. Control incremental          43b y 44b
      6. Particionamiento             47b-particionamiento.rds.sql
      7. Copia de datos               bcp out local -> bcp in RDS
      8. Indices y columnstore        47c-indices-tuning.sql
      9. Revalidacion de claves       etl.usp_VerificarIntegridad

    Por que el orden difiere del on-premise
    ---------------------------------------
    En el laboratorio local el orden es cargar, luego 47b y luego 47c,
    porque el Integrante 2 particiono una base que ya estaba poblada. Aqui
    se particiona ANTES de copiar: 47b reconstruye el indice agrupado de
    cuatro tablas de hechos, y hacerlo sobre 8,2 millones de filas en una
    db.t3.micro costaria mucho mas que hacerlo sobre tablas vacias. El
    resultado final es identico; lo que cambia es cuanto tarda.

    Los indices columnstore de 47c si van despues de la carga, que ademas
    es la recomendacion habitual: construirlos sobre datos ya presentes es
    mas rapido que alimentarlos fila por fila durante la copia.

    El adaptador de filegroups
    --------------------------
    Los scripts 41 a 45 llevan clausulas ON FG_DIM, ON FG_FACT, ON FG_STG y
    ON FG_IDX incrustadas. Si RDS acepto los filegroups, se ejecutan tal
    cual. Si no, este script los reescribe al vuelo quitando esas clausulas
    antes de mandarlos. Los archivos originales NUNCA se modifican: la copia
    adaptada se escribe en una carpeta temporal.

    Uso:
        .\07-migracion\75-migrar-dw.ps1
        .\07-migracion\75-migrar-dw.ps1 -SoloEsquema
        .\07-migracion\75-migrar-dw.ps1 -Piloto        # solo 10% de reservas
#>

[CmdletBinding()]
param(
    [string] $ServidorLocal = 'localhost,1433',
    [string] $UsuarioLocal  = 'sa',
    [string] $ClaveLocal    = 'Armagedon45*',
    [string] $BaseLocal     = 'TurismoDW',
    [switch] $SoloEsquema,
    [switch] $SoloDatos,
    [switch] $Piloto,
    # Filas por lote de bcp. Se usa 10 000 y no las 50 000 del ETL local:
    # una instancia RDS pequena otorga concesiones de memoria mucho mas
    # modestas, y un lote grande se queda esperando en RESOURCE_SEMAPHORE
    # en vez de fallar, lo que parece un cuelgue.
    [int] $TamanoLote = 10000
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Migracion del DW hacia Amazon RDS for SQL Server'

Probar-Herramienta 'sqlcmd' 'Instale las herramientas de linea de comandos de SQL Server.' | Out-Null
Probar-Herramienta 'bcp'    'bcp viene con las herramientas de SQL Server.'                  | Out-Null

$ctx = Obtener-Contexto -Raiz $Raiz
Probar-Endpoint -Identificador $ctx.SqlId | Out-Null

$Destino = "$($ctx.SqlEndpoint),1433"
Escribir "Origen  : $ServidorLocal / $BaseLocal"
Escribir "Destino : $Destino / TurismoDW  (usuario $($ctx.SqlUsuario))"

$DirEvid    = Join-Path $Raiz '00-docs\05-evidencias\migracion'
$DirTrabajo = Join-Path $env:TEMP 'turismodw-migracion'
$DirAdaptado= Join-Path $DirTrabajo 'sql-adaptado'
New-Item -ItemType Directory -Force -Path $DirEvid, $DirTrabajo, $DirAdaptado | Out-Null

$sufijo   = if ($Piloto) { 'piloto' } else { 'completa' }
$bitacora = Join-Path $DirEvid "migracion-dw-$sufijo.txt"
$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(" MIGRACION DEL DW A AMAZON RDS - $($sufijo.ToUpper())")
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1')
$registro.Add(" Fecha   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add(" Origen  : $ServidorLocal / $BaseLocal")
$registro.Add(" Destino : $Destino / TurismoDW")
$registro.Add('=====================================================================')

# ---------------------------------------------------------------------------
# Tablas a copiar. El orden respeta las dependencias de clave foranea:
# dimensiones antes que hechos. Las de staging NO llevan datos (el ETL las
# trunca en cada corrida) y las de bitacora empiezan limpias en la nube.
# ---------------------------------------------------------------------------
$TablasDatos = @(
    'dw.DimTiempo', 'dw.DimCliente', 'dw.DimHotel', 'dw.DimTipoHabitacion',
    'dw.DimTour', 'dw.DimPaquete', 'dw.DimEstadoReserva', 'dw.DimCanal',
    'etl.Numeros',
    'dw.FactReserva', 'dw.FactReservaHabitacion', 'dw.FactReservaTour',
    'dw.FactOcupacionDiaria', 'dw.FactResena', 'dw.FactInteraccionWeb'
)

# ===========================================================================
# FASE A. Esquema
# ===========================================================================
if (-not $SoloDatos) {

    Anotar ''
    Anotar '--- A1. Creacion de la base en RDS ---'
    $r = Medir-Paso '40-crear-basedatos.rds.sql' {
        Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                       -Base 'master' -Archivo (Join-Path $PSScriptRoot 'sql\40-crear-basedatos.rds.sql')
    }
    if (-not $r.Ok) { throw "Fallo la creacion de la base en RDS." }
    $registro.Add($r.Salida)

    # --- Modo aplicado --------------------------------------------------
    $modo = (Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                            -Base 'TurismoDW' -Silencioso `
                            -Consulta "SET NOCOUNT ON; SELECT TOP 1 Modo FROM dbo.MigracionModo;").Salida
    $modo = ($modo -split "`n" | Where-Object { $_ -match 'FILEGROUPS|PRIMARY' } | Select-Object -First 1).Trim()
    Anotar ''
    Anotar "--- A2. Modo de esquema aplicado por RDS: $modo ---"
    if ($modo -eq 'FILEGROUPS') {
        Anotar '    RDS acepto los filegroups por proposito.'
        Anotar '    Los scripts 41..45 y 47b se ejecutan SIN modificacion.'
    } else {
        Anotar '    RDS rechazo los filegroups: se degrada a PRIMARY.'
        Anotar '    Los scripts 41..45 se adaptan quitando las clausulas ON FG_*.'
        Anotar '    La particion LOGICA se conserva completa (ALL TO [PRIMARY]).'
    }

    # --- Adaptador ------------------------------------------------------
    function Resolver-Script {
        <#
            Devuelve la ruta del script a ejecutar. En modo FILEGROUPS es el
            original. En modo PRIMARY escribe una copia adaptada en la
            carpeta temporal y devuelve esa; el archivo del repositorio no
            se toca nunca.
        #>
        param([string] $Ruta)

        if ($modo -eq 'FILEGROUPS') { return $Ruta }

        $texto = Get-Content $Ruta -Raw
        # Quita 'ON FG_XXX' al final de un CREATE TABLE / CREATE INDEX.
        $texto = [regex]::Replace($texto, '(?im)\s+ON\s+\[?FG_[A-Z0-9_]+\]?\s*(?=;|\r?\n)', '')
        # Quita 'ON FG_XXX' pegado a un parentesis de cierre.
        $texto = [regex]::Replace($texto, '(?im)\)\s*ON\s+\[?FG_[A-Z0-9_]+\]?', ')')

        $salida = Join-Path $DirAdaptado (Split-Path $Ruta -Leaf)
        Set-Content -Path $salida -Value $texto -Encoding utf8
        return $salida
    }

    Anotar ''
    Anotar '--- A3. Esquema, transformacion y vistas ---'
    $scripts = @(
        '41-esquema-staging.sql',
        '42-esquema-estrella.sql',
        '43-etl-control.sql',
        '44-transformacion.sql',
        '45-vistas-powerbi.sql',
        '43b-carga-incremental.sql',
        '44b-transformacion-incremental.sql'
    )
    foreach ($s in $scripts) {
        $ruta = Resolver-Script (Join-Path $Raiz "04-sqlserver\$s")
        $r = Medir-Paso $s {
            Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                           -Base 'TurismoDW' -Archivo $ruta -Silencioso
        }
        if (-not $r.Ok) {
            $registro.Add($r.Salida)
            $registro | Set-Content -Path $bitacora -Encoding utf8
            throw "Fallo $s. Detalle en $bitacora"
        }
    }

    Anotar ''
    Anotar '--- A4. Vista de estado adaptada a RDS ---'
    $r = Medir-Paso '45b-vistas-estado-rds.sql' {
        Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                       -Base 'TurismoDW' -Archivo (Join-Path $PSScriptRoot 'sql\45b-vistas-estado-rds.sql')
    }
    $registro.Add($r.Salida)

    Anotar ''
    Anotar '--- A5. Particionamiento (sobre tablas vacias: barato) ---'
    $r = Medir-Paso '47b-particionamiento.rds.sql' {
        Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                       -Base 'TurismoDW' -Archivo (Join-Path $PSScriptRoot 'sql\47b-particionamiento.rds.sql') -Silencioso
    }
    if (-not $r.Ok) { Anotar "    AVISO: el particionamiento fallo. $($r.Salida)" }
}

if ($SoloEsquema) {
    $registro | Set-Content -Path $bitacora -Encoding utf8
    Escribir ''
    Escribir "Esquema migrado. Bitacora en $bitacora" 'OK'
    return
}

# ===========================================================================
# FASE B. Datos
# ===========================================================================

# Con -SoloDatos la fase A no corrio y $modo quedaria vacio, con lo que la
# fase C trataria la base como si fuera PRIMARY y le quitaria las clausulas
# ON FG_* a los indices de 47c aunque los filegroups SI existan. Se lee el
# modo real de la base en vez de suponerlo.
if (-not $modo) {
    $modo = (Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                            -Base 'TurismoDW' -Silencioso `
                            -Consulta "SET NOCOUNT ON; SELECT TOP 1 Modo FROM dbo.MigracionModo;").Salida
    $modo = ($modo -split "`n" | Where-Object { $_ -match 'FILEGROUPS|PRIMARY' } | Select-Object -First 1)
    $modo = if ($modo) { $modo.Trim() } else { 'PRIMARY' }
    Anotar ''
    Anotar "--- Modo leido de la base: $modo ---"
}

Anotar ''
Anotar '--- B1. Desactivacion temporal de claves foraneas en el destino ---'
# Se copian dimensiones antes que hechos, pero una tabla particionada puede
# recibir filas cuya dimension aun no llego si el orden se altera. Apagar las
# FK durante la copia y revalidarlas al final en bloque es lo mismo que hace
# etl.usp_CargarHechos, y es mucho mas barato que validar fila por fila.
$sqlOff = ($TablasDatos | Where-Object { $_ -like 'dw.*' } |
           ForEach-Object { "ALTER TABLE $_ NOCHECK CONSTRAINT ALL;" }) -join ' '
Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
               -Base 'TurismoDW' -Consulta $sqlOff -Silencioso | Out-Null

Anotar ''
Anotar '--- B1b. Vaciado del destino antes de copiar ---'
# Los scripts de esquema SIEMBRAN filas: 42-esquema-estrella.sql pone el
# centinela -1 en las ocho dimensiones, llena dw.DimTiempo con 2 923 dias y
# dw.DimEstadoReserva con su catalogo de 4; 44-transformacion.sql llena
# etl.Numeros con 4 000. bcp AGREGA filas, no reemplaza, asi que sin vaciar
# antes cada una de esas tablas viola su clave primaria y la copia falla.
#
# Se usa DELETE y no TRUNCATE: TRUNCATE lo bloquea la sola EXISTENCIA de una
# clave foranea que apunte a la tabla, aunque este deshabilitada.
#
# El orden es el inverso al de carga (hechos primero) para que ninguna
# dimension se vacie mientras todavia la referencian filas de hechos.
$ordenBorrado = @($TablasDatos)
[array]::Reverse($ordenBorrado)
$sqlDelete = ($ordenBorrado | ForEach-Object { "DELETE FROM $_;" }) -join ' '
$r = Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                    -Base 'TurismoDW' -Consulta $sqlDelete -Silencioso
if ($r.Ok) { Anotar "    $($TablasDatos.Count) tablas vaciadas en el destino." }
else       { throw "No se pudo vaciar el destino: $($r.Salida)" }

Anotar ''
Anotar '--- B2. Copia de datos con bcp ---'
Anotar ''
Anotar ('    {0,-28} {1,12} {2,12} {3,10} {4,9}' -f 'Tabla', 'Origen', 'Destino', 'MB', 'Segundos')
Anotar ('    ' + ('-' * 74))

$totalFilas = 0
$totalSeg   = 0.0
$fallos     = @()

foreach ($tabla in $TablasDatos) {

    $archivo = Join-Path $DirTrabajo ("{0}.bcp" -f ($tabla -replace '\.', '_'))
    $reloj   = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Salida desde el origen -----------------------------------------
    # -n = formato nativo. Evita conversiones de texto y los problemas de
    # delimitadores que si tiene el ETL (que usa texto porque genera los
    # archivos desde Python). Origen y destino son ambos SQL Server 2022,
    # asi que el formato nativo es compatible.
    if ($Piloto -and $tabla -eq 'dw.FactReserva') {
        # Subconjunto determinista del 10%: no aleatorio, para que dos
        # corridas del piloto sean comparables entre si.
        $consulta = "SELECT * FROM dw.FactReserva WHERE ReservaId % 10 = 0"
        & bcp $consulta queryout $archivo -S $ServidorLocal -U $UsuarioLocal -P $ClaveLocal `
              -d $BaseLocal -n -q 2>&1 | Out-Null
    }
    elseif ($Piloto -and $tabla -in @('dw.FactReservaHabitacion','dw.FactReservaTour','dw.FactOcupacionDiaria','dw.FactResena','dw.FactInteraccionWeb')) {
        $clave = switch ($tabla) {
            'dw.FactReservaHabitacion' { 'ReservaId % 10 = 0' }
            'dw.FactReservaTour'       { 'ReservaId % 10 = 0' }
            'dw.FactOcupacionDiaria'   { 'OcupacionKey % 10 = 0' }
            'dw.FactResena'            { 'ResenaId % 10 = 0' }
            'dw.FactInteraccionWeb'    { 'InteraccionId % 10 = 0' }
        }
        $consulta = "SELECT * FROM $tabla WHERE $clave"
        & bcp $consulta queryout $archivo -S $ServidorLocal -U $UsuarioLocal -P $ClaveLocal `
              -d $BaseLocal -n -q 2>&1 | Out-Null
    }
    else {
        & bcp $tabla out $archivo -S $ServidorLocal -U $UsuarioLocal -P $ClaveLocal `
              -d $BaseLocal -n 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $archivo)) {
        $fallos += "$tabla (salida)"
        Anotar ("    {0,-28} {1}" -f $tabla, 'FALLO al exportar')
        continue
    }

    $filasOrigen = (Invocar-Sqlcmd -Servidor $ServidorLocal -Usuario $UsuarioLocal -Clave $ClaveLocal `
                                   -Base $BaseLocal -Silencioso `
                                   -Consulta "SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM $tabla").Salida
    $filasOrigen = [int64](($filasOrigen -split "`n" | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1).Trim())

    # --- Entrada al destino ---------------------------------------------
    # -E conserva los valores de las columnas IDENTITY. Es imprescindible:
    # todas las claves subrogadas del modelo son IDENTITY y las claves
    # foraneas de los hechos apuntan a ellas. Sin -E, SQL Server generaria
    # numeros nuevos y el modelo estrella quedaria desarmado.
    & bcp $tabla in $archivo -S $Destino -U $ctx.SqlUsuario -P $ctx.SqlClave `
          -d 'TurismoDW' -n -E -b $TamanoLote -m 10 2>&1 | Out-Null
    $codigoIn = $LASTEXITCODE

    $reloj.Stop()
    $mb = if (Test-Path $archivo) { (Get-Item $archivo).Length / 1MB } else { 0 }

    $filasDestino = (Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                                    -Base 'TurismoDW' -Silencioso `
                                    -Consulta "SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM $tabla").Salida
    $filasDestino = [int64](($filasDestino -split "`n" | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1).Trim())

    $marca = if ($codigoIn -ne 0) { ' <- ERROR' }
             elseif ($Piloto)     { '' }
             elseif ($filasOrigen -ne $filasDestino) { ' <- DIFIERE' }
             else { '' }
    if ($marca -like '*ERROR*' -or $marca -like '*DIFIERE*') { $fallos += $tabla }

    Anotar ('    {0,-28} {1,12:N0} {2,12:N0} {3,10:N1} {4,9:N1}{5}' -f `
            $tabla, $filasOrigen, $filasDestino, $mb, $reloj.Elapsed.TotalSeconds, $marca)

    $totalFilas += $filasDestino
    $totalSeg   += $reloj.Elapsed.TotalSeconds
    Remove-Item $archivo -ErrorAction SilentlyContinue
}

Anotar ('    ' + ('-' * 74))
Anotar ('    {0,-28} {1,12} {2,12:N0} {3,10} {4,9:N1}' -f 'TOTAL', '', $totalFilas, '', $totalSeg)

# ===========================================================================
# FASE C. Indices y revalidacion
# ===========================================================================
Anotar ''
Anotar '--- C1. Indices y columnstore (despues de la carga) ---'
$rutaIdx = if ($modo -eq 'PRIMARY' -and (Test-Path (Join-Path $DirAdaptado '47c-indices-tuning.sql'))) {
    Join-Path $DirAdaptado '47c-indices-tuning.sql'
} else {
    $texto = Get-Content (Join-Path $Raiz '04-sqlserver\47c-indices-tuning.sql') -Raw
    if ($modo -ne 'FILEGROUPS') {
        $texto = [regex]::Replace($texto, '(?im)\s+ON\s+\[?FG_[A-Z0-9_]+\]?\s*(?=;|\r?\n)', '')
    }
    $tmp = Join-Path $DirAdaptado '47c-indices-tuning.sql'
    Set-Content -Path $tmp -Value $texto -Encoding utf8
    $tmp
}
$r = Medir-Paso '47c-indices-tuning.sql' {
    Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                   -Base 'TurismoDW' -Archivo $rutaIdx -Silencioso
}
if (-not $r.Ok) { Anotar "    AVISO: 47c fallo. $($r.Salida)" }

Anotar ''
Anotar '--- C2. Revalidacion de claves foraneas ---'
$sqlOn = ($TablasDatos | Where-Object { $_ -like 'dw.*' } |
          ForEach-Object { "ALTER TABLE $_ WITH CHECK CHECK CONSTRAINT ALL;" }) -join ' '
$r = Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                    -Base 'TurismoDW' -Consulta $sqlOn -Silencioso
if ($r.Ok) { Anotar '    Todas las claves foraneas quedaron validadas y confiables.' }
else       { Anotar "    AVISO: hay claves foraneas que no validan. $($r.Salida)"; $fallos += 'FK' }

$noConfiables = (Invocar-Sqlcmd -Servidor $Destino -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave `
                                -Base 'TurismoDW' -Silencioso `
                                -Consulta "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.foreign_keys WHERE is_not_trusted = 1 OR is_disabled = 1;").Salida
Anotar "    Claves foraneas no confiables o deshabilitadas: $(($noConfiables -split "`n" | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1).Trim())"

# ===========================================================================
# Cierre
# ===========================================================================
Anotar ''
Anotar '--- Resultado ---'
if ($fallos.Count -eq 0) {
    Anotar "    MIGRACION CORRECTA. $('{0:N0}' -f $totalFilas) filas en $('{0:N1}' -f $totalSeg) s."
} else {
    Anotar "    MIGRACION CON PROBLEMAS en: $($fallos -join ', ')"
}

$registro | Set-Content -Path $bitacora -Encoding utf8
Escribir ''
Escribir "Bitacora: $bitacora" 'OK'
Escribir 'Siguiente: 07-migracion\76-validacion-post-migracion.sql'
