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

# ---------------- ScreenPad brightness via ATKACPI (ASUS WMI device ids) ----------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AtkAcpi
{
    const string FILE_NAME      = @"\\.\ATKACPI";
    const uint   CONTROL_CODE   = 0x0022240C;
    const uint   DSTS_METHOD    = 0x53545344;
    const uint   DEVS_METHOD    = 0x53564544;
    const uint   GENERIC_READ   = 0x80000000;
    const uint   GENERIC_WRITE  = 0x40000000;
    const uint   OPEN_EXISTING  = 3;
    const uint   FILE_ATTRIBUTE_NORMAL = 0x80;
    const uint   FILE_SHARE_READ  = 1;
    const uint   FILE_SHARE_WRITE = 2;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inLen, byte[] outBuf, uint outLen, ref uint returned, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    static IntPtr Open()
    {
        return CreateFile(FILE_NAME, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                          IntPtr.Zero, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
    }

    static byte[] Call(IntPtr h, uint method, byte[] args)
    {
        byte[] inBuf = new byte[8 + args.Length];
        byte[] outBuf = new byte[16];
        BitConverter.GetBytes(method).CopyTo(inBuf, 0);
        BitConverter.GetBytes((uint)args.Length).CopyTo(inBuf, 4);
        Array.Copy(args, 0, inBuf, 8, args.Length);
        uint ret = 0;
        if (!DeviceIoControl(h, CONTROL_CODE, inBuf, (uint)inBuf.Length, outBuf, (uint)outBuf.Length, ref ret, IntPtr.Zero))
            throw new Exception("DeviceIoControl err=" + Marshal.GetLastWin32Error());
        return outBuf;
    }

    // returns raw value minus 0x10000, or -1 when unsupported
    public static int Read(uint deviceId)
    {
        IntPtr h = Open();
        if (h == new IntPtr(-1)) return -1;
        try
        {
            byte[] args = new byte[8];
            BitConverter.GetBytes(deviceId).CopyTo(args, 0);
            return BitConverter.ToInt32(Call(h, DSTS_METHOD, args), 0) - 65536;
        }
        catch { return -1; }
        finally { CloseHandle(h); }
    }

    // returns 1 when accepted, otherwise an error/result code
    public static int Write(uint deviceId, int value)
    {
        IntPtr h = Open();
        if (h == new IntPtr(-1)) return -1;
        try
        {
            byte[] args = new byte[8];
            BitConverter.GetBytes(deviceId).CopyTo(args, 0);
            BitConverter.GetBytes((uint)value).CopyTo(args, 4);
            return BitConverter.ToInt32(Call(h, DEVS_METHOD, args), 0);
        }
        catch { return -1; }
        finally { CloseHandle(h); }
    }
}
'@

$script:SpStateFile = Join-Path $ROOT 'eotf_brightness.state'
$script:SpLast = -1
$script:SpMinPct = 4
$script:SpSdrFull = 28
$script:SpSdrFloorVal = 84
$script:SpHdrFull = 50
$script:SpHdrFloorVal = 42
# ---------------- brightness mapping config ----------------
$script:SpCfgFile = Join-Path $ROOT 'eotf_brightness.json'
function Load-SpConfig {
    if (-not (Test-Path -LiteralPath $script:SpCfgFile)) { return }
    try {
        $j = Get-Content -LiteralPath $script:SpCfgFile -Raw | ConvertFrom-Json
        if ($null -ne $j.sdrFull)  { $script:SpSdrFull     = [int]$j.sdrFull }
        if ($null -ne $j.sdrFloor) { $script:SpSdrFloorVal = [int]$j.sdrFloor }
        if ($null -ne $j.hdrFull)  { $script:SpHdrFull     = [int]$j.hdrFull }
        if ($null -ne $j.hdrFloor) { $script:SpHdrFloorVal = [int]$j.hdrFloor }
        if ($null -ne $j.fadeMs)   { $script:SpFadeMs = [int]$j.fadeMs }
    } catch { TL "config load failed: $($_.Exception.Message)" }
}
function Save-SpConfig {
    try {
        @{
            sdrFull  = $script:SpSdrFull
            sdrFloor = $script:SpSdrFloorVal
            hdrFull  = $script:SpHdrFull
            hdrFloor = $script:SpHdrFloorVal
            fadeMs   = $script:SpFadeMs
        } | ConvertTo-Json | Out-File -LiteralPath $script:SpCfgFile -Encoding utf8 -Force
    } catch { TL "config save failed: $($_.Exception.Message)" }
}
function Show-SpSettings {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = '副屏亮度映射'
    $f.ClientSize = New-Object System.Drawing.Size(348, 292)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true

    $defs = @(
        @{ text = 'SDR：主屏达到此值 → 副屏满亮'; value = $script:SpSdrFull;     max = 100; y = 14;  suffix = '%' },
        @{ text = 'SDR：主屏最低时 → 副屏下限';   value = $script:SpSdrFloorVal; max = 255; y = 46;  suffix = '' },
        @{ text = 'HDR：主屏达到此值 → 副屏满亮'; value = $script:SpHdrFull;     max = 100; y = 96;  suffix = '%' },
        @{ text = 'HDR：主屏最低时 → 副屏下限';   value = $script:SpHdrFloorVal; max = 255; y = 128; suffix = '' },
        @{ text = '渐变过渡时长（毫秒）';        value = $script:SpFadeMs;      max = 2000; min = 0; y = 160; suffix = 'ms' }
    )

    $nums = @()
    foreach ($d in $defs) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $d.text
        $lbl.Location = New-Object System.Drawing.Point(16, ($d.y + 3))
        $lbl.Size = New-Object System.Drawing.Size(220, 20)
        $f.Controls.Add($lbl)

        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Minimum = if ($null -ne $d.min) { $d.min } else { 1 }
        $n.Maximum = $d.max
        $n.Value = [decimal]$d.value
        $n.Location = New-Object System.Drawing.Point(242, $d.y)
        $n.Size = New-Object System.Drawing.Size(88, 23)
        $f.Controls.Add($n)
        $nums += $n
    }

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '下限单位为 0-255（10 ≈ 4%，255 = 满亮）'
    $hint.Location = New-Object System.Drawing.Point(16, 196)
    $hint.Size = New-Object System.Drawing.Size(314, 20)
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $f.Controls.Add($hint)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '保存'
    $ok.Location = New-Object System.Drawing.Point(130, 234)
    $ok.Size = New-Object System.Drawing.Size(90, 30)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(232, 234)
    $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.Add($cancel)

    $f.AcceptButton = $ok
    $f.CancelButton = $cancel

    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:SpSdrFull     = [int]$nums[0].Value
        $script:SpSdrFloorVal = [int]$nums[1].Value
        $script:SpHdrFull     = [int]$nums[2].Value
        $script:SpHdrFloorVal = [int]$nums[3].Value
        $script:SpFadeMs      = [int]$nums[4].Value
        if ($script:SpSdrFull -lt 1) { $script:SpSdrFull = 1 }
        if ($script:SpHdrFull -lt 1) { $script:SpHdrFull = 1 }
        Save-SpConfig
        TL "mapping saved: sdr=$($script:SpSdrFull)/$($script:SpSdrFloorVal) hdr=$($script:SpHdrFull)/$($script:SpHdrFloorVal) fade=$($script:SpFadeMs)ms"
        try { Sync-ScreenPad } catch { }
    }
    $f.Dispose()
}
Load-SpConfig

