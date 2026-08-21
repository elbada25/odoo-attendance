#!/usr/bin/env bash
# =============================================================================
#  instalador_linux.sh  -  Instalador autocontenido con wizard (Linux)
#  Un solo fichero. Doble-click para instalar (auto-abre terminal).
#  Usa zenity para la GUI. Privilegios con pkexec (GUI) o sudo -n.
# =============================================================================

# ---------------------------------------------------------------------------
# Auto-relaunch in terminal if not running in one (double-click support)
# ---------------------------------------------------------------------------
if [ ! -t 0 ] && [ -z "${ODOO_LAUNCHED_IN_TERMINAL:-}" ]; then
    export ODOO_LAUNCHED_IN_TERMINAL=1
    SCRIPT="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal lxterminal mate-terminal terminator xterm; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal) exec gnome-terminal -- bash "$SCRIPT" ;;
                konsole)        exec konsole -e bash "$SCRIPT" ;;
                xfce4-terminal) exec xfce4-terminal -e bash "$SCRIPT" ;;
                lxterminal)     exec lxterminal -e bash "$SCRIPT" ;;
                mate-terminal)  exec mate-terminal -e bash "$SCRIPT" ;;
                terminator)     exec terminator -e bash "$SCRIPT" ;;
                xterm)          exec xterm -e bash "$SCRIPT" ;;
                *)              exec "$term" -e bash "$SCRIPT" ;;
            esac
            exit 0
        fi
    done
    # Last resort: try xterm
    if command -v xterm >/dev/null 2>&1; then
        exec xterm -e bash "$SCRIPT"
    fi
fi

set -e

SERVICE_NAME="odoo-attendance"
DEFAULT_DIR="$HOME/OdooAttendance"
MARKER_FILE="$HOME/.local/share/OdooAttendance/install_location.txt"

# ---------------------------------------------------------------------------
# Helper: run a command with admin privileges (GUI prompt when possible)
# ---------------------------------------------------------------------------
run_privileged() {
    # Try pkexec first (GUI password dialog), then sudo -n (non-interactive),
    # then sudo with terminal prompt, then direct (if already root).
    if command -v pkexec >/dev/null 2>&1; then
        pkexec "$@" </dev/null && return 0
    fi
    if sudo -n true 2>/dev/null; then
        sudo "$@" </dev/null && return 0
    fi
    # Need password - try sudo with visible prompt
    echo "Se necesitan permisos de administrador para instalar paquetes."
    sudo "$@" && return 0
    return 1
}

get_install_dir() {
    if [ -f "$MARKER_FILE" ]; then
        local dir
        dir="$(head -1 "$MARKER_FILE" 2>/dev/null || true)"
        if [ -n "$dir" ] && [ -f "$dir/conf/fichaje.py" ]; then echo "$dir"; return 0; fi
    fi
    if [ -f "$DEFAULT_DIR/conf/fichaje.py" ]; then echo "$DEFAULT_DIR"; return 0; fi
    return 1
}

extract_payload() {
    local confdir="$1"
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    mkdir -p "$confdir"
    awk '/^___ODOO_PAYLOAD_BEGIN___$/{f=1;next} /^___ODOO_PAYLOAD_END___$/{f=0} f' "$script_path" \
        | base64 -d | tar xz -C "$confdir"
}

install_pkgs() {
    if command -v apt-get >/dev/null 2>&1; then
        run_privileged apt-get update -y >/dev/null 2>&1 || true
        run_privileged apt-get install -y "$@" </dev/null
    elif command -v dnf >/dev/null 2>&1; then
        run_privileged dnf install -y "$@" </dev/null
    elif command -v pacman >/dev/null 2>&1; then
        run_privileged pacman -Syu --noconfirm --needed "$@" </dev/null
    elif command -v zypper >/dev/null 2>&1; then
        run_privileged zypper install -y "$@" </dev/null
    elif command -v apk >/dev/null 2>&1; then
        run_privileged apk add --no-cache "$@" </dev/null
    else
        zenity --error --title="Odoo Attendance" --text="Gestor de paquetes no soportado."
        exit 1
    fi
}

