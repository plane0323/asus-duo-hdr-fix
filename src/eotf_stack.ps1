param([ValidateSet('stop', 'start')][string]$Action = 'stop')

$ErrorActionPreference = 'Continue'
$LOG  = (Join-Path $PSScriptRoot 'eotf_stack.log')
$SVC  = @('AsusScreenXpert', 'AsusScreenXpertHostService')
$PROC = 'AsusAgni|AsusAgniService|AsusFeatureService|AsusInitialService|AsusLinkToScreenXpert|ScreenXpert'

function L($m) { "$(Get-Date -Format 'HH:mm:ss.fff')  $m" | Out-File -LiteralPath $LOG -Append -Encoding utf8 }
"=== stack $Action $(Get-Date -Format s) ===" | Out-File -LiteralPath $LOG -Append -Encoding utf8

if ($Action -eq 'stop') {
    foreach ($s in $SVC) {
        $svcObj = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svcObj) { continue }
        if ($svcObj.Status -eq 'Running') {
            try { Stop-Service -Name $s -Force -ErrorAction Stop; L "svc $s stopped" }
            catch { L "svc $s stop FAILED - $($_.Exception.Message)" }
        }
    }
    for ($r = 1; $r -le 5; $r++) {
        $p = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $PROC })
        if ($p.Count -eq 0) { break }
        foreach ($x in $p) { try { Stop-Process -Id $x.Id -Force -ErrorAction SilentlyContinue; L "proc $($x.ProcessName)($($x.Id)) killed" } catch {} }
        Start-Sleep -Milliseconds 700
    }
    $left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $PROC })
    L "result: procs left=$($left.Count)"
    if ($left.Count -eq 0) { exit 0 } else { exit 1 }
}
else {
    foreach ($s in $SVC) {
        $svcObj = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($null -eq $svcObj) { continue }
        if ($svcObj.Status -ne 'Running') {
            try { Start-Service -Name $s -ErrorAction Stop; L "svc $s started" }
            catch { L "svc $s start FAILED - $($_.Exception.Message)" }
        }
    }
    Start-Sleep -Seconds 2
    $run = @(Get-Service -Name $SVC -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    L "result: services running=$($run.Count)/$($SVC.Count)"
    exit 0
}