$script:SpBurstUntil = [datetime]::MinValue
$script:SpCurVal = -1
$script:SpTarget = -1
$script:SpFadeMs = 480
$script:SpFastMs = 20
$script:SpFadeFrom = -1
$script:SpFadeStart = [datetime]::MinValue
$script:SpEnabled = $true

function Get-SpEnabled {
    if (Test-Path -LiteralPath $script:SpStateFile) {
        try { return ((Get-Content -LiteralPath $script:SpStateFile -Raw).Trim() -ne '0') } catch { }
    }
    return $true
}
function Set-SpEnabled([bool]$on) {
    try {
        $v = if ($on) { '1' } else { '0' }
        $v | Out-File -LiteralPath $script:SpStateFile -Encoding ascii -Force
    } catch { }
}
function Get-MainBrightness {
    $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $m) { return $null }
    return [int]$m.CurrentBrightness
}
function Sync-ScreenPad {
    if (-not $script:SpEnabled) { return }
    $main = Get-MainBrightness
    if ($null -eq $main) { return }
    $hdr = Get-HdrEnabled
    if ($hdr -eq $true) {
        # HDR: 主屏 0..SpHdrFull 线性映射到 SpHdrFloorVal..255
        if ($main -ge $script:SpHdrFull) {
            $val = 255
        } else {
            $val = [int][math]::Round($script:SpHdrFloorVal + ($main * (255 - $script:SpHdrFloorVal) / $script:SpHdrFull))
        }
        if ($val -gt 255) { $val = 255 }
        if ($val -lt $script:SpHdrFloorVal) { $val = $script:SpHdrFloorVal }
    } else {
        # SDR: 主屏 0..SpSdrFull 线性映射到 SpSdrFloorVal..255
        if ($script:SpSdrFull -le 0) {
            $val = 255
        } else {
            $val = [int][math]::Round($script:SpSdrFloorVal + ($main * (255 - $script:SpSdrFloorVal) / $script:SpSdrFull))
        }
        if ($val -gt 255) { $val = 255 }
        if ($val -lt $script:SpSdrFloorVal) { $val = $script:SpSdrFloorVal }
    }
    if ($script:SpCurVal -lt 0) {
        try { $script:SpCurVal = ([AtkAcpi]::Read([uint32]0x00050032)) -band 0xFF } catch { $script:SpCurVal = 0 }
    }
    if ($script:SpCurVal -eq $val) { $script:SpTarget = $val; $script:SpLast = $val; return }
    if (-not $fadeT.Enabled) {
        $script:SpFadeFrom  = $script:SpCurVal
        $script:SpFadeStart = Get-Date
    }
    if ($val -ne $script:SpTarget) {
        $script:SpTarget = $val
        TL "screenpad target $val/255 (main=$main% mode=$(if ($hdr -eq $true) { 'hdr' } else { 'sdr' }))"
    }
    $script:SpBurstUntil = (Get-Date).AddSeconds(3)
    try { if (-not $fadeT.Enabled) { $fadeT.Start() } } catch { }
}

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

    $mapItem = $menu.Items.Add('亮度映射设置…')
    $mapItem.add_Click({ try { Show-SpSettings } catch { TL "settings error: $($_.Exception.Message)" } })
    $sp = Get-SpEnabled
    $spItem = $menu.Items.Add(('副屏亮度跟随主屏：' + $(if ($sp) { '已开启 → 点击关闭' } else { '已关闭 → 点击开启' })))
    $spItem.Checked = $sp
    $spItem.add_Click({
        $now = Get-SpEnabled
        Set-SpEnabled (-not $now)
        $script:SpEnabled = -not $now
        TL "screenpad sync -> $(-not $now)"
        if ($now) {
            try { [void][AtkAcpi]::Write([uint32]0x00050032, 255) } catch { }
            $script:SpLast = -1
        } else {
            $script:SpLast = -1
            Sync-ScreenPad
        }
    })

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

