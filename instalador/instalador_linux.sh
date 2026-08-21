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
    CHOICE=$(zenity --forms --title="Odoo Attendance - Instalador  v1.0.6" \
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
