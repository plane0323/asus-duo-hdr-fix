#Requires -RunAsAdministrator
<#
    dwm-eotf-tray installer
    Copies the scripts to C:\Program Files\dwm_eotf_rs, makes sure
    dwm_eotf_rs.exe is present, registers the logon task, switches the
    ScreenPad services to manual start and launches the tray.
#>

$ErrorActionPreference = 'Stop'

$DST      = 'C:\Program Files\dwm_eotf_rs'
$SRC      = $PSScriptRoot
$PSEXE    = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TASK     = 'dwm_eotf_tray'
$EXENAME  = 'dwm_eotf_rs.exe'
$EXESHA   = '71F5E0786EC254489BF7FBD5AB96CF407EBD7ABA71B9BFA3C7E287DFFAEBA23F'
$EXEURL   = 'https://github.com/SERGEYDJUM/dwm_eotf_rs/releases/download/v0.19.2/dwm_eotf_rs.exe'
$SERVICES = @('AsusScreenXpert', 'AsusScreenXpertHostService')

function Say([string]$m) { Write-Host "[*] $m" }
function Ok([string]$m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[!] $m" -ForegroundColor Yellow }

Say "target: $DST"

# --- 1. directory + scripts -------------------------------------------------
if (-not (Test-Path -LiteralPath $DST)) { New-Item -ItemType Directory -Path $DST -Force | Out-Null }
foreach ($f in 'dwm_eotf_tray.ps1', 'eotf_apply.ps1', 'eotf_stack.ps1') {
    $from = Join-Path (Join-Path $SRC 'src') $f
    if (-not (Test-Path -LiteralPath $from)) { throw "missing source file: $from" }
    Copy-Item -LiteralPath $from -Destination (Join-Path $DST $f) -Force
}
Copy-Item -LiteralPath (Join-Path $SRC 'README.md') -Destination (Join-Path $DST 'README.md') -Force
Ok "scripts copied"

# --- 2. dwm_eotf_rs.exe -----------------------------------------------------
$exePath = Join-Path $DST $EXENAME
$needDownload = $true
if (Test-Path -LiteralPath $exePath) {
    $h = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
    if ($h -eq $EXESHA) { Ok "existing $EXENAME verified"; $needDownload = $false }
    else { Warn "existing $EXENAME hash mismatch, will re-fetch" }
}
if ($needDownload) {
    $local = Join-Path $SRC $EXENAME
    if (Test-Path -LiteralPath $local) {
        $h = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        if ($h -ne $EXESHA) { throw "local $EXENAME has wrong hash: $h" }
        Copy-Item -LiteralPath $local -Destination $exePath -Force
        Ok "copied local $EXENAME (hash ok)"
    } else {
        Say "downloading $EXENAME from upstream release..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $EXEURL -OutFile $exePath -UseBasicParsing
            $h = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
            if ($h -ne $EXESHA) { Remove-Item -LiteralPath $exePath -Force; throw "downloaded file hash mismatch: $h" }
            Ok "downloaded and verified $EXENAME"
        } catch {
            throw "could not obtain $EXENAME. Download it manually from $EXEURL and place it in $DST, then re-run."
        }
    }
}

# --- 3. stop any running tray ----------------------------------------------
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'dwm_eotf_tray\.ps1' -and $_.CommandLine -notmatch 'TestMode' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# --- 4. scheduled task ------------------------------------------------------
$tray = Join-Path $DST 'dwm_eotf_tray.ps1'
$a  = New-ScheduledTaskAction -Execute $PSEXE -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tray`""
$tr = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$tr.Delay = 'PT2S'
$pr = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
$se = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)
Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TASK -Action $a -Trigger $tr -Principal $pr -Settings $se -Description 'dwm_eotf tray controller' -Force | Out-Null
Ok "task '$TASK' registered (logon +2s, highest privileges)"

# --- 5. ScreenPad services -> manual ---------------------------------------
$found = 0
foreach ($s in $SERVICES) {
    if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
        & sc.exe @('config', $s, 'start=', 'demand') | Out-Null
        Ok "service $s -> manual start"
        $found++
    }
}
if ($found -eq 0) { Warn 'ScreenPad services not found - non-ASUS machine, skipping' }

# --- 6. start tray ----------------------------------------------------------
$p = Start-Process -FilePath $PSEXE -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$tray`"" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { Ok "tray started (pid $($p.Id))" }
else { Warn 'tray exited immediately - check the log in the install folder' }

Say "done. tray icon should appear in the notification area."
Say "logs: $DST\tray.log and $DST\eotf_apply.log"
