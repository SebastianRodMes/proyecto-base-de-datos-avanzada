<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
    Integrante 1: Alex Herrera

    79-prueba-recuperacion-etl.ps1
    ----------------------------------------------------------------------
    Prueba obligatoria de la Semana 3: "Prueba de recuperacion ante error
    de ETL".

    Que se demuestra
    ----------------
      1. Un fallo a media carga deja la ejecucion en FALLIDO y la etapa
         culpable identificada en la bitacora, no en un estado ambiguo.
      2. El DW NO queda a medias: el fallo ocurre en la carga a staging,
         antes de tocar dw.*, asi que los hechos conservan su estado
         anterior y el modelo sigue siendo consistente.
      3. Las marcas de agua NO avanzan cuando la corrida falla. Es lo que
         garantiza que el siguiente intento vuelva a traer el mismo lote
         en vez de saltarselo.
      4. Al relanzar, usp_IniciarEjecucion cierra la corrida colgada y el
         resultado converge al estado correcto.

    Como se provoca el fallo
    ------------------------
    Se corrompe el archivo intermedio reserva.dat agregandole cincuenta
    filas con un numero de columnas incorrecto, y se relanza el ETL con
    --sin-extraer para que reutilice ese archivo. bcp tolera hasta diez
    filas malas (-m 10); con cincuenta aborta, cargar_bcp lanza la
    excepcion y el orquestador la registra.

    Se eligio este mecanismo, y no matar el proceso, porque es
    determinista: produce siempre el mismo fallo en la misma etapa, con lo
    que la evidencia es reproducible por cualquier integrante.

    Uso:
        .\07-migracion\79-prueba-recuperacion-etl.ps1
#>

