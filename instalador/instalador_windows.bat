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
8fP4efw8fh4/D/35/wGLZT3yALgBAA==
___ODOO_PAYLOAD_END___
