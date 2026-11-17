# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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

[1.0.0]: https://github.com/plane0323/asus-duo-hdr-fix/releases/tag/v1.0.0
