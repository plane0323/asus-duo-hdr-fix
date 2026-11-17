param([switch]$TestMode)

$ErrorActionPreference = 'Continue'
$ROOT     = $PSScriptRoot
$APPLY    = Join-Path $ROOT 'eotf_apply.ps1'
$STACK    = Join-Path $ROOT 'eotf_stack.ps1'
$STATE    = Join-Path $ROOT 'eotf_state.json'
$TLOG     = Join-Path $ROOT 'tray.log'
$TASK     = 'dwm_eotf_tray'
$TASKFILE = "$env:SystemRoot\System32\Tasks\$TASK"
$MPOKEY   = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
$MPONAME  = 'OverlayTestMode'
$PSEXE    = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function TL($m) { try { "$(Get-Date -Format 'HH:mm:ss')  $m" | Out-File -LiteralPath $TLOG -Append -Encoding utf8 } catch {} }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HdrState {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Lo; public int Hi; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTech; public uint rotation; public uint scaling; public uint rrNum; public uint rrDen; public uint scanline; public int available; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC s; public TGT t; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct H { public uint type; public uint size; public LUID adapterId; public uint id; }
  [StructLayout(LayoutKind.Sequential)] public struct ACM1 { public H h; public uint value; public uint enc; public uint bpc; }
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint f, ref uint np, IntPtr pp, ref uint nm, IntPtr pm, IntPtr t);
  [DllImport("user32.dll", EntryPoint="DisplayConfigGetDeviceInfo")] public static extern int G1(ref ACM1 p);

  // returns 1 = any active path has HDR enabled, 0 = none, -1 = unknown
  public static int AnyHdr() {
    uint np = 0, nm = 0;
    if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return -1;
    IntPtr pb = Marshal.AllocHGlobal((int)np * Marshal.SizeOf(typeof(PATH)));
    IntPtr mb = Marshal.AllocHGlobal((int)nm * 64);
    IntPtr r = (IntPtr)QueryDisplayConfig(2, ref np, pb, ref nm, mb, IntPtr.Zero);
    int result = 0; bool any = false;
    for (int i = 0; i < np; i++) {
      PATH p = (PATH)Marshal.PtrToStructure(IntPtr.Add(pb, i * Marshal.SizeOf(typeof(PATH))), typeof(PATH));
      ACM1 a = new ACM1(); a.h.type = 9; a.h.size = (uint)Marshal.SizeOf(typeof(ACM1)); a.h.adapterId = p.t.adapterId; a.h.id = p.t.id;
      int e = G1(ref a);
      if (e == 0) { any = true; if (((a.value >> 1) & 1) == 1) result = 1; }
    }
    Marshal.FreeHGlobal(pb); Marshal.FreeHGlobal(mb);
    return any ? result : -1;
  }
}
'@

function Get-HdrEnabled {
    try { $v = [HdrState]::AnyHdr(); if ($v -lt 0) { return $null }; return ($v -eq 1) } catch { return $null }
}
function Get-LastGamma {
    if (Test-Path -LiteralPath $STATE) {
        try { $s = Get-Content -LiteralPath $STATE -Raw | ConvertFrom-Json; if ($s.gamma) { return [double]$s.gamma } } catch {}
    }
    return 2.2
}

