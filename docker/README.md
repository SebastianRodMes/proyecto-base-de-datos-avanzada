# 🚀 Cómo montar todo el proyecto (guía para el equipo)

Esta guía deja **toda la base de datos armada y con datos** en tu
computadora, sin que tengas que instalar PostgreSQL, MongoDB ni SQL Server a
mano, y sin pedirle archivos a nadie. Está pensada para que **cualquiera del
equipo** la pueda seguir, aunque no haya usado Docker antes.

> **¿Qué es lo que vamos a hacer?**
> En lugar de instalar cada programa por separado, usamos **Docker**, que es
> como una "caja" que trae todo listo. Le damos un comando, esperamos, y al
> final tenemos la base `TurismoDW` con sus 2 millones de reservas corriendo
> en la máquina, lista para conectarse y trabajar.

---

## 👥 Quién hace qué

| Integrante | Persona | Su parte del proyecto |
|---|---|---|
| **1** | Alex Herrera | Base analítica, ETL y reporte Power BI *(ya entregado)* |
| **2** | **Sebastián** | Filegroups, particionamiento e índices |
| **3** | **Erick** | Alta disponibilidad (Mirroring) y prueba de falla |
| **4** | **Sergio** | Rendimiento, consistencia y documentación |

Cada quien, al final de esta guía, tiene una sección con **qué sigue para su parte**.

---

## ✅ Antes de empezar: instalar dos programas

Solo se hace **una vez** en cada computadora.

### 1. Docker Desktop
Es el motor que levanta todo. Descargalo, instalalo y **ábrelo** (tiene que
quedar corriendo; vas a ver una ballenita 🐳 en la barra de tareas).
- Descarga: https://www.docker.com/products/docker-desktop/

### 2. SSMS (SQL Server Management Studio)
Es la ventana con la que te conectás a la base para ver las tablas y correr
consultas.
- Descarga: https://learn.microsoft.com/es-es/ssms/download-sql-server-management-studio-ssms

---

## 📥 Paso 1 — Traer el proyecto a tu computadora

El proyecto está en GitHub (repositorio **privado**). Pedile a Sebastián que
te agregue como colaborador; después descargalo. La forma más fácil:

1. Instalá **GitHub Desktop**: https://desktop.github.com/
2. Entrá con tu cuenta de GitHub.
3. *File → Clone repository →* elegí `proyecto-base-de-datos-avanzada`.

Eso te deja una carpeta con todo el proyecto adentro.

> Si preferís la terminal:
> ```bash
> git clone https://github.com/SebastianRodMes/proyecto-base-de-datos-avanzada.git
> ```

---

## ▶️ Paso 2 — Levantar todo (un solo comando)

1. Abrí una terminal (**PowerShell** en Windows).
2. Metete en la carpeta `docker` del proyecto. Por ejemplo:
   ```bash
   cd "ruta\donde\lo\clonaste\proyecto-base-de-datos-avanzada\docker"
   ```
3. Escribí este comando y dale Enter:
   ```bash
   docker compose up -d --build
   ```

Eso es todo. Docker se encarga del resto.

> **⏳ La primera vez tarda (unos 20–25 minutos).** Es normal: está creando la
> base y generando los 2 millones de reservas. **Solo pasa la primera vez.**
> Las siguientes veces levanta en segundos.

---

## 👀 Paso 3 — Ver el avance (opcional)

Si querés mirar cómo va mientras esperás:

```bash
docker compose logs -f orchestrator
```

Cuando aparezca el mensaje **"TurismoDW construida y poblada"**, ya terminó.
Cerrá el seguimiento con `Ctrl + C` (eso solo cierra el "espía", no apaga nada).

---

## 🔌 Paso 4 — Conectarte con SSMS

Abrí SSMS y en la ventana de conexión poné exactamente esto:

| Campo | Qué escribir |
|---|---|
| **Nombre del servidor** | `localhost,1433` |
| **Authentication** | *Autenticación de SQL Server* |
| **Nombre de usuario** | `sa` |
| **Contraseña** | `Armagedon45*` |
| **Certificado de servidor de confianza** | ✔️ marcá la casilla |

Dale **Conectar**. En el panel de la izquierda, abrí *Bases de datos* y vas a
ver **`TurismoDW`**. ¡Listo, ya podés trabajar!

Para comprobar que tiene datos, abrí una *Nueva consulta* y ejecutá:
```sql
SELECT COUNT(*) FROM TurismoDW.dw.FactReserva;   -- debe dar 2,000,000
```

---

## 🧭 Qué sigue, según tu parte

### 🟦 Integrante 2 — Sebastián (particionamiento e índices)
Tu trabajo real ya tiene los scripts hechos, en `04-sqlserver/`:
1. `47a-medicion-testigo.sql` → corré y guardá el resultado como **"antes"** (línea base).
2. `47b-particionamiento.sql` → crea los filegroups por año y particiona.
3. `47c-indices-tuning.sql` → crea los índices de mejora.
4. `47a` otra vez → guardá el resultado como **"después"** y compará.
5. Los números van a la **página 6** del reporte de Power BI.
Detalle completo en `00-docs/03-contrato-integrante2.md`.

### 🟩 Integrante 3 — Erick (Alta disponibilidad / Mirroring)
⚠️ **Tu parte NO se monta con este Docker.** El Mirroring necesita varias
instancias de SQL Server con una configuración especial. Tu guía es
`99-setup/01-instalar-developer.md` (sección 6). Coordiná con Sebastián:
conviene que su particionamiento esté listo **antes** de armar el espejo.

### 🟨 Integrante 4 — Sergio (rendimiento y documentación)
La base que levantás con este Docker ya trae todo lo que necesitás:
- Tiempos del proceso de carga → tabla `etl.Etapa`.
- Historial de consultas → **Query Store** (ya activo).
- Las 22 pruebas de consistencia → `04-sqlserver/46-validacion-consistencia.sql`.
Detalle en `INSTRUCCIONES-EQUIPO.md` (sección Integrante 4).

---

## 🛠️ Comandos útiles del día a día

| Quiero... | Comando |
|---|---|
| Apagar todo (sin borrar datos) | `docker compose stop` |
| Volver a prender (ya con datos, es rápido) | `docker compose up -d` |
| Ver si está corriendo | `docker compose ps` |
| Empezar de cero (borra los datos y reconstruye) | `docker compose down -v` y luego `docker compose up -d --build` |

---

## ❓ Si algo sale mal

- **"docker: command not found" o error de conexión** → Docker Desktop no está
  abierto. Abrilo, esperá a que diga "Engine running" y reintentá.
- **SSMS no conecta** → revisá que pusiste *Autenticación de SQL Server* (no
  Windows) y que marcaste *Certificado de servidor de confianza*.
- **El puerto 1433 está ocupado** → tenías otro SQL Server corriendo; apagalo,
  o pedile ayuda a Sebastián.
- **Quedó a medias la primera vez** → `docker compose down -v` y volvé a
  correr `docker compose up -d --build` para empezar limpio.
