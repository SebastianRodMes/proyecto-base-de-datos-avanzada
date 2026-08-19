# Guía del reporte de Power BI y su conexión al modelo de alta disponibilidad

**ITI-821 · Escenario 8: Turismo Inteligente · Semana 3 · Integrante 1: Alex Herrera**

Requerimiento que cubre este documento:

> *«Crear un dashboard en PBI que muestre la información concentrada en el modelo analítico en SQL Server con capacidad de conexión al modelo de alta disponibilidad.»*

---

## 1. La parte que casi siempre se hace mal: la cadena de conexión

Lo natural es conectar Power BI a `localhost` o a `BOSGAME-WINTP`. Y funciona… hasta que el Integrante 3 provoca el failover. En ese momento el nodo principal deja de responder, el `.pbix` apunta a un servidor caído, y hay que abrir el archivo, entrar a *Configuración de origen de datos*, cambiar el nombre del servidor y volver a publicar. Eso no es alta disponibilidad: es intervención manual disfrazada.

**La solución es un alias de cliente SQL.** El reporte se conecta a un nombre lógico —`TURISMODW`— que el cliente de SQL Server resuelve al nodo real. Tras el failover se repunta el alias y **el `.pbix` no se toca**.

```
   Power BI  ──►  TURISMODW  ──►  ┌─ nodo principal  (normal)
   (.pbix)         (alias)         └─ nodo espejo     (tras el failover)
                       ▲
                       │
              se repunta aquí, no en el reporte
```

El alias vive en el registro de Windows y lo crea `99-setup/00-setup-admin.ps1`:

```
HKLM\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo
    TURISMODW = DBMSSOCN,localhost,1433

HKLM\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo
    TURISMODW = DBMSSOCN,localhost,1433
```

> Se registra en las dos ramas —64 y 32 bits— porque Power BI Desktop y algunos componentes del motor Mashup cargan el proveedor de 32 bits. Si sólo se registra una, el reporte funciona en una máquina y falla en otra sin explicación aparente.

`DBMSSOCN` significa «usar TCP/IP». De ahí que el script tenga que habilitar TCP y fijar el puerto 1433: por defecto las instancias de SQL Server 2022 vienen con TCP deshabilitado y puertos dinámicos.

---

## 2. Por qué Import y no DirectQuery

| | Import (elegido) | DirectQuery |
|---|---|---|
| Durante la caída del nodo | El dashboard **sigue visible** con los últimos datos cargados | Todos los visuales muestran error |
| Rendimiento con 2 M de filas | Instantáneo (VertiPaq en memoria) | Cada visual dispara SQL contra el DW |
| Carga sobre el nodo principal | Sólo durante el refresco | Constante, compite con el ETL |
| Evidencia del failover | El refresco posterior confirma la reconexión | Inmediata pero a costa de todo lo demás |

El escenario dice explícitamente que *«las consultas históricas afectan las operaciones»*. DirectQuery reintroduce ese problema en el DW. Import lo elimina: el modelo se lee una vez por refresco y el resto del tiempo el dashboard no toca la base.

Con Import, la evidencia del failover es igual de contundente: se provoca la caída, se repunta el alias, se refresca, y la página *Estado del sistema* muestra el **nuevo nombre de nodo** con los mismos totales que antes. Eso demuestra continuidad de servicio y consistencia de datos a la vez.

---

## 3. Abrir el proyecto

El entregable es un proyecto **PBIP** (`06-powerbi/TurismoDW.pbip`), no un `.pbix`. Un `.pbix` es binario: no se puede generar por script ni revisar en un diff. PBIP guarda el modelo semántico como archivos `.tmdl` de texto, con las 17 tablas, 26 relaciones y 52 medidas DAX ya definidas.

### Paso previo obligatorio

En Power BI Desktop: **Archivo → Opciones y configuración → Opciones → Características de vista previa**, y activar:

- [x] Guardar archivos de proyecto de Power BI (.pbip)
- [x] Almacenar el modelo semántico con formato TMDL
- [x] Almacenar el reporte con formato PBIR mejorado  ← **imprescindible para el lienzo generado**

Reiniciar Power BI Desktop.

### Abrir y refrescar

