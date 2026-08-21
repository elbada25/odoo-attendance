# Odoo Attendance Automation

Automatizacion de fichaje en Odoo. Al desbloquear el PC aparece un dialogo
preguntando si quieres fichar; si aceptas, Selenium abre Chrome, inicia sesion
en Odoo y crea los bloques de asistencia del dia segun el horario configurado.

- **Windows**: tarea del Programador de Tareas (trigger al desbloquear / iniciar sesion).
- **Linux**: servicio `systemd --user` que escucha la senal de desbloqueo por D-Bus.
- **Fichaje en masa**: ficha un rango de fechas de golpe via API JSON-RPC.

Toda la configuracion (credenciales, horarios, on/off) se gestiona desde la
**app GUI** o editando `config.toml`. No hace falta tocar codigo.

---

## Descarga e instalacion

Descarga el instalador de tu sistema desde [GitHub Releases](../../releases):

| SO | Fichero |
|----|---------|
| Windows | `instalador_windows.bat` |
| Linux   | `instalador_linux.sh`   |

### Windows
1. Doble click en `instalador_windows.bat`.
2. Aparece un wizard grafico (WinForms):
   - Bienvenida
   - Seleccion de directorio (con boton "Examinar...")
   - Checkbox "Crear acceso directo en el Escritorio"
   - Barra de progreso con log detallado
3. El instalador **se autoeleva** (UAC) si necesita permisos.
4. Si ya esta instalado, ofrece **Actualizar** (conserva configuracion),
   **Reinstalar** (borra todo) o **Desinstalar**.

### Linux
1. Da permisos de ejecucion: `chmod +x instalador_linux.sh`
2. Doble click (se abre solo en terminal) o `bash instalador_linux.sh`.
3. Dialogos nativos (zenity): seleccion de directorio, progreso, finalizacion.
4. Pregunta si quieres crear un acceso directo en el Escritorio.

### Que instala
- Extrae los ficheros del proyecto (embebidos en el instalador).
- Instala Python si no esta presente.
- Crea entorno virtual e instala dependencias (`requirements.txt`).
- Registra la tarea programada (Windows) o el servicio systemd (Linux).
- Crea lanzador **"Configurar Fichaje Odoo"** en el menu/escritorio.
- Crea **desinstalador** en el directorio de instalacion.

### Estructura instalada
```
OdooAttendance/
├── Configurar Fichaje Odoo.bat   # abre la GUI
├── Desinstalar.bat               # desinstala todo
└── conf/                         # ficheros internos (no tocar)
    ├── config.toml
    ├── ...
    └── .venv/
```

---

## Actualizaciones

Para actualizar a una version nueva:

1. Descarga el nuevo instalador de [GitHub Releases](../../releases).
2. Ejecutalo. Detectara la instalacion existente.
3. Elige **"Actualizar (conserva configuracion)"**.
4. El instalador respalda tu `config.toml`, extrae los ficheros nuevos,
   restaura tu configuracion y reinstala dependencias.

Tus credenciales, horarios y marcadores se conservan. Solo se actualiza el
codigo de la aplicacion.

> La version instalada se muestra en la barra de titulo de la GUI
> (`Odoo Attendance - Configuracion  v1.0.0`).

---

## Configuracion (app GUI)

Abre **"Configurar Fichaje Odoo"** desde el Escritorio / menu de aplicaciones.

### Pestanas

| Pestana | Contenido |
|---------|-----------|
| **General / Credenciales** | URL Odoo, usuario, contrasena, headless, perfil Chrome, activar/desactivar, dias a saltar, meses de verano |
| **Horario normal** | Bloques por dia (entrada, salida, categoria). Botones `+ Anadir bloque` y `X` |
| **Horario verano** | Igual, aplicable a los meses marcados como verano |
| **Dias especiales** | Fechas `MM-DD` que sobreescriben el horario semanal (ej. 24/12, 31/12) |
| **Fichaje en masa** | Rango de fechas `YYYY-MM-DD` con exclusiones. Previsualiza los dias antes de fichar |

### Botones
- **Guardar** / **Cancelar**
- **Fichar ahora**: ejecuta la automatizacion hoy, ignorando el marcador diario
- **Fichar rango** (pestana Fichaje en masa): registra asistencia para un
  rango de fechas via API JSON-RPC (mucho mas rapido que el navegador)

---

## Fichaje en masa

Permite fichar un rango de fechas de golpe. Utiliza la API JSON-RPC de Odoo
en vez del navegador, por lo que es muy rapido (~1 segundo por dia).

1. Ve a la pestana **Fichaje en masa**.
2. Introduce fecha **Desde** y **Hasta** (`YYYY-MM-DD`).
3. Opcionalmente, excluye fechas concretas separadas por comas.
4. Pulsa **Previsualizar dias** para ver que dias se ficharian y con que bloques.
5. Pulsa **Fichar rango** para ejecutar.

Tambien desde terminal:
```bash
python odoo_attendance.py --bulk 2026-08-01 2026-08-31 --exclude 2026-08-15,2026-08-22
```

> Odoo permite fichar hasta 200 dias antes y 2 dias despues de la fecha actual.
> Las fechas fuera de ese rango se saltan con un mensaje de error.

---

## Como funciona (dialogo de fichaje)

Al desbloquear el PC se lanza `fichaje.py`:

1. Comprueba `behavior.enabled`. Si esta desactivado, no hace nada.
2. Comprueba si hoy es dia saltado o ya tiene marcador (`.markers/<fecha>.done`).
3. Si no hay bloques programados hoy, no pregunta.
4. Muestra un dialogo con 3 opciones:
   - **Fichar** -> ejecuta Selenium y marca el dia.
   - **No preguntar mas hoy** -> marca sin fichar.
   - **Ahora no** -> volvera a preguntar en el proximo desbloqueo.
5. Todo se registra en `attendance.log`.

---

## Desarrollo

### Requisitos
- Python 3.10+
- `pip install -r requirements.txt`

### Generar instaladores
```bash
python generar_instaladores.py
```
Genera `instalador/instalador_windows.bat` e `instalador/instalador_linux.sh`
con todos los ficheros del proyecto embebidos en base64.

### Versionado
El fichero `VERSION` contiene la version actual. Se muestra en la GUI y en los
instaladores. Al hacer un release, actualiza `VERSION`, regenera los
instaladores y subelos a GitHub Releases.

---

## Estructura del repositorio

```
├── .gitignore
├── VERSION                          # version actual
├── version.py                       # lector de VERSION
├── config.example.toml              # plantilla (valores demo)
├── config_gui.py                    # app GUI de configuracion
├── fichaje.py                       # orquestador (dialogo + marcador)
├── odoo_attendance.py               # automatizacion Selenium + RPC
├── unlock_listener.py               # detector D-Bus (Linux)
├── generar_instaladores.py          # genera los instaladores autocontenidos
├── requirements.txt
├── README.md
└── instalador/                      # instaladores generados (se suben a Releases)
    ├── instalador_windows.bat
    └── instalador_linux.sh
```

> `config.toml` NO esta en el repositorio (`.gitignore`). Solo se incluye
> `config.example.toml` con valores demo. Cada usuario tiene su propio
> `config.toml` con sus credenciales reales, que nunca se sube a git.
