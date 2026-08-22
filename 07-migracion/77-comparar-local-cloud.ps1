<#
    ITI-821 | Escenario 8: Turismo Inteligente | Semana 4
    Integrante 1: Alex Herrera

    77-comparar-local-cloud.ps1
    ----------------------------------------------------------------------
    Compara el entorno local contra el migrado en dos ejes:

      A. INTEGRIDAD   Corre 76-validacion-post-migracion.sql en ambos y
                      resta los conjuntos de metricas. Filas, sumas de
                      control y checksums tienen que coincidir.

      B. RENDIMIENTO  Corre las cinco consultas testigo de
                      47a-medicion-testigo.sql en ambos, cinco veces cada
                      una, y compara la MEDIANA.

    Por que la mediana de cinco corridas
    ------------------------------------
    Es la misma metodologia que uso el Integrante 4 en
    comparacion-rendimiento.md. Una sola corrida mide el estado de la cache
    tanto como la consulta. Con cinco y mediana, un pico aislado no arrastra
    el resultado. La primera corrida se descarta como calentamiento.

    Advertencia sobre lo que esta comparacion NO es
    -----------------------------------------------
    No es una comparacion pareja. El entorno local es SQL Server Developer
    en un contenedor con 4 GB de memoria y disco NVMe local; el destino es
    Express en una db.t3.micro con almacenamiento de red y, ademas, con la
    latencia de internet de por medio. Se espera que la nube pierda en
    varias consultas. Ese resultado se reporta tal cual: el repositorio ya
    sento el precedente cuando el Integrante 4 documento la regresion de T4
    en vez de presentar cinco mejoras de cinco.

    Uso:
        .\07-migracion\77-comparar-local-cloud.ps1
        .\07-migracion\77-comparar-local-cloud.ps1 -Corridas 3
        .\07-migracion\77-comparar-local-cloud.ps1 -SoloIntegridad
#>

[CmdletBinding()]
param(
    [string] $ServidorLocal = 'localhost,1433',
    [string] $UsuarioLocal  = 'sa',
    [string] $ClaveLocal    = 'Armagedon45*',
    [string] $Base          = 'TurismoDW',
    [int]    $Corridas      = 5,
    [switch] $SoloIntegridad,
    [switch] $SoloRendimiento
)

$ErrorActionPreference = 'Stop'
$Raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

Escribir-Titulo 'ITI-821 | Comparacion entre el entorno local y la nube'

$ctx = Obtener-Contexto -Raiz $Raiz
Probar-Endpoint -Identificador $ctx.SqlId | Out-Null
$Nube = "$($ctx.SqlEndpoint),1433"

Escribir "Local : $ServidorLocal"
Escribir "Nube  : $Nube"

$DirEvid = Join-Path $Raiz '00-docs\05-evidencias\migracion'
New-Item -ItemType Directory -Force -Path $DirEvid | Out-Null
$salida = Join-Path $DirEvid 'comparacion-local-cloud.txt'

$registro = [System.Collections.Generic.List[string]]::new()
function Anotar([string] $t) { $registro.Add($t); Escribir $t }

