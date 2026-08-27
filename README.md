# Odoo Attendance

Aplicacion de escritorio que automatiza el fichaje en Odoo. Al desbloquear el
PC aparece un dialogo preguntando si quieres fichar; si aceptas, la app se
conecta a Odoo via API y crea los bloques de asistencia del dia segun el
horario configurado.

- **Windows**: tarea del Programador de Tareas (trigger al desbloquear / iniciar sesion).
- **Linux**: servicio `systemd --user` que escucha la senal de desbloqueo por D-Bus.
- **Fichaje en masa**: ficha un rango de fechas de golpe via API JSON-RPC.
- **Revision de dias faltantes**: comprueba los ultimos 200 dias y ficha los que falten.
- **Correccion de fichajes**: borra y recrea los fichajes de un rango segun tu horario.
- **Eliminacion de fichajes**: borra fichajes en un rango de fechas.
- **Bandeja del sistema**: minimiza la app al tray en vez de cerrarla.
- **Auto-fichaje**: ficha automaticamente sin preguntar, de forma invisible.
- **Recordatorio diario**: notificacion si no has fichado a la hora configurada.

Toda la configuracion (credenciales, horarios, opciones) se gestiona desde la
**app GUI** o editando `config.toml`. No hace falta tocar codigo.

---

## Descarga e instalacion

Descarga el instalador de tu sistema desde [GitHub Releases](../../releases):

| SO | Fichero |
|----|---------|
| Windows | `instalador_windows.exe` (recomendado) o `instalador_windows.bat` |
| Linux   | `instalador_linux.sh`   |

### Windows
1. Doble click en `instalador_windows.exe` (o `.bat`).
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

La app **comprueba automaticamente** si hay nuevas versiones al abrir la GUI
(configurable). Si hay una actualizacion disponible:

1. Aparece un aviso en la GUI y en el dialogo de fichaje.
2. Pulsa **"Actualizar ahora"**.
3. La app descarga el nuevo instalador y lo ejecuta.
4. El instalador detecta la instalacion existente y ofrece **"Actualizar
   (conserva configuracion)"**.
5. Tu `config.toml`, horarios y marcadores se conservan. Solo se actualiza
   el codigo.

Tambien puedes actualizar manualmente descargando el instalador de
[GitHub Releases](../../releases) y ejecutandolo.

> La version instalada se muestra en la barra de titulo de la GUI
> (`Odoo Attendance - v1.2.0`).

---

## Configuracion (app GUI)

Abre **"Configurar Fichaje Odoo"** desde el Escritorio / menu de aplicaciones.

### Pestanas

| Pestana | Contenido |
|---------|-----------|
| **General** | Credenciales Odoo, perfil Chrome, headless, activar/desactivar, dias a saltar, meses de verano, actualizaciones, bandeja del sistema, auto-fichaje, recordatorio |
| **Horario normal** | Bloques por dia (entrada, salida, categoria). Botones `+ Anadir bloque` y `X` |
| **Horario verano** | Igual, aplicable a los meses marcados como verano |
| **Dias especiales** | Fechas `MM-DD` que sobreescriben el horario semanal (ej. 24/12, 31/12) |
| **Fichaje en masa** | Rango de fechas `YYYY-MM-DD` con exclusiones. Previsualiza los dias antes de fichar |
| **Revision** | Comprueba dias faltantes en los ultimos 200 dias y permite ficharlos |
| **Eliminar** | Borra fichajes en un rango de fechas |
| **Corregir** | Borra y recrea fichajes en un rango segun el horario configurado |

### Botones del pie de pagina
- **Guardar** / **Cancelar**
- **Fichar ahora**: ejecuta la automatizacion hoy, ignorando el marcador diario

### Opciones de comportamiento (pestana General)

| Opcion | Descripcion |
|--------|-------------|
| Activar dialogo al desbloquear | Master on/off del dialogo de fichaje |
| Comprobar actualizaciones | Busca nuevas versiones al abrir la GUI |
| Dias a saltar | Weekdays en los que no se pregunta (ej. sabado, domingo) |
| Meses de verano | Meses que usan horario intensivo |
| **Minimizar al system tray** | Al cerrar la GUI, se oculta en la bandeja del sistema con un icono. Menu del tray: Mostrar, Fichar ahora, Salir |
| **Fichar automaticamente** | Ficha sin mostrar dialogo al desbloquear el PC. Configurable invisible (sin ventana de Chrome) |
| **Recordatorio diario** | Cuando la app esta en el tray, muestra una notificacion si no has fichado a la hora configurada |

---

## Revision de dias faltantes

Comprueba si te has dejado algun dia por fichar en los **ultimos 200 dias**:

1. Ve a la pestana **Revision**.
2. Pulsa **Comprobar dias faltantes**.
3. La app consulta Odoo (en segundo plano, sin ventana visible) y muestra que
   dias laborables no tienen fichaje.
4. Pulsa **Fichar dias faltantes** para registrarlos todos de golpe.

Tambien desde terminal:
```bash
python odoo_attendance.py --check-missing
```

---

## Eliminacion de fichajes

Borra fichajes existentes en un rango de fechas:

1. Ve a la pestana **Eliminar**.
2. Selecciona fecha **Desde** y **Hasta**.
3. Pulsa **Eliminar fichajes** y confirma.

