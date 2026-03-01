#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][ValidateSet("Lock","Unlock")][string]$Action,
    [Parameter(Mandatory)][string]$AdminPassword
)

# ─── SID resolve ──────────────────────────────────────────────────────────────
$sidObj  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545")
$NTUsers = $sidObj.Translate([System.Security.Principal.NTAccount])
Write-Host "[INFO] Users group: $NTUsers" -ForegroundColor Gray

# ─── Password check ───────────────────────────────────────────────────────────
$AdminUser = (Get-LocalUser | Where-Object { $_.SID.Value -like "*-500" }).Name
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
$ctx   = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
             [System.DirectoryServices.AccountManagement.ContextType]::Machine)
$valid = $ctx.ValidateCredentials($AdminUser, $AdminPassword)
if (-not $valid) {
    Write-Host "[ERROR] Wrong password for '$AdminUser'!" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Password accepted. Mode: $Action" -ForegroundColor Green

# ─── Target user ──────────────────────────────────────────────────────────────
$TargetUser = Get-LocalUser | Where-Object {
    $_.Enabled -eq $true -and
    $_.SID.Value -notlike "*-500" -and
    $_.Name -notmatch "^(Guest|WDAGUtility|DefaultAccount)$"
} | Select-Object -First 1

$TargetUserName = $TargetUser.Name
$TargetSID      = $TargetUser.SID.Value
$TargetProfile  = "C:\Users\$TargetUserName"
$TargetNT       = (New-Object System.Security.Principal.SecurityIdentifier($TargetSID)).Translate(
                      [System.Security.Principal.NTAccount])

Write-Host "[INFO] Target user: $TargetUserName ($TargetNT)" -ForegroundColor Gray

$HKU = "Registry::HKEY_USERS\$TargetSID"

function Set-UserReg {
    param([string]$SubKey, [string]$Name, [int]$Value)
    $p = "$HKU\$SubKey"
    if (!(Test-Path $p)) { New-Item $p -Force | Out-Null }
    Set-ItemProperty $p $Name -Value $Value -Type DWord
}

function Remove-UserReg {
    param([string]$SubKey, [string]$Name)
    $p = "$HKU\$SubKey"
    if (Test-Path $p) { Remove-ItemProperty $p $Name -ErrorAction SilentlyContinue }
}

# ─── Desktop ACL ──────────────────────────────────────────────────────────────
function Set-DesktopACL {
    param([bool]$Lock)
    $paths = @("$TargetProfile\Desktop", "C:\Users\Public\Desktop")
    foreach ($p in $paths) {
        if (!(Test-Path $p)) { continue }
        $acl = Get-Acl $p
        if ($Lock) {
            $acl.SetAccessRuleProtection($true, $true)
            $allow = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $TargetNT,"ReadAndExecute,ListDirectory",
                "ContainerInherit,ObjectInherit","None","Allow")
            $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $TargetNT,"CreateFiles,CreateDirectories,Delete,DeleteSubdirectoriesAndFiles,Write",
                "ContainerInherit,ObjectInherit","None","Deny")
            $acl.AddAccessRule($allow)
            $acl.AddAccessRule($deny)
        } else {
            $acl.SetAccessRuleProtection($false, $true)
            $acl.Access | Where-Object { $_.AccessControlType -eq "Deny" } |
                ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        }
        Set-Acl $p $acl
        Write-Host "[$(if($Lock){'LOCK'}else{'UNLOCK'})] Desktop: $p" -ForegroundColor $(if($Lock){'Yellow'}else{'Cyan'})
    }
}