detect_family() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    elif command -v zypper >/dev/null 2>&1; then echo zypper
    elif command -v apk >/dev/null 2>&1; then echo apk
    fi
}

if ! command -v zenity >/dev/null 2>&1; then
    echo "ERROR: zenity no esta instalado. Instalalo con tu gestor de paquetes."
    echo "  Debian/Ubuntu: sudo apt install zenity"
    echo "  Fedora:        sudo dnf install zenity"
    echo "  Arch:          sudo pacman -S zenity"
    exit 1
fi

EXISTING_DIR=""
if EXISTING_DIR="$(get_install_dir 2>/dev/null)"; then
    CHOICE=$(zenity --forms --title="Odoo Attendance - Instalador  v1.0.7" \
        --text="Odoo Attendance ya esta instalado en:\n\n<b>$EXISTING_DIR</b>\n\nQue deseas hacer?" \
        --add-combo="Accion" --combo-values="Actualizar (conserva configuracion)|Reinstalar (borra configuracion)|Desinstalar" \
        --width=500 2>/dev/null) || exit 0

    if [ "$CHOICE" = "Desinstalar" ]; then
        zenity --question --title="Odoo Attendance" \
            --text="Se va a DESINSTALAR Odoo Attendance.\n\nEsto eliminara:\n  - El servicio systemd\n  - La entrada de menu\n  - El directorio: $EXISTING_DIR\n    (incluyendo config.toml, .venv, .markers y logs)\n\nContinuar?" \
            --width=450 2>/dev/null || exit 0

        (
            echo "# Eliminando servicio systemd..."
            systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service" 2>/dev/null || true
            systemctl --user daemon-reload 2>/dev/null || true
            echo "25"
            echo "# Eliminando entrada de menu..."
            rm -f "$HOME/.local/share/applications/odoo-attendance-config.desktop" 2>/dev/null || true
            rm -f "$HOME/Desktop/odoo-attendance-config.desktop" 2>/dev/null || true
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
            echo "50"
            echo "# Eliminando directorio..."
            rm -rf "$EXISTING_DIR" 2>/dev/null || true
            echo "75"
            echo "# Limpiando registro..."
            rm -f "$MARKER_FILE" 2>/dev/null || true
            echo "100"
        ) | zenity --progress --title="Odoo Attendance - Desinstalando" \
            --text="Desinstalando..." --percentage=0 --auto-close --width=450 2>/dev/null

        zenity --info --title="Odoo Attendance" --text="Desinstalacion completada." --width=400 2>/dev/null
        exit 0
    fi
    DEFAULT_DIR="$EXISTING_DIR"
    PRESERVE_CONFIG="no"
    if [ "$CHOICE" = "Actualizar (conserva configuracion)" ]; then
        PRESERVE_CONFIG="yes"
    fi
else
    PRESERVE_CONFIG="no"
fi

# ---- Directory selection ----
TARGET_DIR=$(zenity --file-selection --title="Odoo Attendance - Selecciona el directorio" \
    --directory --filename="$DEFAULT_DIR" 2>/dev/null) || exit 0
[ -z "$TARGET_DIR" ] && TARGET_DIR="$DEFAULT_DIR"

# ---- Shortcut question ----
CREATE_SHORTCUT=$(zenity --question --title="Odoo Attendance" \
    --text="Crear acceso directo en el Escritorio?" \
    --ok-label="Si" --cancel-label="No" --width=400 2>/dev/null && echo "yes" || echo "no")