> Esta accion **no se puede deshacer**. Los fichajes con `state=confirmed` se
> pasan a `draft` antes de borrarlos (Odoo no permite borrar confirmed).

Tambien desde terminal:
```bash
python odoo_attendance.py --delete 2026-06-01 2026-06-30
```

---

## Correccion de fichajes

Borra y vuelve a crear los fichajes de un rango segun tu horario configurado.
Util para corregir fichajes con horas incorrectas o con `worked_hours=0`:

1. Ve a la pestana **Corregir**.
2. Selecciona fecha **Desde** y **Hasta**.
3. Pulsa **Corregir fichajes** y confirma.

La app borra los fichajes existentes en el rango y crea nuevos con los bloques
configurados (normal o verano segun el mes). Todo en segundo plano, sin
ventana visible.

Tambien desde terminal:
```bash
python odoo_attendance.py --correct 2026-06-01 2026-06-30
```

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
4. Si **auto-fichaje** esta activado, ficha directamente sin dialogo
   (configurable en modo invisible).
5. Si no, muestra un dialogo con 3 opciones:
   - **Fichar** (preseleccionado, pulsa Enter) -> ejecuta la automatizacion y marca el dia.
   - **No preguntar mas hoy** -> marca sin fichar.
   - **Ahora no** -> volvera a preguntar en el proximo desbloqueo.
6. Todo se registra en `attendance.log`.

### Auto-fichaje

Si `auto_fichaje = true` en la configuracion, el dialogo no aparece. La app
ficha directamente al desbloquear el PC. Se puede configurar para que Chrome
funcione de forma invisible (`auto_fichaje_headless = true`).

### Recordatorio diario

Si `reminder_enabled = true` y la app esta minimizada en el system tray, un
proceso en background comprueba cada 5 minutos si hoy se ha fichado. Si paso
la hora configurada y no hay fichaje, muestra una notificacion en el tray.

> El recordatorio requiere que la app este abierta (minimizada en el tray).
> Si la app esta completamente cerrada, el recordatorio no funciona.

---

## Bandeja del sistema (system tray)

Si `minimize_to_tray = true`:

- Al cerrar la GUI, la ventana se oculta y aparece un icono en la bandeja
  del sistema.
- Click derecho en el icono muestra un menu:
  - **Mostrar**: restaura la ventana.
  - **Fichar ahora**: ejecuta el fichaje de hoy.
  - **Salir**: cierra la app completamente.
- Doble click en el icono restaura la ventana.
- Si el recordatorio esta activado, las notificaciones aparecen desde el tray.

---

## Comandos CLI

```bash
# Fichar hoy
python odoo_attendance.py

# Fichar hoy en modo invisible (sin ventana de Chrome)
python odoo_attendance.py --headless

# Fichar un rango de fechas
python odoo_attendance.py --bulk START END [--exclude D1,D2,...]

# Comprobar dias faltantes (ultimos 200 dias)
python odoo_attendance.py --check-missing

# Eliminar fichajes en un rango
python odoo_attendance.py --delete START END

# Corregir fichajes en un rango (borra y recrea)
python odoo_attendance.py --correct START END
```

Todas las fechas en formato `YYYY-MM-DD`.

---

## Desarrollo

### Requisitos
- Python 3.10+
- `pip install -r requirements.txt`

### Dependencias
- `selenium` - automatizacion del navegador
- `requests` - llamadas JSON-RPC a Odoo
- `pystray` - icono en la bandeja del sistema
- `Pillow` - generacion del icono del tray
- `python-dotenv` - variables de entorno (fallback)
- `tomli` - parser TOML (Python < 3.11)

### Generar instaladores
```bash
python generar_instaladores.py
```
Genera `instalador/instalador_windows.exe`,
`instalador/instalador_windows.bat` e `instalador/instalador_linux.sh`
con todos los ficheros del proyecto embebidos.

### Versionado
El fichero `VERSION` contiene la version actual. Se muestra en la GUI y en los
instaladores. Al hacer un release, actualiza `VERSION`, crea un tag `vX.Y.Z`
y subelo. GitHub Actions genera los instaladores automaticamente.

---

## Estructura del repositorio

```
├── .github/workflows/release.yml    # CI: genera instaladores al pushear tags
├── .gitignore
├── VERSION                          # version actual
├── version.py                       # lector de VERSION
├── config.example.toml              # plantilla (valores demo)
├── config_gui.py                    # app GUI de configuracion
├── fichaje.py                       # orquestador (dialogo + marcador)
├── odoo_attendance.py               # automatizacion Selenium + RPC
├── unlock_listener.py               # detector D-Bus (Linux)
├── check_updates.py                 # comprobacion de actualizaciones
├── theme.py                         # tema visual (claro/oscuro)
├── widgets.py                       # widgets personalizados
├── datepickers.py                   # selectores de fecha/hora
├── generar_instaladores.py          # genera los instaladores autocontenidos
├── requirements.txt
├── README.md
└── instalador/                      # instaladores generados (se suben a Releases)
    ├── instalador_windows.exe
    ├── instalador_windows.bat
    └── instalador_linux.sh
```

> `config.toml` NO esta en el repositorio (`.gitignore`). Solo se incluye
> `config.example.toml` con valores demo. Cada usuario tiene su propio
> `config.toml` con sus credenciales reales, que nunca se sube a git.