# ─── Wallpaper ────────────────────────────────────────────────────────────────
function Set-WallpaperLock {
    param([bool]$Lock)
    $lmPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"
    if ($Lock) {
        Set-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" "NoChangingWallPaper" 1
        Set-UserReg "Software\Policies\Microsoft\Windows\Personalization" "PreventChangingWallpaper" 1
        if (!(Test-Path $lmPath)) { New-Item $lmPath -Force | Out-Null }
        Set-ItemProperty $lmPath "NoChangingWallPaper" -Value 1 -Type DWord
    } else {
        Remove-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop" "NoChangingWallPaper"
        Remove-UserReg "Software\Policies\Microsoft\Windows\Personalization" "PreventChangingWallpaper"
        if (Test-Path $lmPath) { Remove-ItemProperty $lmPath "NoChangingWallPaper" -ErrorAction SilentlyContinue }
    }
    Write-Host "[$(if($Lock){'LOCK'}else{'UNLOCK'})] Wallpaper" -ForegroundColor $(if($Lock){'Yellow'}else{'Cyan'})
}

# ─── System tools ─────────────────────────────────────────────────────────────
function Set-SystemToolsLock {
    param([bool]$Lock)
    $expPol = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    if (!(Test-Path $expPol)) { New-Item $expPol -Force | Out-Null }
    if ($Lock) {
        Set-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableTaskMgr"       1
        Set-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableRegistryTools"  1
        Set-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "NoControlPanel"        1
        Set-UserReg "Software\Policies\Microsoft\Windows\System"                "DisableCMD"            2
        Set-ItemProperty $expPol "NoControlPanel" -Value 1 -Type DWord
    } else {
        Remove-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableTaskMgr"
        Remove-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "DisableRegistryTools"
        Remove-UserReg "Software\Microsoft\Windows\CurrentVersion\Policies\System" "NoControlPanel"
        Remove-UserReg "Software\Policies\Microsoft\Windows\System"                "DisableCMD"
        Remove-ItemProperty $expPol "NoControlPanel" -ErrorAction SilentlyContinue
    }
    Write-Host "[$(if($Lock){'LOCK'}else{'UNLOCK'})] System tools" -ForegroundColor $(if($Lock){'Yellow'}else{'Cyan'})
}

# ─── Block software installation ──────────────────────────────────────────────
function Set-InstallLock {
    param([bool]$Lock)
    $installerPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer"
    if (!(Test-Path $installerPath)) { New-Item $installerPath -Force | Out-Null }
    $storePath = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
    if (!(Test-Path $storePath)) { New-Item $storePath -Force | Out-Null }
    $progFiles = @("C:\Program Files", "C:\Program Files (x86)")

    if ($Lock) {
        Set-ItemProperty $installerPath "DisableMSI"          -Value 2 -Type DWord
        Set-ItemProperty $installerPath "DisableUserInstalls"  -Value 1 -Type DWord
        Set-ItemProperty $storePath "DisableStoreApps"         -Value 1 -Type DWord
        Set-ItemProperty $storePath "RemoveWindowsStore"       -Value 1 -Type DWord
        foreach ($pf in $progFiles) {
            if (!(Test-Path $pf)) { continue }
            $acl = Get-Acl $pf
            $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $TargetNT,"Write,CreateFiles,CreateDirectories",
                "ContainerInherit,ObjectInherit","None","Deny")
            $acl.AddAccessRule($deny)
            Set-Acl $pf $acl
        }
        $srpPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers"
        if (!(Test-Path $srpPath)) { New-Item $srpPath -Force | Out-Null }
        Set-ItemProperty $srpPath "DefaultLevel"        -Value 131072 -Type DWord
        Set-ItemProperty $srpPath "PolicyScope"         -Value 1      -Type DWord
        Set-ItemProperty $srpPath "AuthenticodeEnabled" -Value 0      -Type DWord
        $blockedPaths = @(
            "$TargetProfile\Downloads",
            "$TargetProfile\AppData\Local\Temp",
            "C:\Users\Public\Downloads"
        )
        foreach ($bp in $blockedPaths) {
            $pathKey = "$srpPath\Paths\{$(New-Guid)}"
            if (!(Test-Path $pathKey)) { New-Item $pathKey -Force | Out-Null }
            Set-ItemProperty $pathKey "SaferFlags"   -Value 0           -Type DWord
            Set-ItemProperty $pathKey "ItemData"     -Value "$bp\*"     -Type ExpandString
            Set-ItemProperty $pathKey "Description"  -Value "SchoolLock" -Type String
        }
        Write-Host "[LOCK] Install blocked" -ForegroundColor Yellow
    } else {
        Remove-ItemProperty $installerPath "DisableMSI"          -ErrorAction SilentlyContinue
        Remove-ItemProperty $installerPath "DisableUserInstalls"  -ErrorAction SilentlyContinue
        Remove-ItemProperty $storePath "DisableStoreApps"         -ErrorAction SilentlyContinue
        Remove-ItemProperty $storePath "RemoveWindowsStore"       -ErrorAction SilentlyContinue
        foreach ($pf in $progFiles) {
            if (!(Test-Path $pf)) { continue }
            $acl = Get-Acl $pf
            $acl.Access | Where-Object {
                $_.AccessControlType -eq "Deny" -and $_.IdentityReference -like "*$TargetUserName*"
            } | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
            Set-Acl $pf $acl
        }
        $srpPaths = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\Paths"
        if (Test-Path $srpPaths) { Remove-Item $srpPaths -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "[UNLOCK] Install allowed" -ForegroundColor Cyan
    }
}