# ---- Install ----
FAMILY="$(detect_family)"
declare -A PKG_PYTHON=( [apt]="python3 python3-venv" [dnf]="python3 python3-devel" [pacman]="python" [zypper]="python3 python3-devel" [apk]="python3 py3-pip" )
declare -A PKG_TK=( [apt]="python3-tk" [dnf]="python3-tkinter" [pacman]="tk" [zypper]="python3-tk" [apk]="py3-tkinter" )
declare -A PKG_DBUS=( [apt]="python3-dbus" [dnf]="python3-dbus" [pacman]="python-dbus" [zypper]="python3-dbus" [apk]="py3-dbus" )
declare -A PKG_GI=( [apt]="python3-gi gir1.2-glib-2.0" [dnf]="python3-gobject glib2" [pacman]="python-gobject glib2" [zypper]="python3-gobject glib2" [apk]="py3-gobject3 glib" )

CONF_DIR="$TARGET_DIR/conf"
VENV="$CONF_DIR/.venv"
VENV_PY="$VENV/bin/python"
REQ="$CONF_DIR/requirements.txt"
USER_UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$USER_UNIT_DIR/${SERVICE_NAME}.service"
CONFIG_TOML="$CONF_DIR/config.toml"

# ---- Preserve existing config if updating ----
BACKUP_CONFIG=""
if [ "$PRESERVE_CONFIG" = "yes" ] && [ -f "$CONFIG_TOML" ]; then
    BACKUP_CONFIG="$(mktemp /tmp/odoo_config_backup.XXXXXX.toml)"
    cp "$CONFIG_TOML" "$BACKUP_CONFIG"
fi