1. **Archivo → Abrir → Examinar** → `06-powerbi/TurismoDW.pbip`
2. **Inicio → Actualizar**. La primera carga trae ~8.4 millones de filas; tarda algunos minutos.
3. Si pide credenciales: **Windows → Usar mis credenciales actuales**.

### Si el proyecto PBIP no abre

El formato PBIP cambia entre versiones de Power BI Desktop. Si la versión instalada lo rechaza, se arma el modelo a mano y no se pierde nada: las consultas M están en cada `*.tmdl` (bloque `partition`) y las 52 medidas DAX en `06-powerbi/medidas-dax.md`, listas para pegar.

**Ruta manual:** Obtener datos → Base de datos SQL Server → Servidor `TURISMODW`, Base de datos `TurismoDW`, modo **Importar** → seleccionar las 16 vistas `dw.vw_*` → Cargar → crear las relaciones de la sección 4 → pegar las medidas.

---

## 4. Modelo semántico

Estrella pura: dimensiones alrededor, hechos al centro, todas las relaciones **muchos-a-uno con filtro en un solo sentido**. Sin relaciones bidireccionales, que son la causa habitual de totales inflados y de ambigüedad en modelos con varios hechos.

```
                     DimTiempo ★ (tabla de fechas)
                          │
        ┌─────────────┬───┴────┬──────────────┬─────────────┐
        │             │        │              │             │
  FactReserva  FactReservaHab  FactReservaTour  FactResena  FactInteraccionWeb
        │             │   │        │      │       │  │            │
   DimCliente    DimHotel │   DimTour     │  DimPaquete           DimCanal
   DimPaquete         DimTipoHabitacion   │
   DimEstadoReserva                       │
                                   FactOcupacionDiaria
                                   (DimTiempo + DimHotel)
```

### Puntos que hay que verificar tras abrir

1. **`DimTiempo` marcada como tabla de fechas.** Botón derecho sobre la tabla → *Marcar como tabla de fechas* → columna `Fecha`. El TMDL ya lo declara (`dataCategory: Time`), pero conviene confirmarlo: sin esa marca, `SAMEPERIODLASTYEAR` y `TOTALYTD` devuelven números erróneos **sin dar error**.

2. **Relaciones de fecha inactivas.** `FactReserva` tiene tres relaciones con `DimTiempo`: activa por `FechaInicioKey` (la fecha de la estadía, que es por la que se analiza), e inactivas por `FechaReservaKey` y `FechaFinKey`. Es *role-playing*: para analizar por fecha de compra en lugar de fecha de viaje, se usa `USERELATIONSHIP` dentro de un `CALCULATE`.

3. **Relaciones inactivas en `FactResena`.** Una reseña apunta a un hotel, a un tour o a un paquete, nunca a los tres. Las tres relaciones existen pero sólo se activa la que corresponda al análisis, filtrando además por `TipoEntidad`.

---

## 5. Las seis páginas del reporte

**El lienzo viene generado**: 6 páginas y 56 visuales en formato PBIR, producidos por `06-powerbi/61-generar-reporte.py`. Cada visual es un archivo JSON de texto, así que el reporte se versiona y se revisa igual que el resto del proyecto.

Se verificó que los 68 archivos son JSON válido y que las 92 referencias de campo resuelven contra el modelo semántico. **No** se pudo abrir el lienzo en Power BI Desktop desde el entorno donde se generó, y el formato PBIR cambia entre versiones: si la tuya lo rechaza, el modelo semántico sigue siendo válido y esta especificación es la guía para armar las páginas a mano.

### Página 1 — Resumen ejecutivo

| Elemento | Visual | Campos |
|---|---|---|
| Fila de tarjetas | Tarjeta ×6 | `Reservas`, `Ingresos confirmados`, `% Ocupación hotelera`, `Promedio de estadía (noches)`, `Índice de satisfacción`, `Ticket promedio` |
| Tendencia | Gráfico de líneas | Eje `DimTiempo[AnioMesEtiqueta]`, valores `Ingresos confirmados` y `Ingresos año anterior` |
| Mix | Anillo | Leyenda `DimEstadoReserva[Estado]`, valor `Reservas` |
| Top países | Barras horizontales | Eje `DimCliente[PaisOrigen]`, valor `Reservas` |
| Segmentadores | Segmentación ×3 | `DimTiempo[Anio]`, `DimHotel[Pais]`, `DimTiempo[TipoTemporada]` |