# ─── Dangerous apps ───────────────────────────────────────────────────────────
function Set-DangerousAppsLock {
    param([bool]$Lock)
    $apps = @(
        "regedit.exe","cmd.exe","powershell.exe","powershell_ise.exe",
        "mmc.exe","msconfig.exe","diskpart.exe","format.com","cipher.exe",
        "net.exe","netsh.exe","sc.exe","bcdedit.exe","wmic.exe",
        "taskkill.exe","shutdown.exe","wscript.exe","cscript.exe"
    )
    foreach ($app in $apps) {
        $exePath = "$env:SystemRoot\System32\$app"
        if (!(Test-Path $exePath)) { continue }
        try {
            $acl = Get-Acl $exePath
            if ($Lock) {
                $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $TargetNT,"ReadAndExecute","None","None","Deny")
                $acl.AddAccessRule($deny)
                Write-Host "  [BLOCK] $app" -ForegroundColor Yellow
            } else {
                $acl.Access | Where-Object { $_.AccessControlType -eq "Deny" } |
                    ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
                Write-Host "  [ALLOW] $app" -ForegroundColor Cyan
            }
            Set-Acl $exePath $acl
        } catch {
            Write-Host "  [SKIP] $app : $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
    Write-Host "[$(if($Lock){'LOCK'}else{'UNLOCK'})] Dangerous apps" -ForegroundColor $(if($Lock){'Yellow'}else{'Cyan'})
}

# ─── USB ──────────────────────────────────────────────────────────────────────
function Set-USBLock {
    param([bool]$Lock)
    $usbPath = "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies"
    if (!(Test-Path $usbPath)) { New-Item $usbPath -Force | Out-Null }
    Set-ItemProperty $usbPath "WriteProtect" -Value $(if ($Lock) { 1 } else { 0 }) -Type DWord
    Write-Host "[$(if($Lock){'LOCK'}else{'UNLOCK'})] USB" -ForegroundColor $(if($Lock){'Yellow'}else{'Cyan'})
}

# ─── Run ──────────────────────────────────────────────────────────────────────
$isLock = ($Action -eq "Lock")

Write-Host "`n=== Desktop ===" -ForegroundColor Magenta
Set-DesktopACL -Lock $isLock

Write-Host "`n=== Wallpaper ===" -ForegroundColor Magenta
Set-WallpaperLock -Lock $isLock

Write-Host "`n=== System Tools ===" -ForegroundColor Magenta
Set-SystemToolsLock -Lock $isLock

Write-Host "`n=== Install Block ===" -ForegroundColor Magenta
Set-InstallLock -Lock $isLock

Write-Host "`n=== Dangerous Apps ===" -ForegroundColor Magenta
Set-DangerousAppsLock -Lock $isLock

Write-Host "`n=== USB ===" -ForegroundColor Magenta
Set-USBLock -Lock $isLock

Write-Host "`n[INFO] Updating policies..." -ForegroundColor Gray
gpupdate /force | Out-Null

Write-Host "`n[DONE] '$Action' applied successfully." -ForegroundColor Green
