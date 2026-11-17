#Requires -RunAsAdministrator
<#
    dwm-eotf-tray uninstaller
    Removes the logon task, restores the ScreenPad services to automatic
    start, restarts them, and optionally deletes the install folder.
#>

$ErrorActionPreference = 'Continue'

$DST      = 'C:\Program Files\dwm_eotf_rs'
$TASK     = 'dwm_eotf_tray'
$SERVICES = @('AsusScreenXpert', 'AsusScreenXpertHostService')

function Say([string]$m) { Write-Host "[*] $m" }
function Ok([string]$m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[!] $m" -ForegroundColor Yellow }

# --- 1. stop the tray -------------------------------------------------------
$tg = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'dwm_eotf_tray\.ps1' -and $_.CommandLine -notmatch 'TestMode' }
foreach ($x in $tg) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue; Ok "tray stopped (pid $($x.ProcessId))" }

# --- 2. remove the task -----------------------------------------------------
if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction SilentlyContinue
    Ok "task '$TASK' removed"
} else { Say "task '$TASK' was not registered" }

# --- 3. restore services to automatic --------------------------------------
foreach ($s in $SERVICES) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        & sc.exe @('config', $s, 'start=', 'auto') | Out-Null
        Ok "service $s -> automatic start"
        Start-Service -Name $s -ErrorAction SilentlyContinue
        Ok "service $s started"
    } else { Say "service $s not present, skipped" }
}

# --- 4. DWM note ------------------------------------------------------------
Say "the EOTF patch lives in dwm.exe memory and disappears at the next logoff/reboot."
Say "reboot (or sign out and back in) to return to the stock sRGB curve."

# --- 5. optional folder removal --------------------------------------------
$answer = Read-Host "Delete '$DST' and everything in it? (y/N)"
if ($answer -eq 'y' -or $answer -eq 'Y') {
    if (Test-Path -LiteralPath $DST) {
        Remove-Item -LiteralPath $DST -Recurse -Force -ErrorAction SilentlyContinue
        Ok "removed $DST"
    }
} else {
    Say "kept $DST (you can delete it manually later)"
}

Say "done."
