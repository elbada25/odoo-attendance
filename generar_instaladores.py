"""Genera instaladores wizard autocontenidos (Windows .bat + Linux .sh).

Estructura de instalacion resultante:
  OdooAttendance/
  ├── Configurar Fichaje Odoo.bat   (Windows) / .desktop (Linux)  -> abre GUI
  ├── Desinstalar.bat / .sh         -> desinstala todo
  └── conf/                         -> todo lo interno (user no toca)
      ├── config.toml
      ├── config_gui.py
      ├── fichaje.py
      ├── odoo_attendance.py
      ├── unlock_listener.py
      ├── requirements.txt
      └── .venv/

Uso:
    python generar_instaladores.py
"""

from __future__ import annotations

import base64
import io
import subprocess
import tarfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
INSTALLER_DIR = SCRIPT_DIR / "instalador"

# Read version
_VERSION = (SCRIPT_DIR / "VERSION").read_text(encoding="utf-8").strip()

# Ficheros que van a conf/ (el usuario no necesita tocarlos).
PROJECT_FILES = [
    ("config.toml", "config.toml"),
    ("config.example.toml", "config.example.toml"),
    ("config_gui.py", "config_gui.py"),
    ("fichaje.py", "fichaje.py"),
    ("odoo_attendance.py", "odoo_attendance.py"),
    ("unlock_listener.py", "unlock_listener.py"),
    ("check_updates.py", "check_updates.py"),
    ("theme.py", "theme.py"),
    ("datepickers.py", "datepickers.py"),
    ("widgets.py", "widgets.py"),
    ("requirements.txt", "requirements.txt"),
    ("VERSION", "VERSION"),
    ("version.py", "version.py"),
]


def build_payload() -> str:
    buf = io.BytesIO()
    # If config.toml is missing (e.g. CI where it's gitignored), copy from
    # config.example.toml so the payload always ships a default config.
    config_toml = SCRIPT_DIR / "config.toml"
    config_example = SCRIPT_DIR / "config.example.toml"
    _restore_config = False
    if not config_toml.exists() and config_example.exists():
        import shutil
        shutil.copy(config_example, config_toml)
        _restore_config = True

    try:
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for disk_path, arcname in PROJECT_FILES:
                path = SCRIPT_DIR / disk_path
                if not path.exists():
                    raise FileNotFoundError(f"Falta {path}")
                tar.add(path, arcname=arcname)
    finally:
        if _restore_config:
            config_toml.unlink()

    return base64.b64encode(buf.getvalue()).decode("ascii")


# =========================================================================
# Windows installer
# =========================================================================
# =========================================================================
# Windows installer (.exe via C# launcher + embedded PowerShell)
# =========================================================================

# C# launcher source — compiled to instalador_windows.exe with csc.exe.
# The exe reads its own file to extract the embedded PS1 and runs it hidden.
# No console window ever appears.
CS_LAUNCHER = r'''// Odoo Attendance Installer Launcher
// Reads its own executable to find embedded PowerShell + payload markers.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

class Launcher {
    [STAThread]
    static void Main() {
        Application.EnableVisualStyles();
        string selfPath = Application.ExecutablePath;
        byte[] bytes = File.ReadAllBytes(selfPath);
        // Convert to string for marker search (ASCII portion is enough)
        string content = System.Text.Encoding.UTF8.GetString(
            bytes, 0, Math.Min(bytes.Length, 2 * 1024 * 1024));

        string psBegin = "___PS_WIZARD_BEGIN___";
        string psEnd = "___PS_WIZARD_END___";
        int s = content.LastIndexOf(psBegin);
        int e = content.LastIndexOf(psEnd);
        if (s < 0 || e < 0) {
            MessageBox.Show("Installer data not found.", "Error",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string ps1 = content.Substring(s + psBegin.Length, e - s - psBegin.Length);

        string tempPs1 = Path.Combine(Path.GetTempPath(),
            "odoo_wizard_" + Path.GetRandomFileName().Replace(".", "") + ".ps1");
        File.WriteAllText(tempPs1, ps1, System.Text.Encoding.UTF8);

        // Self-elevate if needed
        bool isAdmin = false;
        try {
            using (var id = System.Security.Principal.WindowsIdentity.GetCurrent()) {
                var principal = new System.Security.Principal.WindowsPrincipal(id);
                isAdmin = principal.IsInRole(
                    System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
        } catch {}

        if (!isAdmin) {
            // Re-launch self elevated, then exit
            var psi = new ProcessStartInfo {
                FileName = selfPath,
                Verb = "runas",
                UseShellExecute = true
            };
            try {
                Process.Start(psi);
            } catch {
                // User declined UAC — run non-elevated (may fail for some steps)
                _RunPs(tempPs1, selfPath);
            }
            return;
        }

        _RunPs(tempPs1, selfPath);
    }

    static void _RunPs(string tempPs1, string selfPath) {
        var psi = new ProcessStartInfo {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + tempPs1 + "\" -InstallerPath \"" + selfPath + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        try {
            var proc = Process.Start(psi);
            proc.WaitForExit();
        } catch (Exception ex) {
            MessageBox.Show("Failed to run installer: " + ex.Message, "Error",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        } finally {
            try { File.Delete(tempPs1); } catch {}
        }
    }
}
'''