### Página 2 — Ocupación hotelera ★

| Elemento | Visual | Campos |
|---|---|---|
| Mapa | Mapa | Ubicación `DimHotel[Ciudad]`, tamaño `Habitaciones ocupadas`, saturación `% Ocupación hotelera` |
| Estacionalidad | Matriz | Filas `DimHotel[Nombre]`, columnas `DimTiempo[NombreMesCorto]`, valor `% Ocupación hotelera`, formato condicional de escala de color |
| Evolución | Área | Eje `DimTiempo[AnioMesEtiqueta]`, valor `% Ocupación hotelera` |
| Ranking | Tabla | `DimHotel[Nombre]`, `DimHotel[Categoria]`, `Habitaciones ocupadas`, `% Ocupación hotelera`, `Ingresos por hotel` |

### Página 3 — Reservas y temporadas ★

| Elemento | Visual | Campos |
|---|---|---|
| Por temporada | Columnas agrupadas | Eje `DimTiempo[Anio]`, leyenda `DimTiempo[TipoTemporada]`, valor `Reservas` |
| Estacionalidad mensual | Columnas | Eje `DimTiempo[NombreMes]`, valor `Reservas` |
| Anticipación | Histograma (columnas) | Eje `DimPaquete[RangoDuracion]`, valor `Días de anticipación promedio` |
| Cancelaciones | Línea | Eje `DimTiempo[AnioMesEtiqueta]`, valor `Tasa de cancelación` |
| KPI | Tarjetas | `Reservas en temporada alta`, `Concentración en temporada alta`, `Crecimiento de ingresos YoY` |

### Página 4 — Destinos y tours ★

| Elemento | Visual | Campos |
|---|---|---|
| Destinos más visitados | Barras | Eje `DimHotel[PaisCiudad]`, valor `Reservas alojamiento` |
| Tours más solicitados | Barras | Eje `DimTour[Nombre]`, valor `Tours solicitados` |
| Actividades | Treemap | Grupo `DimTour[TipoActividad]`, valor `Ingresos por tour` |
| Proveedores | Tabla | `DimTour[Proveedor]`, `Tours solicitados`, `Ingresos por tour`, `Personas en tours` |

### Página 5 — Perfil del visitante y satisfacción ★

| Elemento | Visual | Campos |
|---|---|---|
| Satisfacción | Medidor | `Índice de satisfacción`, máximo 1 |
| Distribución | Columnas | Eje `FactResena[Calificacion]`, valor `Reseñas` |
| Perfil demográfico | Columnas apiladas | Eje `DimCliente[RangoEdad]`, leyenda `DimCliente[GrupoViaje]`, valor `Reservas` |
| Preferencias | Treemap | Grupo `DimCliente[TipoAlojamiento]`, valor `Reservas` |
| Presupuesto vs gasto | Columnas + línea | Eje `DimCliente[RangoPresupuesto]`, columnas `Ticket promedio`, línea `Presupuesto promedio declarado` |
| Embudo web | Embudo | `FactInteraccionWeb[TipoEvento]`, valor `Interacciones` |

### Página 6 — Estado del sistema (evidencia de alta disponibilidad)

Esta página es la que demuestra el requerimiento. Todo sale de `dw.vw_EstadoSistema`, que se evalúa **en el momento del refresco contra el nodo al que se resolvió el alias**.

| Elemento | Visual | Campos |
|---|---|---|
| Nodo activo | Tarjeta | `Nodo activo` |
| Rol de mirroring | Tarjeta | `EstadoSistema[RolMirroring]` |
| Estado del mirroring | Tarjeta | `Estado del mirroring` |
| Socio y testigo | Tarjeta ×2 | `EstadoSistema[Socio]`, `EstadoSistema[Testigo]` |
| Última carga | Tarjeta | `Última carga` |
| Frescura | Tarjeta | `Semáforo de frescura` |
| Calidad de datos | Tabla | `CalidadDatos[Fuente]`, `[Objeto]`, `[Regla]`, `[Severidad]`, `[Registros]` |
| Volumen cargado | Tarjetas | `Reservas`, `Reseñas`, `Interacciones` |
| **Bloque reservado** | — | Resultados de particionamiento e índices del **Integrante 2** |