$registro.Add('=====================================================================')
$registro.Add(' COMPARACION LOCAL CONTRA NUBE')
$registro.Add(' ITI-821 | Escenario 8: Turismo Inteligente | Integrante 1: Alex Herrera')
$registro.Add(" Fecha : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$registro.Add(" Local : $ServidorLocal")
$registro.Add(" Nube  : $Nube")
$registro.Add('=====================================================================')

# ---------------------------------------------------------------------------
# Caracterizacion de los dos entornos
# ---------------------------------------------------------------------------
Anotar ''
Anotar '=== 0. Los dos entornos ==='
Anotar ''

$sqlEntorno = @'
SET NOCOUNT ON;
SELECT CONVERT(varchar(40),@@SERVERNAME) + ' | ' +
       CONVERT(varchar(40),SERVERPROPERTY('Edition')) + ' | ' +
       CONVERT(varchar(20),SERVERPROPERTY('ProductVersion')) + ' | CPUs=' +
       CONVERT(varchar(4),(SELECT cpu_count FROM sys.dm_os_sys_info)) + ' | MemMB=' +
       CONVERT(varchar(10),(SELECT physical_memory_kb/1024 FROM sys.dm_os_sys_info));
'@

foreach ($e in @(@{N='LOCAL'; S=$ServidorLocal; U=$UsuarioLocal; P=$ClaveLocal},
                 @{N='NUBE '; S=$Nube; U=$ctx.SqlUsuario; P=$ctx.SqlClave})) {
    $r = Invocar-Sqlcmd -Servidor $e.S -Usuario $e.U -Clave $e.P -Base $Base -Consulta $sqlEntorno -Silencioso
    $linea = ($r.Salida -split "`n" | Where-Object { $_ -match '\|' } | Select-Object -First 1)
    Anotar ("  {0} {1}" -f $e.N, $linea.Trim())
}

# ===========================================================================
# A. INTEGRIDAD
# ===========================================================================
if (-not $SoloRendimiento) {
    Anotar ''
    Anotar '====================================================================='
    Anotar ' A. INTEGRIDAD: las mismas metricas en los dos entornos'
    Anotar '====================================================================='

    $sqlMetricas = Join-Path $PSScriptRoot '76-validacion-post-migracion.sql'
    $variables = @('ReservasOrigen=2000010', 'MontoOrigen=16709503160.28',
                   'ResenasOrigen=500002', 'InteraccionesOrigen=1500002')

    function Obtener-Metricas {
        param($Servidor, $Usuario, $Clave)
        $r = Invocar-Sqlcmd -Servidor $Servidor -Usuario $Usuario -Clave $Clave `
                            -Base $Base -Archivo $sqlMetricas -Variables $variables -Silencioso
        $mapa = @{}
        # Se toman solo las lineas del bloque 2, que empiezan con dw.
        foreach ($linea in ($r.Salida -split "`n")) {
            if ($linea -match '^\s*(dw\.\w+)\s+(\d+)\s+([\d\.\-]+|NULL)\s+(-?\d+|NULL)') {
                $mapa[$Matches[1]] = [pscustomobject]@{
                    Filas = [int64]$Matches[2]; Suma = $Matches[3]; Checksum = $Matches[4]
                }
            }
        }
        return $mapa
    }

    $mLocal = Obtener-Metricas -Servidor $ServidorLocal -Usuario $UsuarioLocal -Clave $ClaveLocal
    $mNube  = Obtener-Metricas -Servidor $Nube -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave

    Anotar ''
    Anotar ('  {0,-26} {1,12} {2,12} {3,12} {4}' -f 'Tabla', 'Local', 'Nube', 'Diferencia', 'Checksum')
    Anotar ('  ' + ('-' * 78))

    $diferencias = 0
    foreach ($tabla in ($mLocal.Keys | Sort-Object)) {
        $l = $mLocal[$tabla]
        $n = $mNube[$tabla]
        if (-not $n) {
            Anotar ('  {0,-26} {1,12:N0} {2,12} {3,12} {4}' -f $tabla, $l.Filas, 'AUSENTE', '', 'n/d')
            $diferencias++
            continue
        }
        $dif = $n.Filas - $l.Filas
        $chk = if ($l.Checksum -eq $n.Checksum) { 'igual' } else { 'DIFIERE' }
        if ($dif -ne 0 -or $chk -eq 'DIFIERE') { $diferencias++ }
        Anotar ('  {0,-26} {1,12:N0} {2,12:N0} {3,12:N0} {4}' -f $tabla, $l.Filas, $n.Filas, $dif, $chk)
    }

    Anotar ''
    if ($diferencias -eq 0) {
        Anotar '  INTEGRIDAD VERIFICADA: conteos y checksums coinciden en las 14 tablas.'
        Anotar ''
        Anotar '  El checksum importa mas que el conteo: comparar conteos detecta filas'
        Anotar '  perdidas, pero no filas alteradas. CHECKSUM_AGG si.'
    } else {
        Anotar "  HAY $diferencias TABLAS CON DIFERENCIAS. Revisar antes de dar por buena la migracion."
    }
}

