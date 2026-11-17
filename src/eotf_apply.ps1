param(
    [ValidateSet('patch', 'revert')][string]$Mode = 'patch',
    [double]$Gamma = 2.2,
    [switch]$EnsureStack
)

$ErrorActionPreference = 'Continue'

$LOG  = (Join-Path $PSScriptRoot 'eotf_apply.log')
$EXE  = (Join-Path $PSScriptRoot 'dwm_eotf_rs.exe')
$SVC  = @('AsusScreenXpert', 'AsusScreenXpertHostService')
$PROC = 'AsusAgni|AsusAgniService|AsusFeatureService|AsusInitialService|AsusLinkToScreenXpert|ScreenXpert'
$STATE = (Join-Path $PSScriptRoot 'eotf_state.json')

$fs = New-Object System.IO.FileStream($LOG, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 4096, [System.IO.FileOptions]::WriteThrough)
$sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
$sw.AutoFlush = $true
function W($m) { $sw.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff')  $m"); try { $fs.Flush($true) } catch {} }

W "==================== apply mode=$Mode gamma=$Gamma ===================="

# ---------- 1. stop ScreenPad stack ----------
$wasRunning = New-Object System.Collections.ArrayList
foreach ($s in $SVC) {
    $svcObj = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($null -eq $svcObj) { continue }
    if ($svcObj.Status -eq 'Running') {
        try { Stop-Service -Name $s -Force -ErrorAction Stop; [void]$wasRunning.Add($s); W "svc $s stopped" }
        catch { W "svc $s stop FAILED - $($_.Exception.Message)" }
    }
}
for ($r = 1; $r -le 5; $r++) {
    $p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $PROC })
    if ($p.Count -eq 0) { break }
    foreach ($x in $p) { try { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Milliseconds 800
}

# ---------- 2. GUARD ----------
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $PROC })
$leftSvc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $SVC -and $_.Status -ne 'Stopped' })
if ($left.Count -gt 0 -or $leftSvc.Count -gt 0) {
    W "GUARD FAILED procs=[$(($left | ForEach-Object { $_.ProcessName }) -join ',')] svcs=[$(($leftSvc | ForEach-Object { $_.Name }) -join ',')]"
    W "ABORT - DWM untouched"
    foreach ($s in $wasRunning) { try { Start-Service -Name $s -ErrorAction SilentlyContinue } catch {} }
    $sw.Dispose(); $fs.Dispose()
    exit 2
}
W "GUARD PASSED"

# ---------- 3. act ----------
$ok = $false
if ($Mode -eq 'patch') {
    $out = & $EXE -c $Gamma 2>&1 | Out-String
    W "patcher exit=$LASTEXITCODE"
    W "patcher said: $(($out -replace "`r?`n", ' | ').Trim())"
    $ok = ($LASTEXITCODE -eq 0 -and $out -match 'DWM patched')
} else {
    $old = (Get-Process dwm -ErrorAction SilentlyContinue).Id
    & taskkill.exe /F /IM dwm.exe 2>&1 | Out-Null
    W "dwm killed (old pid=$old) exit=$LASTEXITCODE"
    Start-Sleep -Seconds 3
    $new = (Get-Process dwm -ErrorAction SilentlyContinue).Id
    W "dwm restarted pid=$new"
    $ok = ($null -ne $new -and $new -ne $old)
}
Start-Sleep -Seconds 2

# ---------- 4. restore stack ----------
$toStart = if ($EnsureStack) { $SVC } else { $wasRunning }
foreach ($s in $toStart) {
    $svcObj = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($null -eq $svcObj) { continue }
    if ($svcObj.Status -eq 'Running') { W "svc $s already running"; continue }
    try { Start-Service -Name $s -ErrorAction Stop; W "svc $s started" }
    catch { W "svc $s start FAILED - $($_.Exception.Message)" }
}

# ---------- 5. state ----------
if ($ok) {
    $curDwm = (Get-Process dwm -ErrorAction SilentlyContinue | Select-Object -First 1).Id
    $st = @{ patched = ($Mode -eq 'patch'); gamma = $Gamma; time = (Get-Date).ToString('o'); dwm_pid = $curDwm } | ConvertTo-Json
    $st | Out-File -LiteralPath $STATE -Encoding utf8 -Force
    W "state written: $st"
}
W "==================== apply end ok=$ok ===================="
$sw.Dispose(); $fs.Dispose()
if ($ok) { exit 0 } else { exit 1 }
