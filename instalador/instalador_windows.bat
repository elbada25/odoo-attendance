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
6PuZTwDgAQA=
___ODOO_PAYLOAD_END___