(
    # ---- Step 1: Extract ----
    echo "# Extrayendo ficheros del proyecto..."
    extract_payload "$CONF_DIR"
    echo "10"

    # ---- Restore config if we backed it up ----
    if [ -n "$BACKUP_CONFIG" ] && [ -f "$BACKUP_CONFIG" ]; then
        cp "$BACKUP_CONFIG" "$CONFIG_TOML"
        rm -f "$BACKUP_CONFIG"
        echo "# Configuracion anterior restaurada."
    fi

    # ---- Step 2: System packages ----
    echo "# Instalando paquetes del sistema..."
    install_pkgs ${PKG_PYTHON[$FAMILY]} ${PKG_TK[$FAMILY]} ${PKG_DBUS[$FAMILY]} ${PKG_GI[$FAMILY]} 2>/dev/null || true
    echo "30"

    # ---- Step 3: Virtual env ----
    echo "# Creando entorno virtual..."
    if [ ! -x "$VENV_PY" ]; then
        python3 -m venv "$VENV" 2>&1 || {
            echo "ERROR: No se pudo crear el entorno virtual." >&2
            exit 1
        }
    fi
    echo "45"

    # ---- Step 4: Python dependencies ----
    echo "# Instalando dependencias..."
    "$VENV_PY" -m pip install --upgrade pip >/dev/null 2>&1 || true
    "$VENV_PY" -m pip install -r "$REQ" >/dev/null 2>&1 || {
        echo "AVISO: Algunas dependencias no se pudieron instalar." >&2
    }
    echo "60"

    # ---- Step 5: Launchers & uninstaller ----
    echo "# Creando lanzadores y desinstalador..."
    cat > "$TARGET_DIR/configurar.sh" <<LAUNCHER_EOF
#!/usr/bin/env bash
exec "$VENV_PY" "$CONF_DIR/config_gui.py"
LAUNCHER_EOF
    chmod +x "$TARGET_DIR/configurar.sh"

    cat > "$TARGET_DIR/desinstalar.sh" <<UNINST_EOF
#!/usr/bin/env bash
set -e
SERVICE_NAME="$SERVICE_NAME"
MARKER_FILE="$MARKER_FILE"
TARGET_DIR="$TARGET_DIR"
VENV_PY="$VENV_PY"
CONF_DIR="$CONF_DIR"

echo "=== Desinstalando Odoo Attendance ==="
echo "  Parando servicio systemd..."
systemctl --user disable --now "\$SERVICE_NAME" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/\${SERVICE_NAME}.service" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

echo "  Eliminando accesos directos..."
rm -f "$HOME/.local/share/applications/odoo-attendance-config.desktop" 2>/dev/null || true
rm -f "$HOME/Desktop/odoo-attendance-config.desktop" 2>/dev/null || true
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "  Eliminando registro..."
rm -f "\$MARKER_FILE" 2>/dev/null || true

echo "  Eliminando directorio de instalacion..."
rm -rf "\$TARGET_DIR" 2>/dev/null || true

echo ""
echo "Desinstalacion completada."
echo "Presiona Enter para cerrar..."
read -r _
UNINST_EOF
    chmod +x "$TARGET_DIR/desinstalar.sh"
    echo "75"

    # ---- Step 6: systemd service ----
    echo "# Instalando servicio systemd..."
    mkdir -p "$USER_UNIT_DIR"
    SYS_PY="$(command -v python3)"
    cat > "$SERVICE_FILE" <<UNIT_EOF
[Unit]
Description=Odoo Attendance unlock listener
After=graphical-session.target

[Service]
Type=simple
ExecStart=$SYS_PY $CONF_DIR/unlock_listener.py
WorkingDirectory=$CONF_DIR
Restart=on-failure
RestartSec=10
Environment=DISPLAY=\${DISPLAY:-:0}
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
UNIT_EOF
    systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY 2>/dev/null || true
    loginctl enable-linger "$USER" 2>/dev/null || \
        run_privileged loginctl enable-linger "$USER" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null || true
    echo "85"

    # ---- Step 7: Menu entry ----
    echo "# Creando entrada de menu..."
    APP_DIR="$HOME/.local/share/applications"
    mkdir -p "$APP_DIR"
    cat > "$APP_DIR/odoo-attendance-config.desktop" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Configurar Fichaje Odoo
Exec=$VENV_PY $CONF_DIR/config_gui.py
Path=$CONF_DIR
Icon=preferences-system
Terminal=false
Categories=Utility;Office;
DESKTOP_EOF
    chmod +x "$APP_DIR/odoo-attendance-config.desktop" 2>/dev/null || true
    if [ "$CREATE_SHORTCUT" = "yes" ] && [ -d "$HOME/Desktop" ]; then
        cp "$APP_DIR/odoo-attendance-config.desktop" "$HOME/Desktop/" 2>/dev/null || true
        chmod +x "$HOME/Desktop/odoo-attendance-config.desktop" 2>/dev/null || true
    fi
    update-desktop-database "$APP_DIR" 2>/dev/null || true
    echo "95"

    # ---- Step 8: Marker ----
    echo "# Guardando informacion de instalacion..."
    mkdir -p "$(dirname "$MARKER_FILE")"
    echo "$TARGET_DIR" > "$MARKER_FILE"
    echo "100"
) | zenity --progress --title="Odoo Attendance - Instalando" \
    --text="Instalando Odoo Attendance..." --percentage=0 --auto-close --width=450 2>/dev/null

INSTALL_RC=$?
if [ $INSTALL_RC -ne 0 ]; then
    # Clean up backup if install failed
    [ -n "$BACKUP_CONFIG" ] && [ -f "$BACKUP_CONFIG" ] && rm -f "$BACKUP_CONFIG"
    zenity --error --title="Odoo Attendance" --text="La instalacion fue cancelada o fallo." --width=400 2>/dev/null
    exit 1
fi

zenity --info --title="Odoo Attendance" \
    --text="Instalacion completada.\n\nDirectorio: $TARGET_DIR\n\nAbre 'Configurar Fichaje Odoo' desde el menu para configurar.\nPara desinstalar: ejecuta 'desinstalar.sh' en el directorio de instalacion." \
    --width=500 2>/dev/null

exit 0

___ODOO_PAYLOAD_BEGIN___
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
___ODOO_PAYLOAD_END___