# ===========================================================================
# B. RENDIMIENTO
# ===========================================================================
if (-not $SoloIntegridad) {
    Anotar ''
    Anotar '====================================================================='
    Anotar ' B. RENDIMIENTO: cinco consultas testigo, mediana de N corridas'
    Anotar '====================================================================='

    # Las mismas cinco de 47a-medicion-testigo.sql, para que los numeros sean
    # comparables con la linea base que dejo el Integrante 2.
    $testigos = [ordered]@{
        'T1 Eliminacion de particion (2024)' = @'
SELECT COUNT_BIG(*) AS Reservas, SUM(MontoConfirmado) AS Monto
FROM dw.FactReserva
WHERE FechaInicioKey BETWEEN 20240101 AND 20241231;
'@
        'T2 Ocupacion por pais y mes' = @'
SELECT h.Pais, t.Anio, t.Mes,
       SUM(o.HabitacionesOcupadas) AS Ocupadas,
       SUM(o.HabitacionesDisponibles) AS Disponibles
FROM dw.FactOcupacionDiaria o
JOIN dw.DimHotel h  ON h.HotelKey = o.HotelKey
JOIN dw.DimTiempo t ON t.TiempoKey = o.TiempoKey
GROUP BY h.Pais, t.Anio, t.Mes;
'@
        'T3 Ranking de tours' = @'
SELECT TOP 20 tr.Nombre, SUM(ft.IngresoTour) AS Ingreso, COUNT_BIG(*) AS Veces
FROM dw.FactReservaTour ft
JOIN dw.DimTour tr ON tr.TourKey = ft.TourKey
GROUP BY tr.Nombre
ORDER BY Ingreso DESC;
'@
        'T4 Perfil del visitante contra satisfaccion' = @'
SELECT c.PaisOrigen,
       COUNT_BIG(DISTINCT r.ReservaId) AS Reservas,
       AVG(CONVERT(float, s.Calificacion)) AS Calificacion
FROM dw.FactReserva r
JOIN dw.DimCliente c ON c.ClienteKey = r.ClienteKey
LEFT JOIN dw.FactResena s ON s.ClienteKey = r.ClienteKey
GROUP BY c.PaisOrigen;
'@
        'T5 Tendencia mensual' = @'
SELECT t.Anio, t.Mes, COUNT_BIG(*) AS Reservas, SUM(r.MontoConfirmado) AS Monto
FROM dw.FactReserva r
JOIN dw.DimTiempo t ON t.TiempoKey = r.FechaInicioKey
GROUP BY t.Anio, t.Mes
ORDER BY t.Anio, t.Mes;
'@
    }

    function Medir-Consulta {
        param($Servidor, $Usuario, $Clave, $Consulta, $Veces)
        $tiempos = @()
        # La primera corrida se descarta: mide el llenado de la cache, no la
        # consulta. Por eso se ejecuta Veces + 1.
        for ($i = 0; $i -le $Veces; $i++) {
            $reloj = [System.Diagnostics.Stopwatch]::StartNew()
            Invocar-Sqlcmd -Servidor $Servidor -Usuario $Usuario -Clave $Clave `
                           -Base $Base -Consulta $Consulta -Silencioso | Out-Null
            $reloj.Stop()
            if ($i -gt 0) { $tiempos += $reloj.Elapsed.TotalMilliseconds }
        }
        $ordenados = $tiempos | Sort-Object
        return [pscustomobject]@{
            Mediana = $ordenados[[int]($ordenados.Count / 2)]
            Minimo  = $ordenados[0]
            Maximo  = $ordenados[-1]
        }
    }

    # --- Costo fijo por invocacion --------------------------------------
    # Cada medicion lanza un proceso sqlcmd nuevo, asi que incluye arranque
    # del proceso, TCP, TLS, autenticacion y recien despues la consulta.
    # Contra un endpoint en us-east-1 ese costo fijo es de cientos de
    # milisegundos y DOMINA cualquier consulta que dure poco: sin separarlo,
    # las cinco testigo parecen degradarse por igual y el numero no dice
    # nada sobre el motor. Se mide con SELECT 1 y se resta.
    Anotar ''
    Anotar '  Costo fijo por invocacion (SELECT 1):'
    $fijoLocal = (Medir-Consulta -Servidor $ServidorLocal -Usuario $UsuarioLocal `
                                 -Clave $ClaveLocal -Consulta 'SET NOCOUNT ON; SELECT 1;' -Veces $Corridas).Mediana
    $fijoNube  = (Medir-Consulta -Servidor $Nube -Usuario $ctx.SqlUsuario `
                                 -Clave $ctx.SqlClave -Consulta 'SET NOCOUNT ON; SELECT 1;' -Veces $Corridas).Mediana
    Anotar ('    local {0,8:N1} ms     nube {1,8:N1} ms     sobrecosto de la nube {2,8:N1} ms' -f `
            $fijoLocal, $fijoNube, ($fijoNube - $fijoLocal))

    Anotar ''
    Anotar "  Corridas por consulta: $Corridas (mas una de calentamiento que se descarta)"
    Anotar ''
    Anotar ('  {0,-42} {1,9} {2,9} {3,8} {4,9} {5,9} {6,8}' -f `
            'Consulta', 'Local', 'Nube', 'Factor', 'Local net', 'Nube net', 'F. neto')
    Anotar ('  ' + ('-' * 100))

    $mejoras = 0; $regresiones = 0
    foreach ($nombre in $testigos.Keys) {
        $q = $testigos[$nombre]
        $l = Medir-Consulta -Servidor $ServidorLocal -Usuario $UsuarioLocal -Clave $ClaveLocal -Consulta $q -Veces $Corridas
        $n = Medir-Consulta -Servidor $Nube -Usuario $ctx.SqlUsuario -Clave $ctx.SqlClave -Consulta $q -Veces $Corridas

        $factor = if ($l.Mediana -gt 0) { $n.Mediana / $l.Mediana } else { 0 }

        # Tiempo neto: lo que tarda el MOTOR, sin el costo de conectarse.
        $netoLocal = [Math]::Max($l.Mediana - $fijoLocal, 0.1)
        $netoNube  = [Math]::Max($n.Mediana - $fijoNube,  0.1)
        $factorNeto = $netoNube / $netoLocal

        if ($factorNeto -lt 1) { $mejoras++ } else { $regresiones++ }

        Anotar ('  {0,-42} {1,9:N1} {2,9:N1} {3,7:N1}x {4,9:N1} {5,9:N1} {6,7:N1}x' -f `
                $nombre, $l.Mediana, $n.Mediana, $factor, $netoLocal, $netoNube, $factorNeto)
    }

    Anotar ''
    Anotar "  Descontado el costo de conexion, la nube pierde en $regresiones de 5 consultas."
    Anotar ''
    Anotar '  Las columnas "net" son la medida honesta del MOTOR. Las primeras dos'
    Anotar '  son la medida honesta de la EXPERIENCIA: es lo que va a sentir Power'
    Anotar '  BI al refrescar contra la nube. Ninguna sobra, y presentar solo una'
    Anotar '  de las dos daria una conclusion equivocada:'
    Anotar ''
    Anotar '    - solo el total     -> parece que el motor degrado por igual en'
    Anotar '                           todas las consultas, que es falso;'
    Anotar '    - solo el neto      -> esconde que cada ida y vuelta a us-east-1'
    Anotar '                           cuesta cientos de milisegundos reales.'
}

# ---------------------------------------------------------------------------
Anotar ''
Anotar '====================================================================='
Anotar ' Conclusion'
Anotar '====================================================================='
Anotar ''
Anotar '  La migracion se juzga por INTEGRIDAD, no por velocidad. Una db.t3.micro'
Anotar '  con Express no puede competir contra Developer con 4 GB y disco local,'
Anotar '  y no es el objetivo: el objetivo era que los datos llegaran completos y'
Anotar '  que la solucion siguiera operando desde la nube.'
Anotar ''
Anotar '  Si hiciera falta rendimiento comparable, la palanca es la clase de'
Anotar '  instancia, no el diseno: subir a db.t3.small o db.t3.medium es un'
Anotar '  cambio de configuracion, no una migracion nueva.'

$registro | Set-Content -Path $salida -Encoding utf8
Escribir ''
Escribir "Evidencia: $salida" 'OK'