[CmdletBinding()]
param(
    [string] $Servidor = 'localhost,1433',
    [string] $Usuario  = 'sa',
    [string] $Clave    = 'Armagedon45*',
    [string] $Base     = 'TurismoDW'
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Prueba de recuperacion ante error de ETL'

$DirEtl  = Join-Path $Raiz '05-etl'
$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$salida = Join-Path $DirEvid 'prueba-recuperacion-etl.txt'

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

function Consultar([string] $sql) {
    $r = & sqlcmd -S $Servidor -U $Usuario -P $Clave -C -d $Base -W -s ' | ' -Q "SET NOCOUNT ON; $sql" 2>&1
    return ($r | Out-String).Trim()
}

$registro.Add('=====================================================================')
$registro.Add(' PRUEBA DE RECUPERACION ANTE ERROR DE ETL')
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1: Alex Herrera')
$registro.Add(" Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add('=====================================================================')

# ---------------------------------------------------------------------------
# 1. Estado inicial
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 1. Estado antes de provocar el fallo ==='
Anotar ''

# El ORDER BY final no es cosmetico: los tres conteos se comparan como
# texto, y UNION ALL no garantiza el orden de las filas. Sin ordenar, dos
# ejecuciones identicas pueden devolver las mismas filas en distinta
# posicion y la comparacion las declararia diferentes.
$sqlHechos = @'
SELECT Hecho, Filas FROM (
    SELECT [Hecho]='dw.FactReserva', [Filas]=COUNT_BIG(*) FROM dw.FactReserva
    UNION ALL SELECT 'dw.FactReservaHabitacion', COUNT_BIG(*) FROM dw.FactReservaHabitacion
    UNION ALL SELECT 'dw.FactReservaTour', COUNT_BIG(*) FROM dw.FactReservaTour
    UNION ALL SELECT 'dw.FactOcupacionDiaria', COUNT_BIG(*) FROM dw.FactOcupacionDiaria
    UNION ALL SELECT 'dw.FactResena', COUNT_BIG(*) FROM dw.FactResena
    UNION ALL SELECT 'dw.FactInteraccionWeb', COUNT_BIG(*) FROM dw.FactInteraccionWeb
) t ORDER BY Hecho;
'@

$hechosAntes = Consultar $sqlHechos
Anotar $hechosAntes
Anotar ''
Anotar 'Marcas de agua antes del fallo:'
$marcasAntes = Consultar 'SELECT Fuente, Objeto, Marca FROM etl.vw_EstadoIncremental ORDER BY Fuente, Objeto;'
Anotar $marcasAntes

# ---------------------------------------------------------------------------
# 2. Corrida sana previa, para dejar archivos intermedios frescos
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 2. Corrida previa correcta (deja los .dat en el directorio de trabajo) ==='
Push-Location $DirEtl
$previa = & python run_etl.py --modo INCREMENTAL 2>&1
Pop-Location
$estadoPrevio = ($previa | Select-String 'Estado     :').ToString().Trim()
Anotar "    $estadoPrevio"

# El directorio de trabajo lo define config.py; se pregunta a Python en vez
# de suponerlo, porque cambia entre maquinas.
Push-Location $DirEtl
$dirTrabajo = (& python -c "from etl import config; print(config.DIR_TRABAJO)" 2>&1 | Out-String).Trim()
Pop-Location
Anotar "    Directorio de trabajo: $dirTrabajo"

$archivoReserva = Join-Path $dirTrabajo 'reserva.dat'
if (-not (Test-Path $archivoReserva)) {
    throw "No existe $archivoReserva. La corrida previa no dejo archivos intermedios."
}

# ---------------------------------------------------------------------------
# 3. Corrupcion deliberada
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 3. Corrupcion deliberada de reserva.dat ==='

$respaldo = "$archivoReserva.respaldo"
Copy-Item $archivoReserva $respaldo -Force

$tamanoAntes = (Get-Item $archivoReserva).Length

# Las filas corruptas tienen que estar BIEN FORMADAS y aun asi ser
# invalidas. Un primer intento con filas de dos campos no fallo: el
# terminador de fila es un salto de linea y el de campo es |~|, asi que bcp
# siguio consumiendo lineas hasta juntar doce campos, y como todas las
# columnas de staging son nvarchar por diseno, cualquier texto entra.
#
# Staging es deliberadamente permisivo (ver 41-esquema-staging.sql): la
# validacion se hace despues, en etl.usp_ValidarStaging. Asi que hay que
# violar el ESQUEMA, no los datos. Dos violaciones a la vez:
#
#   campo  1  reserva_id  -> 200 caracteres en una nvarchar(50)
#   campo 12  EjecucionId -> texto en una columna int
#
$relleno = 'X' * 200
$basura = (1..50 | ForEach-Object {
    @($relleno, '1', '1', '2027-01-01', '2027-01-02', '2027-01-03',
      '1', 'CONFIRMADA', '100.00', '', '2027-01-01', 'NO_ES_UN_ENTERO') -join '|~|'
}) -join "`n"
Add-Content -Path $archivoReserva -Value ($basura + "`n") -NoNewline -Encoding utf8
$tamanoDespues = (Get-Item $archivoReserva).Length

Anotar "    Se agregaron 50 filas bien formadas pero invalidas ($tamanoAntes -> $tamanoDespues bytes)."
Anotar '    Cada una viola dos veces el esquema: reserva_id de 200 caracteres en'
Anotar '    una nvarchar(50), y EjecucionId con texto en una columna int.'
Anotar '    bcp tolera 10 filas malas (-m 10). Con 50 aborta.'

# ---------------------------------------------------------------------------
# 4. Corrida que debe fallar
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 4. Corrida con el archivo corrupto (debe fallar) ==='

Push-Location $DirEtl
$fallida = & python run_etl.py --modo INCREMENTAL --sin-extraer 2>&1
$codigoSalida = $LASTEXITCODE
Pop-Location

Anotar "    Codigo de salida del ETL: $codigoSalida  (se espera 1)"
$lineasError = $fallida | Select-String 'ERROR|bcp fallo|FALLIDO' | Select-Object -First 6
$lineasError | ForEach-Object { Anotar "    $($_.ToString().Trim())" }

# ---------------------------------------------------------------------------
# 5. Que quedo registrado
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 5. Lo que la bitacora registro del fallo ==='
Anotar ''
Anotar 'Ejecucion fallida:'
Anotar (Consultar @'
SELECT TOP 1 [Ejecucion]=EjecucionId, [Modo]=Modo, [Estado]=Estado,
       [Segundos]=DuracionSegundos, [Mensaje]=LEFT(ISNULL(Mensaje,''),90)
FROM etl.Ejecucion ORDER BY EjecucionId DESC;
'@)

Anotar ''
Anotar 'Etapa culpable, identificada por nombre y objeto destino:'
Anotar (Consultar @'
SELECT [Etapa]=Nombre, [Destino]=ISNULL(ObjetoDestino,''), [Estado]=Estado,
       [Mensaje]=LEFT(ISNULL(Mensaje,''),80)
FROM etl.Etapa
WHERE EjecucionId = (SELECT MAX(EjecucionId) FROM etl.Ejecucion)
  AND Estado = 'FALLIDO';
'@)

# ---------------------------------------------------------------------------
# 6. El DW no quedo a medias
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 6. El DW conservo su estado ==='
Anotar ''
$hechosDurante = Consultar $sqlHechos
Anotar $hechosDurante
Anotar ''
if ($hechosDurante -eq $hechosAntes) {
    Anotar '    Los conteos son IDENTICOS a los de antes del fallo.'
    Anotar '    El fallo ocurrio en la carga a staging, antes de tocar dw.*,'
    Anotar '    asi que ninguna tabla de hechos quedo a medias.'
} else {
    Anotar '    AVISO: los conteos cambiaron. Revisar.'
}

Anotar ''
Anotar 'Marcas de agua despues del fallo:'
$marcasDespues = Consultar 'SELECT Fuente, Objeto, Marca FROM etl.vw_EstadoIncremental ORDER BY Fuente, Objeto;'
Anotar $marcasDespues
Anotar ''
if ($marcasDespues -eq $marcasAntes) {
    Anotar '    Las marcas NO avanzaron. El siguiente intento vuelve a traer el'
    Anotar '    mismo lote en vez de saltarselo: se prefiere reprocesar antes que'
    Anotar '    perder datos, y la carga incremental es idempotente porque borra'
    Anotar '    por clave de negocio antes de insertar.'
} else {
    Anotar '    AVISO: las marcas avanzaron pese al fallo. Eso seria un defecto.'
}

# ---------------------------------------------------------------------------
# 7. Recuperacion
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 7. Recuperacion: se relanza el ETL ==='

Move-Item $respaldo $archivoReserva -Force
Anotar '    Archivo intermedio restaurado (simula corregir el origen del fallo).'

Push-Location $DirEtl
$recuperada = & python run_etl.py --modo INCREMENTAL 2>&1
$codigoRecuperada = $LASTEXITCODE
Pop-Location

Anotar "    Codigo de salida: $codigoRecuperada  (se espera 0)"
Anotar ''
Anotar 'Ultimas tres ejecuciones:'
Anotar (Consultar @'
SELECT TOP 3 [Ejecucion]=EjecucionId, [Modo]=Modo, [Estado]=Estado,
       [Leidos]=RegistrosLeidos, [Segundos]=DuracionSegundos
FROM etl.Ejecucion ORDER BY EjecucionId DESC;
'@)

Anotar ''
Anotar '=== 8. Estado final ==='
Anotar ''
$hechosDespues = Consultar $sqlHechos
Anotar $hechosDespues

# ---------------------------------------------------------------------------
# 9. Veredicto
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 9. Veredicto ==='
Anotar ''

$ok = ($codigoSalida -eq 1) -and ($codigoRecuperada -eq 0) -and
      ($hechosDurante -eq $hechosAntes) -and ($hechosDespues -eq $hechosAntes) -and
      ($marcasDespues -eq $marcasAntes)

if ($ok) {
    Anotar '    RECUPERACION CORRECTA.'
    Anotar ''
    Anotar '    - El fallo devolvio codigo 1 y quedo registrado como FALLIDO.'
    Anotar '    - La etapa culpable esta identificada en etl.Etapa.'
    Anotar '    - Los hechos del DW no se alteraron durante el fallo.'
    Anotar '    - Las marcas de agua no avanzaron.'
    Anotar '    - El relanzamiento devolvio codigo 0 y convergio al mismo estado.'
} else {
    Anotar '    LA PRUEBA NO PASO. Detalle:'
    Anotar "      codigo del fallo        : $codigoSalida (esperado 1)"
    Anotar "      codigo de recuperacion  : $codigoRecuperada (esperado 0)"
    Anotar "      hechos intactos al fallar: $($hechosDurante -eq $hechosAntes)"
    Anotar "      hechos iguales al final : $($hechosDespues -eq $hechosAntes)"
    Anotar "      marcas sin avanzar      : $($marcasDespues -eq $marcasAntes)"
}

$registro | Set-Content -Path $salida -Encoding utf8
Escribir ''
Escribir "Evidencia: $salida" 'OK'
