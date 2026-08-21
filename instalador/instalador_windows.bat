@echo off
REM ===========================================================================
REM  instalador_windows.bat  -  Instalador autocontenido con wizard (Windows)
REM  Un solo fichero. Doble-click para instalar o desinstalar.
REM  Se autoeleva con UAC cuando lo necesita.
REM ===========================================================================
setlocal enabledelayedexpansion
set "SELF=%~f0"

net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%SELF%\"\"' -Verb RunAs"
    exit /b 0
)

set "PS1=%TEMP%\odoo_wizard_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$bat = Get-Content -Raw -LiteralPath '%SELF%';" ^
  "$s = $bat.LastIndexOf('___PS_WIZARD_BEGIN___') + 21;" ^
  "$e = $bat.LastIndexOf('___PS_WIZARD_END___');" ^
  "$ps = $bat.Substring($s, $e - $s);" ^
  "[IO.File]::WriteAllText('%PS1%', $ps, [Text.Encoding]::UTF8);"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -InstallerPath "%SELF%"
set "RC=%ERRORLEVEL%"
del "%PS1%" 2>nul
exit /b %RC%

___PS_WIZARD_BEGIN___
# PowerShell WinForms wizard for Odoo Attendance installer/uninstaller.
param([string]$InstallerPath)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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
    # Try 'python' on PATH, but EXCLUDE the Windows Store stub
    $py = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($py -and $py -notmatch 'WindowsApps') {
        try { & $py --version 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { return $py } } catch {}
    }
    # Try 'py' launcher
    $pyLa = (Get-Command py -ErrorAction SilentlyContinue).Source
    if ($pyLa) {
        try { $exe = & py -3 -c "import sys;print(sys.executable)" 2>$null; if ($exe -and (Test-Path $exe)) { return $exe } } catch {}
    }
    # Try common install locations
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
        @{ Label = "Extrayendo ficheros del proyecto..."; Action = {
            # Backup existing config if preserving
            if ($preserveConfig -and (Test-Path $configToml)) {
                $backupConfig = Join-Path $env:TEMP "odoo_config_backup_$(Get-Random).toml"
                Copy-Item $configToml $backupConfig
                $logBox.AppendText("  Configuracion anterior respaldada.`r`n")
            }
            Extract-Payload $confDir
            # Restore config after extraction
            if ($backupConfig -and (Test-Path $backupConfig)) {
                Copy-Item $backupConfig $configToml -Force
                Remove-Item $backupConfig -Force
                $logBox.AppendText("  Configuracion anterior restaurada.`r`n")
            }
        } },
        @{ Label = "Buscando Python..."; Action = { $script:py = Find-Python; if (-not $script:py) { $script:py = Install-Python } } },
        @{ Label = "Creando entorno virtual..."; Action = {
            $venvPy = Join-Path $confDir ".venv\Scripts\python.exe"
            if (-not (Test-Path $venvPy)) {
                & $script:py -m venv (Join-Path $confDir ".venv") 2>&1 | Out-Null
                if (-not (Test-Path $venvPy)) {
                    throw "No se pudo crear el entorno virtual con Python: $($script:py)"
                }
            }
        } },
        @{ Label = "Instalando dependencias..."; Action = {
            $vp = Join-Path $confDir ".venv\Scripts\python.exe"
            if (-not (Test-Path $vp)) { throw "No se encontro python.exe en el venv" }
            & $vp -m pip install --upgrade pip 2>&1 | Out-Null
            & $vp -m pip install -r (Join-Path $confDir "requirements.txt") 2>&1 | Out-Null
        } },
        @{ Label = "Creando accesos directos..."; Action = {
            # Top-level launcher bat
            $launcher = Join-Path $targetDir "Configurar Fichaje Odoo.bat"
            $venvPyw = Join-Path $confDir ".venv\Scripts\pythonw.exe"
            $guiScript = Join-Path $confDir "config_gui.py"
            @"
@echo off
"$venvPyw" "$guiScript"
"@ | Set-Content $launcher -Encoding UTF8

            # Top-level uninstaller bat
            $uninstaller = Join-Path $targetDir "Desinstalar.bat"
            @"
@echo off
setlocal
set "SELF=%~f0"
set "TARGET_DIR=%~dp0"
set "TARGET_DIR=%TARGET_DIR:~0,-1%"
set TASK_NAME=OdooAttendance
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%SELF%\"\"' -Verb RunAs"
    exit /b 0
)
echo Eliminando tarea programada...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1
echo Eliminando acceso directo del escritorio...
del /q "%USERPROFILE%\Desktop\Configurar Fichaje Odoo.lnk" 2>nul
echo Limpiando registro...
rd /s /q "%LOCALAPPDATA%\OdooAttendance" 2>nul
echo Eliminando directorio de instalacion...
cd /d "%USERPROFILE%"
rd /s /q "%TARGET_DIR%" 2>nul
echo.
echo Desinstalacion completada.
pause
endlocal
"@ | Set-Content $uninstaller -Encoding UTF8

            # Desktop shortcut (if requested)
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
        @{ Label = "Guardando informacion de instalacion..."; Action = {
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
        @{ Label = "Eliminando directorio de instalacion..."; Action = { if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force -ErrorAction SilentlyContinue } } },
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

# ---- Wizard form ----
$form = New-Object System.Windows.Forms.Form
$form.Text = "Odoo Attendance - Instalador  v1.0.0"
$form.Size = New-Object System.Drawing.Size(540, 480)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Odoo Attendance"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(20, 15)
$titleLabel.Size = New-Object System.Drawing.Size(500, 30)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Automatizacion de fichaje en Odoo"
$subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$subtitleLabel.ForeColor = [System.Drawing.Color]::Gray
$subtitleLabel.Location = New-Object System.Drawing.Point(20, 45)
$subtitleLabel.Size = New-Object System.Drawing.Size(500, 20)
$form.Controls.Add($subtitleLabel)

$sep = New-Object System.Windows.Forms.Label
$sep.Location = New-Object System.Drawing.Point(20, 75)
$sep.Size = New-Object System.Drawing.Size(500, 2)
$sep.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$form.Controls.Add($sep)

$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(20, 85)
$contentPanel.Size = New-Object System.Drawing.Size(500, 320)
$form.Controls.Add($contentPanel)

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Text = "< Atras"
$btnBack.Location = New-Object System.Drawing.Point(20, 415)
$btnBack.Size = New-Object System.Drawing.Size(90, 28)
$btnBack.Visible = $false
$form.Controls.Add($btnBack)

$btnNext = New-Object System.Windows.Forms.Button
$btnNext.Text = "Siguiente >"
$btnNext.Location = New-Object System.Drawing.Point(430, 415)
$btnNext.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnNext)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancelar"
$btnCancel.Location = New-Object System.Drawing.Point(335, 415)
$btnCancel.Size = New-Object System.Drawing.Size(90, 28)
$form.Controls.Add($btnCancel)

$script:page = 0
$script:mode = "install"
$script:targetDir = $defaultDir
$script:createShortcut = $true
$script:py = $null
$script:preserveConfig = $false
$existingDir = Get-InstallDir

function Clear-Content() { $contentPanel.Controls.Clear() }

function Show-Welcome() {
    Clear-Content
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(0, 10)
    $lbl.Size = New-Object System.Drawing.Size(500, 200)
    $lbl.Text = @"
Este asistente te ayudara a instalar Odoo Attendance.

La aplicacion fichara automaticamente en Odoo cada vez que desbloquees el PC,
preguntandote antes si quieres hacerlo. Podras configurar credenciales y
horarios desde una interfaz grafica.

Haz clic en Siguiente para continuar.
"@
    $contentPanel.Controls.Add($lbl)
    $btnBack.Visible = $false
    $btnNext.Text = "Siguiente >"
    $btnNext.Enabled = $true
}

function Show-Welcome-Installed() {
    Clear-Content
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(0, 10)
    $lbl.Size = New-Object System.Drawing.Size(500, 120)
    $lbl.Text = @"
Odoo Attendance ya esta instalado en:

$existingDir

Que deseas hacer?
"@
    $contentPanel.Controls.Add($lbl)
    $rbUpdate = New-Object System.Windows.Forms.RadioButton
    $rbUpdate.Text = "Actualizar (conserva configuracion, credenciales y horarios)"
    $rbUpdate.Location = New-Object System.Drawing.Point(20, 130)
    $rbUpdate.Size = New-Object System.Drawing.Size(460, 24)
    $rbUpdate.Checked = $true
    $contentPanel.Controls.Add($rbUpdate)
    $rbReinstall = New-Object System.Windows.Forms.RadioButton
    $rbReinstall.Text = "Reinstalar (borra configuracion, empieza de cero)"
    $rbReinstall.Location = New-Object System.Drawing.Point(20, 160)
    $rbReinstall.Size = New-Object System.Drawing.Size(460, 24)
    $contentPanel.Controls.Add($rbReinstall)
    $rbUninstall = New-Object System.Windows.Forms.RadioButton
    $rbUninstall.Text = "Desinstalar"
    $rbUninstall.Location = New-Object System.Drawing.Point(20, 190)
    $rbUninstall.Size = New-Object System.Drawing.Size(300, 24)
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
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Selecciona el directorio de instalacion:"
    $lbl.Location = New-Object System.Drawing.Point(0, 10)
    $lbl.Size = New-Object System.Drawing.Size(500, 20)
    $contentPanel.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $script:targetDir
    $txt.Location = New-Object System.Drawing.Point(0, 35)
    $txt.Size = New-Object System.Drawing.Size(400, 24)
    $contentPanel.Controls.Add($txt)

    $browse = New-Object System.Windows.Forms.Button
    $browse.Text = "Examinar..."
    $browse.Location = New-Object System.Drawing.Point(410, 34)
    $browse.Size = New-Object System.Drawing.Size(85, 26)
    $browse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.SelectedPath = $txt.Text
        if ($dlg.ShowDialog() -eq "OK") { $txt.Text = $dlg.SelectedPath }
    })
    $contentPanel.Controls.Add($browse)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "El directorio se creara si no existe."
    $info.ForeColor = [System.Drawing.Color]::Gray
    $info.Location = New-Object System.Drawing.Point(0, 65)
    $info.Size = New-Object System.Drawing.Size(500, 20)
    $contentPanel.Controls.Add($info)

    # Shortcut checkbox
    $cbShortcut = New-Object System.Windows.Forms.CheckBox
    $cbShortcut.Text = "Crear acceso directo en el Escritorio"
    $cbShortcut.Location = New-Object System.Drawing.Point(0, 100)
    $cbShortcut.Size = New-Object System.Drawing.Size(300, 24)
    $cbShortcut.Checked = $true
    $contentPanel.Controls.Add($cbShortcut)

    $script:dirTextBox = $txt
    $script:shortcutCheckBox = $cbShortcut
    $btnBack.Visible = $true
    $btnNext.Text = "Instalar >"
    $btnNext.Enabled = $true
}

