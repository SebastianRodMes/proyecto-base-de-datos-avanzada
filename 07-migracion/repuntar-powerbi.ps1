<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    repuntar-powerbi.ps1
    ----------------------------------------------------------------------
    Cambia el servidor al que apunta el modelo semantico de Power BI, para
    que el reporte consuma el DW migrado a la nube en vez del local.

    El problema: no hay parametro compartido
    ----------------------------------------
    El generador 06-powerbi/60-generar-pbip.py interpola el servidor una
    sola vez (linea 56, variable SERVIDOR_POWERBI), pero lo escribe en las
    DIECISEIS particiones del modelo. En el proyecto ya generado no queda
    ninguna indireccion: cada archivo tables/*.tmdl lleva la cadena literal

        Origen = Sql.Database("localhost,14330", "TurismoDW"),

    No existe un expressions.tmdl con un parametro, ni un bloque dataSource
    compartido.

    Por que no se regenera con 60-generar-pbip.py
    ---------------------------------------------
    Seria lo natural, pero rompe cosas:

      1. El generador hace shutil.rmtree de TurismoDW.Report/ (lineas
         661-663) y emite un reporte VACIO a proposito (lineas 724-738). El
         reporte versionado tiene 6 paginas y 55 visuales.
      2. Los artefactos versionados ya divergieron del generador. El commit
         0ee64a4 los ajusto para que Power BI Desktop los abriera:
         compatibilityLevel 1606 en vez de 1567, la anotacion PBI_ProTooling,
         y un lineageTag por tabla y por columna que el generador no produce.
         Regenerar revertiria todo eso.

    Asi que se editan las 16 lineas directamente, que es una operacion
    acotada y reversible con git checkout.

    Uso:
        .\07-migracion\repuntar-powerbi.ps1              # -> a la nube
        .\07-migracion\repuntar-powerbi.ps1 -Local       # -> localhost,14330
        .\07-migracion\repuntar-powerbi.ps1 -Servidor "host,1433"
        .\07-migracion\repuntar-powerbi.ps1 -Verificar   # solo informa
#>

[CmdletBinding()]
param(
    [string] $Servidor = '',
    [string] $Base     = 'TurismoDW',
    [switch] $Local,
    [switch] $Verificar
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Repunte del modelo de Power BI'

$DirTablas = Join-Path $Raiz '06-powerbi\TurismoDW.SemanticModel\definition\tables'
if (-not (Test-Path $DirTablas)) { throw "No existe $DirTablas" }

# El patron reconoce cualquier servidor y cualquier base, para que el script
# sirva igual para ir a la nube, volver a local o cambiar de instancia.
$patron = 'Sql\.Database\("([^"]*)",\s*"([^"]*)"\)'

# ---------------------------------------------------------------------------
# Modo verificacion
# ---------------------------------------------------------------------------
if ($Verificar) {
    $encontrados = @{}
    Get-ChildItem $DirTablas -Filter '*.tmdl' | ForEach-Object {
        $texto = Get-Content $_.FullName -Raw
        foreach ($m in [regex]::Matches($texto, $patron)) {
            $clave = "$($m.Groups[1].Value) / $($m.Groups[2].Value)"
            if (-not $encontrados.ContainsKey($clave)) { $encontrados[$clave] = @() }
            $encontrados[$clave] += $_.Name
        }
    }
    Escribir ''
    if ($encontrados.Count -eq 0) {
        Escribir 'Ninguna particion declara un origen Sql.Database.' 'AVISO'
    }
    foreach ($k in $encontrados.Keys) {
        Escribir ("{0,-52} {1,2} tablas" -f $k, $encontrados[$k].Count) 'OK'
    }
    if ($encontrados.Count -gt 1) {
        Escribir ''
        Escribir 'El modelo apunta a MAS DE UN servidor. Deberia ser uno solo.' 'AVISO'
    }
    return
}

# ---------------------------------------------------------------------------
# Resolucion del destino
# ---------------------------------------------------------------------------
if ($Local) {
    $Servidor = 'localhost,14330'
    Escribir 'Destino: laboratorio local (endpoint de alta disponibilidad)'
}
elseif (-not $Servidor) {
    $ctx = Obtener-Contexto -Raiz $Raiz
    if (-not $ctx.SqlEndpoint -or $ctx.SqlEndpoint -eq 'None') {
        throw "No se pudo resolver el endpoint de $($ctx.SqlId). Verifique que la instancia exista."
    }
    $Servidor = "$($ctx.SqlEndpoint),1433"
    Escribir "Destino: Amazon RDS ($($ctx.SqlId))"
}
Escribir "Servidor : $Servidor"
Escribir "Base     : $Base"

# ---------------------------------------------------------------------------
# Reescritura
# ---------------------------------------------------------------------------
$cambiados = 0
$sinCambio = 0
$archivos  = Get-ChildItem $DirTablas -Filter '*.tmdl' | Sort-Object Name

Escribir ''
foreach ($archivo in $archivos) {
    $texto = Get-Content $archivo.FullName -Raw

    if ($texto -notmatch $patron) {
        # _Medidas.tmdl no tiene origen SQL: su particion es una tabla
        # literal de un solo valor. Que no aparezca aqui es lo correcto.
        $sinCambio++
        continue
    }

    $nuevo = [regex]::Replace($texto, $patron, ('Sql.Database("{0}", "{1}")' -f $Servidor, $Base))

    if ($nuevo -eq $texto) {
        Escribir ("  {0,-30} ya apuntaba al destino" -f $archivo.Name)
        $sinCambio++
        continue
    }

    # -NoNewline conserva el final de archivo original: agregar una linea
    # extra ensuciaria el diff de las 16 tablas sin necesidad.
    Set-Content -Path $archivo.FullName -Value $nuevo -Encoding utf8 -NoNewline
    Escribir ("  {0,-30} repuntada" -f $archivo.Name) 'OK'
    $cambiados++
}

Escribir ''
Escribir "Tablas repuntadas : $cambiados"
Escribir "Sin cambios       : $sinCambio  (incluye _Medidas.tmdl, que no tiene origen SQL)"

# ---------------------------------------------------------------------------
# Coherencia con el generador
# ---------------------------------------------------------------------------
# Si alguien vuelve a correr 60-generar-pbip.py, debe producir el mismo
# servidor que se acaba de escribir a mano. El generador lo lee de la
# variable de entorno POWERBI_SQL_SERVIDOR, asi que se deja anotado en el
# .env que corresponda en vez de dejar los dos desincronizados.
$archivoEnv = if ($Local) { Join-Path $Raiz '05-etl\.env' } else { Join-Path $Raiz '05-etl\.env.aws' }
if (Test-Path $archivoEnv) {
    $lineas = Get-Content $archivoEnv
    if ($lineas -match '^POWERBI_SQL_SERVIDOR=') {
        $lineas = $lineas -replace '^POWERBI_SQL_SERVIDOR=.*', "POWERBI_SQL_SERVIDOR=$Servidor"
    } else {
        $lineas += "POWERBI_SQL_SERVIDOR=$Servidor"
    }
    Set-Content -Path $archivoEnv -Value $lineas -Encoding utf8
    Escribir "POWERBI_SQL_SERVIDOR actualizado en $(Split-Path $archivoEnv -Leaf)" 'OK'
} else {
    Escribir "No existe $(Split-Path $archivoEnv -Leaf); recuerde fijar POWERBI_SQL_SERVIDOR=$Servidor" 'AVISO'
}

Escribir ''
Escribir 'Para revertir:  git checkout -- 06-powerbi/' 'AVISO'
Escribir ''
Escribir 'Siguiente: abrir el proyecto y refrescar.' 'OK'
Escribir '  Start-Process .\06-powerbi\TurismoDW.pbip'
Escribir '  Autenticacion: Base de datos | usuario y clave de RDS | confiar en el certificado.'