# PowerShell wizard — embedded in the .exe, handles all UI + install logic.
# Detects system dark/light theme and adapts colors.
PS_WIZARD = r'''# PowerShell WinForms wizard for Odoo Attendance installer/uninstaller.
param([string]$InstallerPath)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── Detect system theme ────────────────────────────────────────────────────
$lightTheme = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue
$isDark = $lightTheme.AppsUseLightTheme -eq 0

if ($isDark) {
    $clrPrimary = [System.Drawing.Color]::FromArgb(59, 130, 246)
    $clrPrimaryHov = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $clrBg = [System.Drawing.Color]::FromArgb(30, 30, 46)
    $clrSurface = [System.Drawing.Color]::FromArgb(43, 43, 60)
    $clrSurfaceAlt = [System.Drawing.Color]::FromArgb(53, 53, 72)
    $clrText = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $clrTextSec = [System.Drawing.Color]::FromArgb(156, 163, 175)
    $clrBorder = [System.Drawing.Color]::FromArgb(63, 63, 90)
    $clrDivider = [System.Drawing.Color]::FromArgb(53, 53, 72)
    $clrSuccess = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $clrError = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $clrWarning = [System.Drawing.Color]::FromArgb(245, 158, 11)
    $clrInputBg = [System.Drawing.Color]::FromArgb(53, 53, 72)
    $clrInputBorder = [System.Drawing.Color]::FromArgb(74, 74, 99)
} else {
    $clrPrimary = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $clrPrimaryHov = [System.Drawing.Color]::FromArgb(29, 78, 216)
    $clrBg = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $clrSurface = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $clrSurfaceAlt = [System.Drawing.Color]::FromArgb(238, 240, 242)
    $clrText = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $clrTextSec = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $clrBorder = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $clrDivider = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $clrSuccess = [System.Drawing.Color]::FromArgb(22, 163, 74)
    $clrError = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $clrWarning = [System.Drawing.Color]::FromArgb(217, 119, 6)
    $clrInputBg = [System.Drawing.Color]::FromArgb(255, 255, 255)
    $clrInputBorder = [System.Drawing.Color]::FromArgb(209, 213, 219)
}

$fontBody = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBodyB = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$fontTitle = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$fontSubtitle = New-Object System.Drawing.Font("Segoe UI", 10)
$fontSmall = New-Object System.Drawing.Font("Segoe UI", 8)
$fontSection = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font("Cascadia Mono", 8)
if (-not (Test-Path "C:\Windows\Fonts\CascadiaMono.ttf")) {
    $fontMono = New-Object System.Drawing.Font("Consolas", 8)
}

$defaultDir = Join-Path $env:USERPROFILE "OdooAttendance"
$markerFile = Join-Path $env:LOCALAPPDATA "OdooAttendance\install_location.txt"
$taskName = "OdooAttendance"

function Get-InstallDir() {
    if (Test-Path $markerFile) {
        $dir = (Get-Content $markerFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        if ($dir -and (Test-Path (Join-Path $dir "conf\fichaje.py"))) { return $dir }
    }
    if (Test-Path (Join-Path $defaultDir "conf\fichaje.py")) { return $defaultDir }
    return $null
}

function Extract-Payload($confDir) {
    $content = Get-Content -Raw -LiteralPath $InstallerPath
    $s = $content.LastIndexOf('___ODOO_PAYLOAD_BEGIN___')
    $e = $content.LastIndexOf('___ODOO_PAYLOAD_END___')
    if ($s -lt 0 -or $e -lt 0) { throw "Payload no encontrado" }
    $b64 = $content.Substring($s + 25, $e - $s - 25) -replace '\s',''
    $bytes = [Convert]::FromBase64String($b64)
    $tmp = Join-Path $env:TEMP "odoo_payload.tar.gz"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    if (-not (Test-Path $confDir)) { New-Item -ItemType Directory -Path $confDir -Force | Out-Null }
    & tar xzf $tmp -C $confDir 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Error al extraer tar.gz" }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

function Find-Python() {
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($py -and $py -notmatch 'WindowsApps') {
        try { & $py --version 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { return $py } } catch {}
    }
    $pyLa = (Get-Command py -ErrorAction SilentlyContinue).Source
    if ($pyLa) {
        try { $exe = & py -3 -c "import sys;print(sys.executable)" 2>$null; if ($exe -and (Test-Path $exe)) { return $exe } } catch {}
    }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python311\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python310\python.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try { & $c --version 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { return $c } } catch {}
        }
    }
    return $null
}

function Install-Python() {
    & winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
    $py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    if (Test-Path $py) { return $py }
    $py = "$env:ProgramFiles\Python312\python.exe"
    if (Test-Path $py) { return $py }
    throw "No se pudo instalar Python"
}

function Do-Install($targetDir, $createShortcut, $progressBar, $statusLabel, $logBox, $preserveConfig) {
    $confDir = Join-Path $targetDir "conf"
    $configToml = Join-Path $confDir "config.toml"
    $backupConfig = $null

    $steps = @(
        @{ Label = "Extrayendo ficheros..."; Action = {
            if ($preserveConfig -and (Test-Path $configToml)) {
                $backupConfig = Join-Path $env:TEMP "odoo_config_backup_$(Get-Random).toml"
                Copy-Item $configToml $backupConfig
            }
            Extract-Payload $confDir
            if ($backupConfig -and (Test-Path $backupConfig)) {
                Copy-Item $backupConfig $configToml -Force
                Remove-Item $backupConfig -Force
            }
        } },
        @{ Label = "Buscando Python..."; Action = { $script:py = Find-Python; if (-not $script:py) { $script:py = Install-Python } } },
        @{ Label = "Creando entorno virtual..."; Action = {
            $venvPy = Join-Path $confDir ".venv\Scripts\python.exe"
            if (-not (Test-Path $venvPy)) {
                & $script:py -m venv (Join-Path $confDir ".venv") 2>&1 | Out-Null
                if (-not (Test-Path $venvPy)) { throw "No se pudo crear el venv" }
            }
        } },
        @{ Label = "Instalando dependencias..."; Action = {
            $vp = Join-Path $confDir ".venv\Scripts\python.exe"
            & $vp -m pip install --upgrade pip 2>&1 | Out-Null
            & $vp -m pip install -r (Join-Path $confDir "requirements.txt") 2>&1 | Out-Null
        } },
        @{ Label = "Creando accesos directos..."; Action = {
            $venvPyw = Join-Path $confDir ".venv\Scripts\pythonw.exe"
            $guiScript = Join-Path $confDir "config_gui.py"
            if ($createShortcut) {
                $lnk = Join-Path $env:USERPROFILE "Desktop\Configurar Fichaje Odoo.lnk"
                $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
                $s.TargetPath = $venvPyw
                $s.Arguments = "`"$guiScript`""
                $s.WorkingDirectory = $confDir
                $s.IconLocation = "$venvPyw,0"
                $s.Description = "Configurar Odoo Attendance"
                $s.Save()
            }
        } },
        @{ Label = "Registrando tarea programada..."; Action = {
            schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
            $xml = Join-Path $env:TEMP "_odoo_task.xml"
            $venvPyw = Join-Path $confDir ".venv\Scripts\pythonw.exe"
            $fichaje = Join-Path $confDir "fichaje.py"
            @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
  </Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled><Hidden>false</Hidden><ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
  </Settings>
  <Actions><Exec><Command>$venvPyw</Command><Arguments>"$fichaje"</Arguments><WorkingDirectory>$confDir</WorkingDirectory></Exec></Actions>
</Task>
"@ | Set-Content $xml -Encoding Unicode
            schtasks /Create /TN $taskName /XML $xml /F 2>&1 | Out-Null
            Remove-Item $xml -Force -ErrorAction SilentlyContinue
        } },
        @{ Label = "Finalizando..."; Action = {
            $markerDir = Split-Path $markerFile
            if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
            Set-Content $markerFile $targetDir -Encoding UTF8
        } }
    )
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $statusLabel.Text = $step.Label
        $logBox.AppendText("[$($i+1)/$($steps.Count)] $($step.Label)`r`n")
        [System.Windows.Forms.Application]::DoEvents()
        try {
            & $step.Action
            $logBox.AppendText("  OK`r`n")
        } catch {
            $logBox.AppendText("  ERROR: $_`r`n")
            throw $_
        }
        $progressBar.Value = [int](($i + 1) / $steps.Count * 100)
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Do-Uninstall($targetDir, $progressBar, $statusLabel, $logBox) {
    $steps = @(
        @{ Label = "Eliminando tarea programada..."; Action = { schtasks /Delete /TN $taskName /F 2>&1 | Out-Null } },
        @{ Label = "Eliminando acceso directo..."; Action = { Remove-Item (Join-Path $env:USERPROFILE "Desktop\Configurar Fichaje Odoo.lnk") -Force -ErrorAction SilentlyContinue } },
        @{ Label = "Eliminando directorio..."; Action = { if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue } } },
        @{ Label = "Limpiando registro..."; Action = { Remove-Item $markerFile -Force -ErrorAction SilentlyContinue } }
    )
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $step = $steps[$i]
        $statusLabel.Text = $step.Label
        $logBox.AppendText("[$($i+1)/$($steps.Count)] $($step.Label)`r`n")
        [System.Windows.Forms.Application]::DoEvents()
        & $step.Action
        $logBox.AppendText("  OK`r`n")
        $progressBar.Value = [int](($i + 1) / $steps.Count * 100)
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ── Styled button helper ───────────────────────────────────────────────────
function New-Button($text, $x, $y, $w, $h, $isPrimary) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Location = New-Object System.Drawing.Point($x, $y)
    $btn.Size = New-Object System.Drawing.Size($w, $h)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = if ($isPrimary) { 0 } else { 1 }
    $btn.FlatAppearance.BorderColor = $clrBorder
    $btn.Font = if ($isPrimary) { $fontBodyB } else { $fontBody }
    if ($isPrimary) {
        $btn.BackColor = $clrPrimary
        $btn.ForeColor = [System.Drawing.Color]::White
    } else {
        $btn.BackColor = $clrSurface
        $btn.ForeColor = $clrText
    }
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

# ── Main form ──────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = "Odoo Attendance - Instalador  v___VERSION___"
$form.Size = New-Object System.Drawing.Size(560, 600)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = $fontBody
$form.BackColor = $clrBg

# ── Header ─────────────────────────────────────────────────────────────────
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(560, 80)
$headerPanel.BackColor = $clrSurface
$form.Controls.Add($headerPanel)

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(0, 78)
$accentBar.Size = New-Object System.Drawing.Size(560, 2)
$accentBar.BackColor = $clrPrimary
$form.Controls.Add($accentBar)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Odoo Attendance"
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = $clrPrimary
$titleLabel.Location = New-Object System.Drawing.Point(24, 16)
$titleLabel.Size = New-Object System.Drawing.Size(300, 32)
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Automatizacion de fichaje en Odoo"
$subtitleLabel.Font = $fontSubtitle
$subtitleLabel.ForeColor = $clrTextSec
$subtitleLabel.Location = New-Object System.Drawing.Point(24, 48)
$subtitleLabel.Size = New-Object System.Drawing.Size(400, 22)
$headerPanel.Controls.Add($subtitleLabel)

# ── Content ────────────────────────────────────────────────────────────────
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(24, 96)
$contentPanel.Size = New-Object System.Drawing.Size(512, 380)
$contentPanel.BackColor = $clrBg
$form.Controls.Add($contentPanel)

# ── Launch checkbox ────────────────────────────────────────────────────────
$cbLaunch = New-Object System.Windows.Forms.CheckBox
$cbLaunch.Text = "Abrir 'Configurar Fichaje Odoo' al cerrar"
$cbLaunch.Location = New-Object System.Drawing.Point(24, 486)
$cbLaunch.Size = New-Object System.Drawing.Size(300, 24)
$cbLaunch.Font = $fontBody
$cbLaunch.Checked = $true
$cbLaunch.Visible = $false
$cbLaunch.BackColor = $clrBg
$cbLaunch.ForeColor = $clrText
$form.Controls.Add($cbLaunch)

# ── Footer buttons ─────────────────────────────────────────────────────────
$btnBack = New-Button "< Atras" 24 530 90 30 $false
$btnBack.Visible = $false
$form.Controls.Add($btnBack)

$btnCancel = New-Button "Cancelar" 350 530 90 30 $false
$form.Controls.Add($btnCancel)

$btnNext = New-Button "Siguiente >" 446 530 90 30 $true
$form.Controls.Add($btnNext)

$script:page = 0
$script:mode = "install"
$script:targetDir = $defaultDir
$script:createShortcut = $true
$script:py = $null
$script:preserveConfig = $false
$script:installSuccess = $false
$existingDir = Get-InstallDir

function Clear-Content() { $contentPanel.Controls.Clear() }

function Add-Label($text, $x, $y, $w, $h, $font, $color) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.Size = New-Object System.Drawing.Size($w, $h)
    $lbl.Font = $font
    $lbl.ForeColor = $color
    $lbl.BackColor = $clrBg
    $contentPanel.Controls.Add($lbl)
    return $lbl
}

function Show-Welcome() {
    Clear-Content
    Add-Label "Bienvenido al asistente de instalacion" 0 10 512 28 $fontSection $clrText
    Add-Label @"
Este asistente te ayudara a instalar Odoo Attendance.

La aplicacion fichara automaticamente en Odoo cada vez que desbloquees
el PC, preguntandote antes si quieres hacerlo. Podras configurar
credenciales y horarios desde una interfaz grafica.

Haz clic en Siguiente para continuar.
"@ 0 50 512 160 $fontBody $clrText
    $btnBack.Visible = $false
    $btnNext.Text = "Siguiente >"
    $btnNext.Enabled = $true
}

function Show-Welcome-Installed() {
    Clear-Content
    Add-Label "Odoo Attendance ya esta instalado" 0 10 512 28 $fontSection $clrText
    Add-Label @"
Directorio de instalacion:

$existingDir

Que deseas hacer?
"@ 0 50 512 90 $fontBody $clrText

    $rbUpdate = New-Object System.Windows.Forms.RadioButton
    $rbUpdate.Text = "Actualizar (conserva configuracion, credenciales y horarios)"
    $rbUpdate.Location = New-Object System.Drawing.Point(20, 150)
    $rbUpdate.Size = New-Object System.Drawing.Size(480, 28)
    $rbUpdate.Checked = $true
    $rbUpdate.Font = $fontBody
    $rbUpdate.ForeColor = $clrText
    $rbUpdate.BackColor = $clrBg
    $contentPanel.Controls.Add($rbUpdate)

    $rbReinstall = New-Object System.Windows.Forms.RadioButton
    $rbReinstall.Text = "Reinstalar (borra configuracion, empieza de cero)"
    $rbReinstall.Location = New-Object System.Drawing.Point(20, 184)
    $rbReinstall.Size = New-Object System.Drawing.Size(480, 28)
    $rbReinstall.Font = $fontBody
    $rbReinstall.ForeColor = $clrText
    $rbReinstall.BackColor = $clrBg
    $contentPanel.Controls.Add($rbReinstall)

    $rbUninstall = New-Object System.Windows.Forms.RadioButton
    $rbUninstall.Text = "Desinstalar"
    $rbUninstall.Location = New-Object System.Drawing.Point(20, 218)
    $rbUninstall.Size = New-Object System.Drawing.Size(300, 28)
    $rbUninstall.Font = $fontBody
    $rbUninstall.ForeColor = $clrText
    $rbUninstall.BackColor = $clrBg
    $contentPanel.Controls.Add($rbUninstall)

    $script:rbUpdate = $rbUpdate
    $script:rbReinstall = $rbReinstall
    $script:rbUninstall = $rbUninstall
    $btnBack.Visible = $false
    $btnNext.Text = "Siguiente >"
    $btnNext.Enabled = $true
}

function Show-Directory() {
    Clear-Content
    Add-Label "Directorio de instalacion" 0 10 512 28 $fontSection $clrText
    Add-Label "Selecciona donde instalar la aplicacion:" 0 44 512 20 $fontBody $clrText

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $script:targetDir
    $txt.Location = New-Object System.Drawing.Point(0, 70)
    $txt.Size = New-Object System.Drawing.Size(410, 26)
    $txt.Font = $fontBody
    $txt.BackColor = $clrInputBg
    $txt.ForeColor = $clrText
    $txt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $contentPanel.Controls.Add($txt)

    $browse = New-Button "Examinar..." 418 68 90 28 $false
    $browse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $txt.Text
        if ($dlg.ShowDialog() -eq "OK") { $txt.Text = $dlg.SelectedPath }
    })
    $contentPanel.Controls.Add($browse)

    Add-Label "El directorio se creara si no existe." 0 104 512 20 $fontSmall $clrTextSec

    $cbShortcut = New-Object System.Windows.Forms.CheckBox
    $cbShortcut.Text = "Crear acceso directo en el Escritorio"
    $cbShortcut.Location = New-Object System.Drawing.Point(0, 136)
    $cbShortcut.Size = New-Object System.Drawing.Size(300, 26)
    $cbShortcut.Checked = $true
    $cbShortcut.Font = $fontBody
    $cbShortcut.ForeColor = $clrText
    $cbShortcut.BackColor = $clrBg
    $contentPanel.Controls.Add($cbShortcut)

    $script:dirTextBox = $txt
    $script:shortcutCheckBox = $cbShortcut
    $btnBack.Visible = $true
    $btnNext.Text = "Instalar >"
    $btnNext.Enabled = $true
}

function Show-Uninstall-Confirm() {
    Clear-Content
    Add-Label "Confirmar desinstalacion" 0 10 512 28 $fontSection $clrError
    Add-Label @"
Se va a DESINSTALAR Odoo Attendance.

Esto eliminara:
  - La tarea programada (dialogo al desbloquear)
  - El acceso directo del Escritorio
  - El directorio: $existingDir
    (incluyendo config.toml, .venv, .markers y logs)

Tu configuracion se perdera. Si quieres conservarla, copia
config.toml antes de continuar.

Haz clic en Desinstalar para continuar.
"@ 0 50 512 220 $fontBody $clrText
    $btnBack.Visible = $true
    $btnNext.Text = "Desinstalar >"
    $btnNext.Enabled = $true
}

function Show-Progress() {
    Clear-Content

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Iniciando..."
    $statusLabel.Location = New-Object System.Drawing.Point(0, 10)
    $statusLabel.Size = New-Object System.Drawing.Size(512, 24)
    $statusLabel.Font = $fontBodyB
    $statusLabel.ForeColor = $clrText
    $statusLabel.BackColor = $clrBg
    $contentPanel.Controls.Add($statusLabel)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(0, 40)
    $progressBar.Size = New-Object System.Drawing.Size(512, 22)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $contentPanel.Controls.Add($progressBar)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly = $true
    $logBox.Location = New-Object System.Drawing.Point(0, 75)
    $logBox.Size = New-Object System.Drawing.Size(512, 290)
    $logBox.Font = $fontMono
    $logBox.BackColor = $clrSurface
    $logBox.ForeColor = $clrText
    $logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $contentPanel.Controls.Add($logBox)

    $btnBack.Visible = $false
    $btnNext.Visible = $false
    $btnCancel.Text = "Cerrar"
    $btnCancel.Enabled = $false
    $cbLaunch.Visible = $false
    [System.Windows.Forms.Application]::DoEvents()

    try {
        if ($script:mode -eq "install") {
            Do-Install $script:targetDir $script:createShortcut $progressBar $statusLabel $logBox $script:preserveConfig
            $statusLabel.Text = "Instalacion completada."
            $statusLabel.ForeColor = $clrSuccess
            $logBox.AppendText("`r`n=== INSTALACION COMPLETA ===`r`n")
            $logBox.AppendText("Directorio: $($script:targetDir)`r`n")
            $script:installSuccess = $true
        } else {
            Do-Uninstall $existingDir $progressBar $statusLabel $logBox
            $statusLabel.Text = "Desinstalacion completada."
            $statusLabel.ForeColor = $clrSuccess
            $logBox.AppendText("`r`n=== DESINSTALACION COMPLETA ===`r`n")
        }
        $progressBar.Value = 100
    } catch {
        $statusLabel.Text = "Error: $_"
        $statusLabel.ForeColor = $clrError
        $logBox.AppendText("`r`n=== ERROR ===`r`n$_`r`n")
        $progressBar.Value = 0
    }
    if ($script:installSuccess -and $script:mode -eq "install") {
        $cbLaunch.Visible = $true
    }
    $btnCancel.Enabled = $true
    $btnCancel.Text = "Cerrar"
}

$btnNext.Add_Click({
    switch ($script:page) {
        0 {
            if ($existingDir) {
                if ($script:rbUninstall.Checked) {
                    $script:mode = "uninstall"
                    $script:page = 2
                    Show-Uninstall-Confirm
                } else {
                    $script:mode = "install"
                    $script:targetDir = $existingDir
                    $script:preserveConfig = (-not $script:rbReinstall.Checked)
                    $script:page = 1
                    Show-Directory
                }
            } else {
                $script:page = 1
                Show-Directory
            }
        }
        1 {
            $script:targetDir = $script:dirTextBox.Text.Trim()
            if (-not $script:targetDir) {
                [System.Windows.Forms.MessageBox]::Show("Selecciona un directorio.", "Aviso", 0, 48)
                return
            }
            $script:createShortcut = $script:shortcutCheckBox.Checked
            $script:page = 3
            Show-Progress
        }
        2 { $script:page = 3; Show-Progress }
    }
})

$btnBack.Add_Click({
    switch ($script:page) {
        1 { $script:page = 0; if ($existingDir) { Show-Welcome-Installed } else { Show-Welcome } }
        2 { $script:page = 0; Show-Welcome-Installed }
    }
})

$btnCancel.Add_Click({
    if ($script:installSuccess -and $script:mode -eq "install" -and $cbLaunch.Checked) {
        $venvPyw = Join-Path $script:targetDir "conf\.venv\Scripts\pythonw.exe"
        $guiScript = Join-Path $script:targetDir "conf\config_gui.py"
        if (Test-Path $venvPyw) {
            Start-Process -FilePath $venvPyw -ArgumentList "`"$guiScript`"" -WorkingDirectory (Join-Path $script:targetDir "conf")
        }
    }
    $form.Close()
})

if ($existingDir) { Show-Welcome-Installed } else { Show-Welcome }
$form.ShowDialog() | Out-Null
$form.Dispose()
___PS_WIZARD_END___

___ODOO_PAYLOAD_BEGIN___
__PAYLOAD__
___ODOO_PAYLOAD_END___'''

