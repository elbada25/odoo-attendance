@echo off
setlocal enabledelayedexpansion
set "SELF=%~f0"
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process cmd -ArgumentList '/c \"\"%SELF%\"\"' -Verb RunAs -WindowStyle Hidden"
    exit /b 0
)
set "PS1=%TEMP%\odoo_wizard_%RANDOM%.ps1"
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
# PowerShell WinForms wizard for Odoo Attendance installer/uninstaller.
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
$form.Text = "Odoo Attendance - Instalador  v1.0.7"
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
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
___ODOO_PAYLOAD_END___