---

## 6. Procedimiento de failover — el guion de la demostración

Coordinado con el Integrante 3.

### Antes de la caída

1. Refrescar el `.pbix` y **capturar** la página 6: nombre del nodo, rol de mirroring, última carga.
2. **Capturar** la página 1: `Reservas`, `Ingresos confirmados`, `% Ocupación hotelera`. Estos son los números que deben coincidir después.
3. Registrar la hora exacta.

### Durante la caída

El Integrante 3 detiene el nodo principal o ejecuta el failover:

```sql
-- Failover controlado desde el principal
ALTER DATABASE TurismoDW SET PARTNER FAILOVER;

-- Failover forzado si el principal ya no responde (desde el espejo)
ALTER DATABASE TurismoDW SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS;
```

**Observar que el dashboard sigue mostrando todos sus visuales.** Es la prueba de que el modo Import da continuidad de servicio: los datos están en el `.pbix`, no en el servidor caído.

### Repuntar el alias al nodo espejo

En PowerShell **como Administrador** (el nombre del nodo espejo lo da el Integrante 3):

```powershell
$nuevo = 'DBMSSOCN,NOMBRE-DEL-ESPEJO,1433'   # ajustar

foreach ($rama in @(
    'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\MSSQLServer\Client\ConnectTo')) {
    Set-ItemProperty -Path $rama -Name 'TURISMODW' -Value $nuevo -Type String
}

# Verificar que el alias resuelve al nodo nuevo
sqlcmd -S TURISMODW -E -C -Q "SELECT @@SERVERNAME, DB_NAME()"
```

> El script `99-setup/00-setup-admin.ps1` deja este mismo bloque como paso 5; sólo cambia el valor.

### Después del failover

1. **Actualizar** en Power BI Desktop.
2. La página 6 muestra ahora el **nombre del nodo espejo**. Capturar.
3. La página 1 muestra **los mismos totales** que antes. Capturar.
4. Registrar la hora → la diferencia es el **tiempo aproximado de recuperación** que pide el enunciado.

### Tabla de evidencia para el documento

| Momento | Nodo | Reservas | Ingresos confirmados | % Ocupación | Hora |
|---|---|---|---|---|---|
| Antes del failover | | | | | |
| Durante la caída (sin refrescar) | — | *(mismos valores en pantalla)* | | | |
| Después del failover | | | | | |
| **Tiempo de recuperación** | | | | | |

Que las tres filas de datos coincidan es la validación de consistencia «antes y después del reemplazo del nodo».

---

## 7. Contraste contra SQL

Ninguna cifra del dashboard se da por buena sin contrastarla. `04-sqlserver/46-validacion-consistencia.sql` imprime los mismos KPIs calculados directamente en T-SQL:

```powershell
sqlcmd -S TURISMODW -E -C -d TurismoDW -i 04-sqlserver\46-validacion-consistencia.sql `
       -o 00-docs\05-evidencias\validacion-consistencia.txt
```

Comparar tarjeta por tarjeta contra el bloque *«KPI de referencia para contrastar contra Power BI»*. Si un número no coincide, casi siempre es una de dos cosas:

- un filtro de página o de reporte que quedó activo en el `.pbix`;
- una medida que suma un porcentaje almacenado en lugar de dividir sumas (por eso `% Ocupación hotelera` divide `SUM/SUM` y nunca promedia porcentajes).

---

## 8. Entrega

1. **Archivo → Guardar como → `TurismoDW.pbix`** en `06-powerbi/`. El `.pbix` es el entregable para la clase; el `.pbip` es la fuente versionada.
2. Publicación al servicio Power BI: requiere cuenta organizacional (Microsoft 365 Business/Education). Si la cuenta disponible es personal, el servicio la rechaza. En ese caso el entregable es el `.pbix` más las capturas en `00-docs/05-evidencias/`, que es suficiente para una solución **on-premise** como la que pide el escenario.
3. Con cuenta organizacional: **Inicio → Publicar → Mi área de trabajo**. Para que el refresco programado funcione hace falta además instalar un **gateway de datos local**, porque `TURISMODW` es un origen on-premise al que la nube no llega directamente.