# =========================================================================
# Linux installer
# =========================================================================
LINUX_TEMPLATE = r'''#!/usr/bin/env bash
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
    CHOICE=$(zenity --forms --title="Odoo Attendance - Instalador  v___VERSION___" \
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
__PAYLOAD__
___ODOO_PAYLOAD_END___
'''


def _find_csc() -> str | None:
    """Find the C# compiler (csc.exe) on Windows."""
    import glob
    # Check .NET Framework paths
    candidates = sorted(glob.glob(
        r"C:\Windows\Microsoft.NET\Framework64\v*\csc.exe"), reverse=True)
    for c in candidates:
        if Path(c).exists():
            return c
    candidates = sorted(glob.glob(
        r"C:\Windows\Microsoft.NET\Framework\v*\csc.exe"), reverse=True)
    for c in candidates:
        if Path(c).exists():
            return c
    return None


def _generate_bat_fallback(installer_dir, ps_with_payload: str, version: str) -> None:
    """Generate a .bat installer as fallback when csc.exe is not available."""
    bat = f'''@echo off
setlocal enabledelayedexpansion
set "SELF=%~f0"
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process cmd -ArgumentList '/c \\"\\"%SELF%\\"\\"' -Verb RunAs -WindowStyle Hidden"
    exit /b 0
)
set "PS1=%TEMP%\\odoo_wizard_%RANDOM%.ps1"
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
  "$bat = Get-Content -Raw -LiteralPath '%SELF%';" ^
  "$s = $bat.LastIndexOf('___PS_WIZARD_BEGIN___') + 21;" ^
  "$e = $bat.LastIndexOf('___PS_WIZARD_END___');" ^
  "$ps = $bat.Substring($s, $e - $s);" ^
  "[IO.File]::WriteAllText('%PS1%', $ps, [Text.Encoding]::UTF8);"
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%PS1%" -InstallerPath "%SELF%"
set "RC=%ERRORLEVEL%"
del "%PS1%" 2>nul
exit /b %RC%

___PS_WIZARD_BEGIN___
{ps_with_payload}
'''
    path = installer_dir / "instalador_windows.bat"
    path.write_text(bat, encoding="utf-8")
    print(f"  {path}  ({len(bat):,} bytes)")


