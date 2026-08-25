# Manual de Usuario del Dashboard — Turismo Inteligente

**ITI-821 · Escenario 8: Turismo Inteligente · Semanas 3 y 4**  
**Responsable: Integrante 3 (Erick) · Dashboard y métricas de negocio**

---

## 1. Introducción y Propósito del Reporte

El **Dashboard de Turismo Inteligente (`TurismoDW`)** es la herramienta analítica central para la toma de decisiones estratégicas, comerciales y operativas en la industria turística. Permite a directores de operaciones hoteleras, gerentes de producto, planificadores turísticos y analistas de marketing explorar de forma dinámica:

- Niveles de ocupación hotelera y capacidad ociosa por destino y categoría.
- Comportamiento de la demanda y estacionalidad turística (Temporada Alta vs Temporada Verde).
- Desempeño financiero de paquetes turísticos integrados y tours de aventura/ecoturismo.
- Cruce entre preferencias declaradas por los visitantes y su consumo real en destino.
- Embudo digital de interacción web y niveles de satisfacción basados en reseñas de clientes.
- Estado operativo y frescura de la infraestructura analítica.

---

## 2. Requisitos y Acceso al Reporte

### 2.1 Requisitos de Software
- **Power BI Desktop** (versión 2.126 o superior, con compatibilidad para proyectos `.pbip` y formato PBIR).
- Conexión a red hacia la base de datos `TurismoDW` (laboratorio local o nube en Amazon RDS).

### 2.2 Conexión y Apertura
1. Navegar a la carpeta del proyecto y abrir el archivo `06-powerbi/TurismoDW.pbip`.
2. En la cinta de opciones superior, hacer clic en **Inicio > Actualizar** (*Refresh*).
3. Si el sistema solicita credenciales de autenticación:
   - **Tipo de autenticación:** Seleccionar **Base de datos** (*Database*).
   - **Usuario / Contraseña:**
     - *Entorno local:* Usuario `sa` (o credencial del contenedor Docker).
     - *Entorno Amazon RDS:* Usuario `turismoadmin` y la contraseña provisionada en `.secrets/turismodw-cloud.env`.
   - **Nivel de privacidad:** Seleccionar *Organizational* o marcar *Confiar en el certificado del servidor*.

---

## 3. Guía de Navegación por Páginas

El reporte se divide en **6 páginas especializadas**, accesibles mediante las pestañas inferiores o el menú de navegación:

