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
    CHOICE=$(zenity --forms --title="Odoo Attendance - Instalador  v1.0.2" \
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