function Show-Uninstall-Confirm() {
    Clear-Content
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(0, 10)
    $lbl.Size = New-Object System.Drawing.Size(500, 170)
    $lbl.Text = @"
Se va a DESINSTALAR Odoo Attendance.

Esto eliminara:
  - La tarea programada (dialogo al desbloquear)
  - El acceso directo del Escritorio
  - El directorio: $existingDir
    (incluyendo config.toml, .venv, .markers y logs)

Tu configuracion se perdera. Si quieres conservarla, copia config.toml
antes de continuar.

Haz clic en Desinstalar para continuar.
"@
    $contentPanel.Controls.Add($lbl)
    $btnBack.Visible = $true
    $btnNext.Text = "Desinstalar >"
    $btnNext.Enabled = $true
}

function Show-Progress() {
    Clear-Content
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = "Iniciando..."
    $statusLabel.Location = New-Object System.Drawing.Point(0, 10)
    $statusLabel.Size = New-Object System.Drawing.Size(500, 24)
    $contentPanel.Controls.Add($statusLabel)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(0, 40)
    $progressBar.Size = New-Object System.Drawing.Size(500, 24)
    $contentPanel.Controls.Add($progressBar)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ScrollBars = "Vertical"
    $logBox.ReadOnly = $true
    $logBox.Location = New-Object System.Drawing.Point(0, 75)
    $logBox.Size = New-Object System.Drawing.Size(500, 230)
    $logBox.Font = New-Object System.Drawing.Font("Consolas", 8)
    $contentPanel.Controls.Add($logBox)

    $btnBack.Visible = $false
    $btnNext.Visible = $false
    $btnCancel.Text = "Cerrar"
    $btnCancel.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    try {
        if ($script:mode -eq "install") {
            Do-Install $script:targetDir $script:createShortcut $progressBar $statusLabel $logBox $script:preserveConfig
            $statusLabel.Text = "Instalacion completada."
            $logBox.AppendText("`r`n=== INSTALACION COMPLETA ===`r`n")
            $logBox.AppendText("Directorio: $($script:targetDir)`r`n")
            if ($script:createShortcut) {
                $logBox.AppendText("Acceso directo creado en el Escritorio.`r`n")
            }
            $logBox.AppendText("`r`nAbre 'Configurar Fichaje Odoo' para configurar tus credenciales y horarios.`r`n")
            $logBox.AppendText("Para desinstalar: ejecuta 'Desinstalar.bat' en el directorio de instalacion.`r`n")
        } else {
            Do-Uninstall $existingDir $progressBar $statusLabel $logBox
            $statusLabel.Text = "Desinstalacion completada."
            $logBox.AppendText("`r`n=== DESINSTALACION COMPLETA ===`r`n")
        }
        $progressBar.Value = 100
    } catch {
        $statusLabel.Text = "ERROR: $_"
        $logBox.AppendText("`r`n=== ERROR ===`r`n$_`r`n")
        $progressBar.Value = 0
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
                    # rbUpdate preserves config, rbReinstall wipes it
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

$btnCancel.Add_Click({ $form.Close() })

if ($existingDir) { Show-Welcome-Installed } else { Show-Welcome }
$form.ShowDialog() | Out-Null
$form.Dispose()
___PS_WIZARD_END___

___ODOO_PAYLOAD_BEGIN___
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
___ODOO_PAYLOAD_END___