```text
┌────────────────────────────────────────────────────────────────────────┐
│  [1. Resumen]  [2. Ocupación]  [3. Temporadas]  [4. Tours]  [5. Visitante]  [6. Sistema]  │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 3.1 Página 1: Resumen Ejecutivo

**Objetivo:** Ofrecer una vista panorámica de alto nivel sobre la salud comercial y operativa del negocio.

```text
┌────────────────────────────────────────────────────────────────────────┐
│ [ Reservas ]  [ Ingresos Conf. ]  [ % Ocupación ]  [ Satisfacción ]    │
│  2,000,010      $13,425.5 M           30.2 %            72.5 %         │
├───────────────────────────────────┬────────────────────────────────────┤
│ TENDENCIA MENSUAL DE INGRESOS     │ INGRESOS POR CATEGORÍA DE HOTEL   │
│ [ Gráfico de Líneas / Columnas ]  │ [ Gráfico de Barras Horizontales ] │
└───────────────────────────────────┴────────────────────────────────────┘
```

- **Tarjetas Principales (KPI Cards):**
  - **Reservas Totales:** Volumen consolidado de reservas en el periodo filtrado.
  - **Ingresos Confirmados:** Facturación neta libre de cancelaciones.
  - **% Ocupación Hotelera:** Tasa ponderada de habitaciones ocupadas sobre disponibles.
  - **Estadía Promedio:** Número medio de noches por reserva.
  - **Índice de Satisfacción:** Proporción de clientes promotores (4 y 5 estrellas).
  - **Ticket Promedio:** Gasto medio por reserva confirmada.
- **Visuales de Apoyo:**
  - *Evolución de Ingresos:* Permite identificar meses récord y evaluar el crecimiento interanual (YoY).
  - *Distribución por Categoría:* Compara el aporte financiero de hoteles 5 estrellas, 4 estrellas, 3 estrellas y hoteles Boutique.

---

### 3.2 Página 2: Ocupación Hotelera

**Objetivo:** Monitorear la eficiencia en el uso de la capacidad instalada de alojamiento por región geográfica.

- **Segmentadores Disponibles:**
  - *Ciudad / Destino:* Permite filtrar por San José, Manuel Antonio, La Fortuna (Arenal), Guanacaste, Monteverde, Tortuguero, etc.
  - *Categoría de Hotel:* Filtro por estrellas (1 a 5 estrellas y Boutique).
  - *Año y Mes:* Segmentador temporal deslizable.
- **Visuales Clave:**
  - *Mapa de Calor Geográfico:* Burbujas proporcionales a la capacidad y coloreadas según el % de ocupación.
  - *Matriz Mensual de Ocupación:* Tabla cruzada con formato condicional (verde para ocupación > 50 %, amarillo entre 30-50 % y rojo < 30 %).
  - *Ranking de Hoteles:* Top 10 hoteles con mayor tasa de ocupación efectiva.

---

### 3.3 Página 3: Reservas y Temporadas

**Objetivo:** Comprender la dinámica estacional y la anticipación de compra de los turistas para optimizar políticas de cancelación y tarifas.

- **Visuales Clave:**
  - *Temporada Alta vs Temporada Verde:* Comparativa directa de facturación y volumen de reservas entre la época seca (diciembre a abril + julio) y la época verde.
  - *Días de Anticipación:* Histograma que muestra con cuántos días de antelación reserva el turista (antelación media: 30 días).
  - *Tasa de Cancelación por Canal:* Identifica qué canales de venta sufren mayor volatilidad o cancelaciones imprevistas.

---

### 3.4 Página 4: Destinos y Tours

**Objetivo:** Evaluar la rentabilidad y demanda de actividades complementarias (excursiones, deportes de aventura, ecoturismo y paquetes integrados).

- **Visuales Clave:**
  - *Ranking de Tours Líderes:* Identifica las actividades más demandadas (Canopy/Tirolesa, Rafting en Río Pacuare, Caminata al Volcán Arenal, Catamarán y Snorkel).
  - *Ingresos por Operador Turístico:* Facturación generada por cada empresa proveedora de tours.
  - *Penetración de Paquetes:* Comparativa de ingresos provenientes de reservas individuales vs paquetes turísticos combinados (vuelo + hotel + tour).

---

### 3.5 Página 5: Perfil del Visitante y Preferencias

**Objetivo:** Analizar la demografía del turista, sus gustos declarados en encuestas (JSON) y el comportamiento en el canal digital (MongoDB).

- **Visuales Clave:**
  - *Demografía del Visitante:* Distribución de turistas por país de origen (Estados Unidos, Canadá, Alemania, Reino Unido, Francia, etc.) y rango de edad.
  - *Preferencias Declaradas:* Actividades favoritas (Playa, Aventura, Naturaleza, Gastronomía) y dietas/idiomas extraídos del campo JSONB.
  - *Brecha Presupuesto vs Gasto Real:* Gráfico que contrasta el presupuesto estimado informado en el registro contra el ticket promedio real pagado.
  - *Embudo de Conversión Web:* Visualización del funnel de navegación: `Búsquedas` (100 %) → `Adición al Carrito` (42 %) → `Reservas Confirmadas` (12.2 %).

---

### 3.6 Página 6: Estado del Sistema y Calidad de Datos

**Objetivo:** Monitoreo técnico de la infraestructura para auditoría y comprobación de la migración / alta disponibilidad.

- **Indicadores Técnicos:**
  - *Nodo Activo:* Muestra el nombre de la máquina o instancia RDS que responde las consultas.
  - *Estado de Redundancia:* Indica si la base opera en clúster Always On (`SYNCHRONIZED`) o en servicio gestionado de AWS (`GESTIONADO POR AWS`).
  - *Última Carga del ETL:* Fecha y hora de finalización de la última ejecución incremental.
  - *Bitácora de Calidad:* Tabla que lista las reglas de validación aplicadas y el número de registros rechazados en staging (`etl.Error`).
  - *Semáforo de Frescura:* Tarjeta visual que confirma si los datos analíticos tienen menos de 24 horas de antigüedad.

---

## 4. Casos Prácticos de Toma de Decisiones

### Caso 1: Detección de Capacidad Ociosa en Temporada Verde
1. En la **Página 2 (Ocupación Hotelera)**, seleccionar el año en curso y filtrar por los meses de mayo a octubre.
2. Identificar en la matriz los hoteles en Guanacaste y Arenal con ocupación inferior al 25 %.
3. **Acción de Negocio:** Diseñar promociones de "Fin de semana verde" empaquetadas con tours de aguas termales y descuento del 20 % en hospedaje para incentivar el turismo local y regional.

### Caso 2: Reducción del Abandono de Carrito en la Plataforma Web
1. En la **Página 5 (Perfil del Visitante)**, analizar la tarjeta `Abandonos de carrito` (más de 380,000 eventos detectados).
2. Cruzar los abandonos con el `DestinoBuscado` más frecuente (Manuel Antonio y La Fortuna).
3. **Acción de Negocio:** Configurar disparadores automáticos en la plataforma web para enviar recordatorios con disponibilidad en tiempo real y asistencia por chat cuando un usuario abandone el carrito en destinos de alta demanda.

### Caso 3: Estrategia de Up-Selling según Brecha Presupuestaria
1. En la **Página 5**, observar el indicador `Brecha presupuesto vs gasto` en el segmento de turistas de 35 a 54 años provenientes de Norteamérica.
2. Dado que el gasto real supera el presupuesto declarado en más de un 15 %, existe margen para ofrecer servicios premium.
3. **Acción de Negocio:** Habilitar opciones de mejora de habitación (*upgrade* a Suite o Vista al Mar) y tours VIP privados durante el proceso de reserva en línea.

---

## 5. Procedimiento para Alternar Entornos (Local vs Nube)

Si el analista o evaluador necesita cambiar el origen de datos del reporte de Power BI entre el laboratorio Docker local y la nube en Amazon RDS:

```powershell
# Para apuntar el reporte a la base de datos local:
.\07-migracion\repuntar-powerbi.ps1 -Local

# Para apuntar el reporte a la instancia en Amazon RDS:
.\07-migracion\repuntar-powerbi.ps1
```

Tras ejecutar el script, abra `06-powerbi/TurismoDW.pbip` en Power BI Desktop y presione **Inicio > Actualizar**. En la Página 6 observará el cambio inmediato del `NodoActivo` y el estado de la infraestructura.
