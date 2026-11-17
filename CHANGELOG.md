# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.2.0] - 2026-11-17

### 新增：SDR / HDR 双模式映射

- SDR 与 HDR 各自独立的映射区间，不再共用一条曲线
- 默认：SDR `28% → 100%`（下限 84/255）；HDR `50% → 100%`（下限 42/255）
- 主屏超过"满亮"点后副屏锁定 255
- HDR 状态每次同步实时读取，切换模式后自动重算并同步

### 新增：映射设置对话框

- 托盘菜单「亮度映射设置…」修改四个值：两种模式的满亮主屏亮度与副屏下限
- 保存在安装目录 `eotf_brightness.json`，启动时自动读回
- 保存后立即重新同步一次

### 变更

- 亮度下限从全局百分比常量改为每模式独立的下限值（0-255），更贴近真实面板表现

## [1.1.0] - 2026-11-17

### 新增：副屏亮度跟随主屏

- 主屏亮度 0–50% 时副屏按 ×2 映射（0–100%）；主屏 ≥51% 时副屏固定 100%
- 主屏 0% 时副屏保底 `10/255`（约 4%），不会把背光写灭
- 走 ASUS ACPI `DEVS 0x00050032`，是**真实背光**调节，不是软件压暗
- 每个周期读硬件实际值再比对，外部改动会被纠正
- 托盘开关「副屏亮度跟随主屏」，关闭时立即把副屏恢复到 100%

### 新增：面板事件钩子

- `SetWinEventHook(EVENT_OBJECT_SHOW/HIDE)` 匹配 `ControlCenterWindow`（Win+A）与「设置」应用（Win+I）
- 用 SHOW/HIDE 计数判断，支持一个面板由多个窗口组成的情况
- 面板打开 → 采样率切到 300ms；面板关闭 → **立即停止轮询**
- 空闲时完全不轮询，后台开销为 0

### 已知限制

- 用 Fn 亮度键调主屏时不会触发同步（ASUS EC 事件队列 `ATK4001` 在本机型上不可用）
- 同步开启时，手动调副屏亮度会在下一次采样时被拉回映射值

## [1.0.0] - 2026-11-17

首个公开版本。

### 新增

- 托盘程序：Gamma 2.0 / 2.2 / 2.4 切换、关闭补丁（恢复 sRGB）、MPO 开关、副屏栈手动启停、开机自启
- 安全打补丁流程：停副屏栈 → 守卫复查 → 调用 `dwm_eotf_rs -c` → 拉起副屏栈
- 守卫机制：副屏栈未完全停止时中止，绝不动 `dwm.exe`
- 状态判断：基于状态文件中的 `dwm_pid` 与当前 `dwm.exe` 比对，DWM 未重启则不重复打补丁
- HDR 自动跟随：监听 `SystemEvents.DisplaySettingsChanged`（即 `WM_DISPLAYCHANGE`），HDR 开启时自动重打
- 启动类型联动：「开机自启」开关同时管理计划任务与 `AsusScreenXpert` / `AsusScreenXpertHostService` 的启动类型
- `install.ps1`：一键安装，校验 `dwm_eotf_rs.exe` 的 SHA-256
- `uninstall.ps1`：一键还原，恢复 ASUS 原生行为

### 已知问题

- 每次打补丁会黑屏约 6 秒（停服务 + 重启 DWM 的必然代价）
- 补丁仅存在于 DWM 进程内存，DWM 重启后失效（托盘会自动重打）
- 若托盘未能启动，副屏栈会保持手动启动状态，ScreenPad 控制功能不可用，需用 `uninstall.ps1` 恢复

### 说明

本项目的存在意义是绕开一个特定死锁：外部强杀 `dwm.exe` 时，`AsusScreenXpert` 在显示拓扑变更路径上可能导致整机硬锁死（无蓝屏、无 dump、无 TDR）。上游 `dwm_eotf_rs` 每次打补丁都会强杀 DWM，因此在受影响机型上不可直接使用。

[1.2.0]: https://github.com/plane0323/asus-duo-hdr-fix/releases/tag/v1.2.0
[1.1.0]: https://github.com/plane0323/asus-duo-hdr-fix/releases/tag/v1.1.0
[1.0.0]: https://github.com/plane0323/asus-duo-hdr-fix/releases/tag/v1.0.0
