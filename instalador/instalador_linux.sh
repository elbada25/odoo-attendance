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