# ---------------- ScreenPad brightness timer ----------------
$script:SpEnabled = Get-SpEnabled
$brT = New-Object System.Windows.Forms.Timer
$brT.Interval = $script:SpFastMs
$brT.add_Tick({
    try {
        Sync-ScreenPad
        $fast = (((Get-Date) -lt $script:SpBurstUntil) -or ($script:SpPeekCount -gt 0))
        if (-not $fast) {
            $brT.Stop()
            TL 'idle -> polling stopped'
        }
    } catch { }
})
$brT.Start()

# ---------------- brightness fade timer ----------------
$fadeT = New-Object System.Windows.Forms.Timer
$fadeT.Interval = 15
$fadeT.add_Tick({
    try {
        $to = $script:SpTarget
        if ($to -lt 0) { $fadeT.Stop(); return }
        $el = ((Get-Date) - $script:SpFadeStart).TotalMilliseconds
        if ($el -ge $script:SpFadeMs) {
            $v = $to
        } else {
            $p = $el / $script:SpFadeMs
            $ease = $p * $p * (3 - 2 * $p)
            $v = [int][math]::Round($script:SpFadeFrom + ($to - $script:SpFadeFrom) * $ease)
        }
        if ($v -ne $script:SpCurVal) {
            $r = [AtkAcpi]::Write([uint32]0x00050032, $v)
            if ($r -eq 1) { $script:SpCurVal = $v } else { $fadeT.Stop(); TL "fade write failed result=$r"; return }
        }
        if ($v -eq $to -and $el -ge $script:SpFadeMs) { $fadeT.Stop() }
    } catch { }
})


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
        try { $script:SpBurstUntil = (Get-Date).AddSeconds(6); if (-not $brT.Enabled) { $brT.Interval = $script:SpFastMs; $brT.Start() } } catch { }
        try { Sync-ScreenPad } catch { }
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
# ---------------- panel hooks: quick settings / settings app ----------------
# SHOW = 0x8002, HIDE = 0x8003
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PanelHook
{
    public delegate void WinEventDelegate(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr hmod, WinEventDelegate del, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);

    static WinEventDelegate _del;
    static IntPtr _hook;
    public static Action<uint, string, string> Sink;

    public static bool Install(Action<uint, string, string> sink)
    {
        Sink = sink;
        _del = (h, ev, hwnd, idObj, idChild, thread, time) =>
        {
            if (hwnd == IntPtr.Zero) return;
            try
            {
                var cls = new StringBuilder(128);
                GetClassName(hwnd, cls, 128);
                string c = cls.ToString();
                if (c != "ControlCenterWindow" && c != "ApplicationFrameWindow") return;
                var txt = new StringBuilder(256);
                GetWindowText(hwnd, txt, 256);
                var s = Sink;
                if (s != null) s(ev, c, txt.ToString());
            }
            catch { }
        };
        _hook = SetWinEventHook(0x8002, 0x8003, IntPtr.Zero, _del, 0, 0, 0);
        return _hook != IntPtr.Zero;
    }
    public static void Uninstall() { if (_hook != IntPtr.Zero) { UnhookWinEvent(_hook); _hook = IntPtr.Zero; } }
}
'@

$script:SpPeekCount = 0

try {
    $panelAction = [Action[uint32, string, string]] {
        param($ev, $cls, $txt)
        # 快速设置面板，或「设置」应用里的显示页
        $watched = ($cls -eq 'ControlCenterWindow') -or ($cls -eq 'ApplicationFrameWindow' -and $txt -match '设置|Settings')
        if (-not $watched) { return }
        if ($ev -eq 0x8002) {
            $script:SpPeekCount++
            try { if (-not $brT.Enabled) { $brT.Interval = $script:SpFastMs; $brT.Start() } } catch { }
            TL "panel shown ($cls) -> fast poll, open=$($script:SpPeekCount)"
        } elseif ($ev -eq 0x8003) {
            if ($script:SpPeekCount -gt 0) { $script:SpPeekCount-- }
            if ($script:SpPeekCount -eq 0) { TL "panel closed ($cls) -> back to idle" }
        }
    }
    $peekOk = [PanelHook]::Install($panelAction)
    TL "panel hook installed = $peekOk"
} catch {
    TL "panel hook failed: $($_.Exception.Message)"
}

[System.Windows.Forms.Application]::Run($form)
