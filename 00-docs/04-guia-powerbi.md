# Guia de Power BI y alta disponibilidad

Proyecto: Turismo Inteligente - Semana 3

Modelo: `TurismoDW`
Modo: Import

## Conexion

El proyecto PBIP se conecta a:

```text
Servidor: localhost,14330
Base:     TurismoDW
Modo:     Importar
```

`localhost,14330` no es una replica fisica. Es el endpoint estable del laboratorio Docker y se repunta al servidor que tenga el rol `PRIMARY`.

```text
Power BI --> localhost:14330 --> proxy --> sqlserver o sqlserver-secondary
```

Esto evita editar las 16 consultas M durante un failover. En una instalacion Windows equivalente puede definirse `POWERBI_SQL_SERVIDOR=TURISMODW` antes de regenerar el PBIP y usar el alias administrado por `99-setup/00-setup-admin.ps1`.

## Por que se usa Import

| Criterio | Import | DirectQuery |
|---|---|---|
| Caida temporal del servidor | Conserva el ultimo dashboard cargado | Los visuales fallan |
| Carga analitica | VertiPaq atiende las consultas | Cada visual consulta SQL Server |
| Evidencia de recuperacion | El refresco confirma el nuevo nodo | Cambio inmediato, pero dependiente de la red |

Import separa la carga historica de las operaciones y mantiene visible el reporte mientras cambia el nodo.

## Abrir y actualizar

1. Abrir `06-powerbi/TurismoDW.pbip`.
2. Pulsar **Inicio > Actualizar**.
3. En el primer acceso elegir **Base de datos**.
4. Usar el login SQL configurado en `docker/docker-compose.yml`.
5. Marcar **Confiar en el certificado del servidor** si aparece esa opcion.

El primer refresco importa alrededor de 8.7 millones de filas de hechos y puede tardar varios minutos.

Si Power BI conserva una credencial incorrecta:

1. **Archivo > Opciones y configuracion > Configuracion de origen de datos**.
2. Seleccionar `localhost:14330`.
3. **Borrar permisos** o **Editar permisos**.
4. Volver a actualizar con autenticacion de base de datos.

## Modelo validado

| Elemento | Cantidad |
|---|---:|
| Tablas | 17 |
| Relaciones | 26 |
| Medidas DAX | 52 |
| Paginas | 6 |
| Visuales | 55 |
| Archivos JSON PBIR | 65 |
| Referencias de campo | 89 validas, 0 invalidas |

Las relaciones son muchos-a-uno y de filtro simple desde dimensiones hacia hechos. `DimTiempo` es la dimension de fechas; `FactReserva` usa como relacion activa `FechaInicioKey` y conserva relaciones inactivas para fecha de reserva y fecha final.

## Paginas del reporte

1. **Resumen ejecutivo**: reservas, ingresos, ocupacion, estancia, satisfaccion y ticket.
2. **Ocupacion hotelera**: mapa, matriz mensual, evolucion y ranking.
3. **Reservas y temporadas**: estacionalidad, anticipacion y cancelaciones.
4. **Destinos y tours**: destinos, actividades, proveedores e ingresos.
5. **Perfil del visitante**: demografia, preferencias, presupuesto y embudo web.
6. **Estado del sistema**: nodo, rol HA, sincronizacion, ultima carga y calidad.

La pagina 6 consume `dw.vw_EstadoSistema`. La vista conserva los nombres `RolMirroring` y `EstadoMirroring` por compatibilidad con el modelo, pero cuando existe Always On devuelve valores como `AG PRIMARY` y `SYNCHRONIZED`.

## Guion de demostracion

### Antes

1. Actualizar Power BI.
2. Capturar la pagina 1.
3. Capturar la pagina 6 con el nodo y el estado.
4. Registrar la hora.

Valores SQL de referencia:

| KPI | Valor esperado |
|---|---:|
| Reservas | 2,000,005 |
| Monto total | 16,709,495,659.28 |
| Monto confirmado | 13,425,538,311.48 |
| Ocupacion | 30.1854% |
| Resenas | 500,000 |
| Interacciones | 1,500,000 |

### Failover

```powershell
.\04-sqlserver\51-prueba-failover-alwayson-docker.ps1
```

El script:

1. exige que la replica este `SYNCHRONIZED`;
2. captura siete controles;
3. promueve la replica secundaria;
4. repunta `localhost,14330`;
5. calcula el RTO;
6. compara los datos;
7. detiene el nodo anterior y comprueba continuidad;
8. lo reinicia y restaura la sincronizacion.

La ejecucion documentada obtuvo un RTO de **3.667 segundos** y ninguna diferencia de datos.

### Despues

1. El dashboard importado continua visible durante la transicion.
2. Pulsar **Actualizar**.
3. Capturar la pagina 6: el nodo debe ser `sql-secondary`, rol `AG PRIMARY`, estado `SYNCHRONIZED`.
4. Capturar la pagina 1 y comparar sus KPI con la captura anterior.

## Contraste contra SQL

La validacion integral se ejecuta con los valores actuales de las fuentes:

```powershell
sqlcmd -S localhost,14330 -U sa -C -d TurismoDW `
  -i 04-sqlserver\46-validacion-consistencia.sql `
  -v ReservasOrigen=2000005 MontoOrigen=16709495659.28 `
     ResenasOrigen=500000 InteraccionesOrigen=1500000
```

Resultado esperado:

```text
22 | 22 | 0 | 0 | MODELO CONSISTENTE
```

Si una tarjeta no coincide, revisar primero filtros persistentes y despues la medida. El porcentaje de ocupacion debe dividir la suma de habitaciones ocupadas entre la suma de habitaciones disponibles; no debe promediar porcentajes diarios.

## Entrega

1. Guardar el PBIP.
2. **Archivo > Guardar como** y generar `TurismoDW.pbix` si la clase exige el binario.
3. Guardar capturas de las paginas 1 y 6 en `00-docs/05-evidencias/`.
4. Entregar tambien las evidencias SQL y el informe del Integrante 4.

Para publicar en Power BI Service se necesita una cuenta organizacional y un gateway local que alcance `localhost,14330` desde la maquina donde se instala el gateway.
