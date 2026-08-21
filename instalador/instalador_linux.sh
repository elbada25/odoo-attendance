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
    CHOICE=$(zenity --forms --title="Odoo Attendance - Instalador  v1.0.4" \
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