def main() -> None:
    payload = build_payload()
    lines = [payload[i:i+76] for i in range(0, len(payload), 76)]
    payload_text = "\n".join(lines)

    INSTALLER_DIR.mkdir(exist_ok=True)

    # Build the embedded PowerShell + payload content
    ps_with_payload = PS_WIZARD.replace("__PAYLOAD__", payload_text)
    ps_with_payload = ps_with_payload.replace("___VERSION___", _VERSION)

    # ── Linux installer (.sh) ──
    linux = LINUX_TEMPLATE.replace("__PAYLOAD__", payload_text)
    linux = linux.replace("___VERSION___", _VERSION)
    (INSTALLER_DIR / "instalador_linux.sh").write_text(linux, encoding="utf-8")

    # ── Windows installer (.exe) ──
    exe_path = INSTALLER_DIR / "instalador_windows.exe"
    cs_path = INSTALLER_DIR / "_launcher.cs"

    # Write the C# launcher source
    cs_source = CS_LAUNCHER.replace("___VERSION___", _VERSION)
    cs_path.write_text(cs_source, encoding="utf-8")

    # Always keep a .bat fallback alongside the .exe
    _generate_bat_fallback(INSTALLER_DIR, ps_with_payload, _VERSION)

    csc = _find_csc()
    if csc:
        # Compile to a temporary exe
        tmp_exe = INSTALLER_DIR / "_launcher_tmp.exe"
        cmd = [
            csc, "/nologo", "/noconfig",
            "/target:winexe",  # GUI app — no console
            "/optimize+",
            "/r:System.Windows.Forms.dll",
            "/r:System.Drawing.dll",
            "/r:System.Security.dll",
            "/r:System.dll",
            f"/out:{tmp_exe}",
            str(cs_path),
        ]
        print(f"Compilando con: {csc}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print("ERROR de compilacion C#:")
            print("STDOUT:", result.stdout)
            print("STDERR:", result.stderr)
        else:
            # Append the PowerShell + payload to the exe
            # The C# launcher reads its own file and searches for markers
            with open(tmp_exe, "ab") as fh:
                fh.write(b"\r\n___PS_WIZARD_BEGIN___\r\n")
                fh.write(ps_with_payload.encode("utf-8"))
                fh.write(b"\r\n")
            # Move to final name
            tmp_exe.replace(exe_path)
            # Clean up
            cs_path.unlink(missing_ok=True)
            print(f"Generados:")
            print(f"  {exe_path}  ({exe_path.stat().st_size:,} bytes)")
    else:
        print("ADVERTENCIA: csc.exe no encontrado. Solo .bat generado.")

    print(f"  {INSTALLER_DIR / 'instalador_linux.sh'}  ({len(linux):,} bytes)")
    print(f"  Payload: {len(payload):,} chars base64 ({len(lines)} lineas)")


if __name__ == "__main__":
    main()