# ---------------- fast state probes ----------------
function Get-MpoEnabled {
    try { $v = [int](Get-ItemProperty -Path $MPOKEY -Name $MPONAME -ErrorAction Stop).$MPONAME } catch { $v = 0 }
    return (($v -band 5) -eq 0)
}
function Set-MpoEnabled([bool]$enabled) {
    if (-not (Test-Path $MPOKEY)) { New-Item -Path $MPOKEY -Force | Out-Null }
    try { $v = [int](Get-ItemProperty -Path $MPOKEY -Name $MPONAME -ErrorAction Stop).$MPONAME } catch { $v = 0 }
    $new = if ($enabled) { $v -band (-bnot 5) } else { $v -bor 5 }
    New-ItemProperty -Path $MPOKEY -Name $MPONAME -Value $new -PropertyType DWord -Force | Out-Null
    return $new
}
function Get-AutostartEnabled { return (Test-Path -LiteralPath $TASKFILE) }
function Get-StackRunning {
    $s = Get-Service -Name 'AsusScreenXpert' -ErrorAction SilentlyContinue
    return ($null -ne $s -and $s.Status -eq 'Running')
}
function Set-StackStartMode([bool]$auto) {
    $mode = if ($auto) { 'auto' } else { 'demand' }
    foreach ($n in @('AsusScreenXpert', 'AsusScreenXpertHostService')) {
        $a = @('config', $n, 'start=', $mode)
        $o = (& sc.exe @a 2>&1 | Out-String).Trim()
        TL "sc config $n start= $mode -> $o"
    }
}
function Get-PatchState {
    if (-not (Test-Path -LiteralPath $STATE)) { return $null }
    try { $s = Get-Content -LiteralPath $STATE -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $s.patched) { return $null }
    $cur = (Get-Process dwm -ErrorAction SilentlyContinue | Select-Object -First 1).Id
    if ($s.PSObject.Properties.Name -contains 'dwm_pid' -and $s.dwm_pid -and $cur -ne [int]$s.dwm_pid) { return $null }
    return $s
}

# ---------------- icons ----------------
function New-DotIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $b = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($b, 2, 2, 28, 28)
    $p = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 255, 255, 255)), 3
    $g.DrawEllipse($p, 3, 3, 26, 26)
    $g.Dispose(); $b.Dispose(); $p.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$ICO_ON   = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 204, 113))
$ICO_OFF  = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 148, 158))
$ICO_BUSY = New-DotIcon ([System.Drawing.Color]::FromArgb(241, 196, 15))

# ---------------- globals ----------------
$script:Pending     = $null
$script:PendingKind = ''
$script:Busy        = $false
$script:CurGamma    = 2.2
$script:LastHdr     = $null
$script:HdrAt       = $null

function Refresh-Icon {
    if (-not $tray) { return }
    if ($script:Busy) { $tray.Icon = $ICO_BUSY; return }
    $st  = Get-PatchState
    $mpoTxt = if (Get-MpoEnabled) { '开' } else { '关' }
    $stk = if (Get-StackRunning) { '副屏栈开' } else { '副屏栈关' }
    if ($st) {
        $tray.Icon = $ICO_ON
        $tray.Text = "dwm_eotf: 已应用 gamma $($st.gamma) | MPO $mpoTxt | $stk"
    } else {
        $tray.Icon = $ICO_OFF
        $tray.Text = "dwm_eotf: 未应用 | MPO $mpoTxt | $stk"
    }
}

function Start-Child([string]$kind, [string]$file, [string[]]$extra) {
    if ($script:Busy) { TL "skip $kind (busy)"; return }
    $script:Busy = $true
    $script:PendingKind = $kind
    $tray.Icon = $ICO_BUSY
    $tray.Text = 'dwm_eotf: 正在执行...'
    $argList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`"") + $extra
    try {
        $script:Pending = Start-Process -FilePath $PSEXE -ArgumentList $argList -PassThru -WindowStyle Hidden
        TL "spawn $kind pid=$($script:Pending.Id) args=$($extra -join ' ')"
    } catch {
        TL "spawn FAILED: $($_.Exception.Message)"
        $script:Busy = $false
        Refresh-Icon
        $tray.ShowBalloonTip(6000, 'dwm_eotf', "启动失败：$($_.Exception.Message)", 'Error')
    }
}
function Start-Apply([string]$mode, [double]$gamma, [bool]$ensureStack = $false) {
    $a = @('-Mode', $mode)
    if ($mode -eq 'patch') { $a += @('-Gamma', $gamma) }
    if ($ensureStack) { $a += @('-EnsureStack') }
    Start-Child 'apply' $APPLY $a
}
function Start-Stack([string]$action) { Start-Child 'stack' $STACK @('-Action', $action) }

function Register-LogonTask {
    $a = New-ScheduledTaskAction -Execute $PSEXE `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ROOT\dwm_eotf_tray.ps1`""
    $t = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $t.Delay = 'PT15S'
    $p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    Register-ScheduledTask -TaskName $TASK -Action $a -Trigger $t -Principal $p -Settings $s -Description 'dwm_eotf tray controller' -Force | Out-Null
}

# ---------------- menu ----------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $true
$menu.ShowCheckMargin = $true

function Build-Menu {
    $menu.SuspendLayout()
    $menu.Items.Clear()
    $st  = Get-PatchState
    $mpo = Get-MpoEnabled
    $stk = Get-StackRunning
    $hdr = Get-HdrEnabled
    $script:CurGamma = Get-LastGamma

    $h0 = $menu.Items.Add('HDR：' + $(if ($null -eq $hdr) { '未知' } elseif ($hdr) { '已开启' } else { '已关闭' }))
    $h0.Enabled = $false
    $h1 = $menu.Items.Add(('补丁：' + $(if ($st) { "已应用 gamma $($st.gamma)" } else { '未应用（原始 sRGB）' })))
    $h1.Enabled = $false
    $h2 = $menu.Items.Add(('MPO：' + $(if ($mpo) { '已启用' } else { '已禁用' })))
    $h2.Enabled = $false
    $h3 = $menu.Items.Add(('副屏栈：' + $(if ($stk) { '运行中' } else { '已停止' })))
    $h3.Enabled = $false
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $i = $menu.Items.Add('关闭补丁（恢复 sRGB）')
    $i.Enabled = [bool]$st
    $i.add_Click({ Start-Apply 'revert' 0 })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    foreach ($g in 2.0, 2.2, 2.4) {
        $it = $menu.Items.Add(("Gamma {0:0.0}" -f $g))
        $it.Checked = ($st -and ([math]::Abs([double]$st.gamma - $g) -lt 0.001))
        $it.Tag = $g
        $it.add_Click({ param($s, $e) Start-Apply 'patch' ([double]$s.Tag) })
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $mi = $menu.Items.Add(("MPO 多平面叠加：$(if ($mpo) { '已启用 → 点击禁用' } else { '已禁用 → 点击启用' })"))
    $mi.Checked = $mpo
    $mi.add_Click({
        $now = Get-MpoEnabled
        Set-MpoEnabled (-not $now) | Out-Null
        TL "mpo toggled -> $(-not $now)"
        Refresh-Icon
        Start-Apply 'patch' (Get-LastGamma)
        $tray.ShowBalloonTip(4000, 'MPO', $(if ($now) { '已禁用' } else { '已启用' }) + '，正在重启 DWM 使其生效', 'Info')
    })

    $si = $menu.Items.Add(("副屏栈（冰刃 Duo）：$(if ($stk) { '运行中 → 点击停止' } else { '已停止 → 点击启动' })"))
    $si.Checked = $stk
    $si.add_Click({
        $now = Get-StackRunning
        TL "stack toggled -> $(-not $now)"
        $tray.ShowBalloonTip(2500, '副屏栈', $(if ($now) { '正在停止...' } else { '正在启动...' }), 'Info')
        Start-Stack $(if ($now) { 'stop' } else { 'start' })
    })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $auto = Get-AutostartEnabled
    $ai = $menu.Items.Add(('开机自启：' + $(if ($auto) { '已开启 → 点击关闭' } else { '已关闭 → 点击开启' })))
    $ai.Checked = $auto
    $ai.add_Click({
        try {
                        if (Get-AutostartEnabled) {
                Unregister-ScheduledTask -TaskName $TASK -Confirm:$false -ErrorAction Stop
                Set-StackStartMode $true
                TL 'autostart removed; stack start mode -> auto'
                $tray.ShowBalloonTip(3000, '开机自启', '已关闭，副屏栈恢复为开机自启', 'Info')
            } else {
                Register-LogonTask
                Set-StackStartMode $false
                TL 'autostart added; stack start mode -> manual'
                $tray.ShowBalloonTip(3000, '开机自启', '已开启：副屏栈改由托盘在补丁完成后拉起', 'Info')
            } else {
                Register-LogonTask
                TL 'autostart added'
                $tray.ShowBalloonTip(3000, '开机自启', '已开启（登录后约 15 秒启动托盘并自动打补丁）', 'Info')
            }
        } catch {
            TL "autostart toggle FAILED: $($_.Exception.Message)"
            try { $tray.ShowBalloonTip(7000, '开机自启', "操作失败：$($_.Exception.Message)", 'Error') } catch {}
        }
        Refresh-Icon
    })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $ex = $menu.Items.Add('退出')
    $ex.add_Click({ TL 'exit'; $tray.Visible = $false; $tray.Dispose(); [System.Windows.Forms.Application]::Exit() })

    $menu.ResumeLayout()
}
$menu.add_Opening({ Build-Menu })

# ---------------- tray ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $ICO_OFF
$tray.Text = 'dwm_eotf'
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

# ---------------- poll timer ----------------
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 600
$poll.add_Tick({
    if ($script:Pending -and $script:Pending.HasExited) {
        $code = $script:Pending.ExitCode
        $kind = $script:PendingKind
        $script:Pending = $null
        $script:PendingKind = ''
        $script:Busy = $false
        Refresh-Icon
        TL "$kind finished code=$code"
        if ($code -eq 0) {
            if ($kind -eq 'stack') { $tray.ShowBalloonTip(2000, '副屏栈', '操作完成', 'Info') }
            else { $tray.ShowBalloonTip(2000, 'dwm_eotf', '已应用', 'Info') }
        } else {
            $tray.ShowBalloonTip(7000, 'dwm_eotf', "$kind 失败（退出码 $code），详见 鏃ュ織", 'Error')
        }
    }
})
$poll.Start()

# ---------------- test mode ----------------
if ($TestMode) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Build-Menu
    $sw.Stop()
    Write-Output "Build-Menu took $($sw.ElapsedMilliseconds) ms  ShowImageMargin=$($menu.ShowImageMargin)  HDR=$(Get-HdrEnabled)"
    Write-Output '--- MENU ---'
    foreach ($it in $menu.Items) {
        if ($it.GetType().Name -eq 'ToolStripSeparator') { Write-Output '   ----------' ; continue }
        Write-Output ("   [{0}] {1}" -f $(if ($it.Checked) { 'x' } else { ' ' }), $it.Text)
    }
    $tray.Visible = $false
    $tray.Dispose()
    return
}

# ---------------- startup ----------------
Build-Menu
$startT = New-Object System.Windows.Forms.Timer
$startT.Interval = 3000
$startT.add_Tick({
    $startT.Stop()
    if (-not (Get-PatchState)) {
        TL 'startup: not patched -> apply gamma 2.2 (ensure stack)'
        Start-Apply 'patch' (Get-LastGamma) $true
    } else {
        TL 'startup: already patched'
        if (-not (Get-StackRunning)) { TL 'startup: stack down -> start it'; Start-Stack 'start' }
        Refresh-Icon
    }
})
$startT.Start()

Refresh-Icon
TL 'tray started'

function On-DisplayChangedCore {
    try {
        $now = Get-HdrEnabled
        if ($null -eq $now) { return }
        if ($null -eq $script:LastHdr) { $script:LastHdr = $now; TL "hdr initial -> $now"; return }
        if ($now -eq $script:LastHdr) { return }
        $script:LastHdr = $now
        TL "hdr changed -> $now (SystemEvents.DisplaySettingsChanged)"
        if ($now) {
            TL 'hdr ON -> re-apply patch'
            Start-Apply 'patch' (Get-LastGamma)
        } else {
            TL 'hdr OFF -> keep patch (inert), no DWM restart'
            Refresh-Icon
        }
    } catch { TL "display change error: $($_.Exception.Message)" }
}

function On-DisplayChanged {
    try {
        if ($script:Form -and $script:Form.InvokeRequired) {
            [void]$script:Form.BeginInvoke([Action]{ On-DisplayChangedCore })
            return
        }
    } catch { }
    On-DisplayChangedCore
}

$form = New-Object System.Windows.Forms.Form
$script:Form = $form
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged({ On-DisplayChanged })
$script:LastHdr = Get-HdrEnabled
TL "hdr baseline -> $($script:LastHdr)"
$form.ShowInTaskbar = $false
$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.Size = New-Object System.Drawing.Size(1, 1)
[System.Windows.Forms.Application]::Run($form)
