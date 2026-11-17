# ASUS Duo HDR Fix 

> 面向 ASUS 冰刃 Duo / 双屏机型：应用 dwm_eotf_rs 的 HDR 转换曲线补丁，同时绕开会让整机死锁的 DWM 重启问题。

Windows 下修复「开启 HDR 后 SDR 内容发灰发白」的托盘工具。

它调用 [dwm_eotf_rs](https://github.com/SERGEYDJUM/dwm_eotf_rs) 打补丁，但额外解决了一个会让某些机器**整机死锁**的问题。

> 一句话区别：原版每次打补丁都会**强杀 dwm.exe**；本工具在杀之前会把会因此死锁的显示器服务先安全停掉，打完再拉起来。

---

## 它解决的具体问题

在部分 **ASUS 冰刃 Duo / 双屏**机型上，外部强杀 `dwm.exe` 会导致整机硬锁死：

- 不发蓝屏、不写 dump、不报 TDR
- NumLock 灯都不亮
- 只能长按电源

原因是 `AsusScreenXpert` 与 `AsusScreenXpertHostService` 监听了显示拓扑变化。DWM 被强杀会强制触发一次 modeset，它在这条路径上死锁在内核里。

**Windows 自己重启 DWM 不会触发**（优雅退出、拓扑不变），只有外部 `TerminateProcess` 会。

## 本工具的做法

```
开机
 └ 副屏栈启动类型被设为 Manual，不随开机启动
登录 +2s → 托盘启动
     +3s → 自检：状态文件里的 dwm_pid 与当前 dwm 是否一致
            ├ 不一致 → 停副屏栈 → 守卫复查 → dwm_eotf_rs -c → 拉起副屏栈
            └ 一致   → 跳过补丁，仅确保副屏栈在运行
```

关键点：

1. **守卫**：只要副屏栈没停干净就中止，绝不冒险动 DWM
2. **状态判断**：DWM 没重启过就不会重复打补丁，无多余黑屏
3. **HDR 跟随**：监听 `SystemEvents.DisplaySettingsChanged`（即 `WM_DISPLAYCHANGE`），HDR 开启时自动重打
4. **启动类型联动**：托盘的「开机自启」开关同时管理计划任务与副屏栈的启动类型

## 副屏亮度跟随（冰刃 Duo）

主屏亮度映射到副屏，**走 ASUS ACPI 的真实背光调节**（`DEVS 0x00050032`），不是软件压暗：

| 主屏 | 副屏 |
|---|---|
| 0% | 10/255（官方下限，约 4%） |
| 25% | 128/255（50%） |
| 50% | 255/255（100%） |
| 51–100% | 255/255（100%） |

触发方式是**面板事件钩子**：`SetWinEventHook` 监听 `ControlCenterWindow`（Win+A）与「设置」应用（Win+I）的显示/隐藏。

- 面板打开 → 采样率 300ms，拖滑块时副屏实时跟随
- 面板关闭 → **立即停止轮询**
- 空闲时完全不轮询，后台开销为 0

已知限制：用 Fn 亮度键调主屏时不会触发同步（ASUS EC 事件队列 `ATK4001` 在本机型不可用），需要打开一次面板，或在托盘里用「立即同步副屏亮度」。

## 环境要求

- Windows 11（在 26H2 / build 26300 上验证）
- PowerShell 5.1（系统自带）
- 管理员权限（要停服务、重启 DWM）
- 需要自行准备 `dwm_eotf_rs.exe`（见下方安装说明）

## 安装

```powershell
# 以管理员身份运行
.\install.ps1
```

安装脚本会：

1. 把脚本复制到 `C:\Program Files\dwm_eotf_rs`
2. 若目录里没有 `dwm_eotf_rs.exe`，尝试从官方 Release 下载并校验 SHA-256
3. 注册登录计划任务 `dwm_eotf_tray`（延迟 2 秒、最高权限）
4. 把 `AsusScreenXpert` / `AsusScreenXpertHostService` 设为手动启动
5. 启动托盘

**如果你的机器不是 ASUS 双屏机型**，理论上不会有那个死锁，可以直接用原版 `dwm_eotf_rs.exe -c`，不需要本工具。

## 托盘菜单

| 项 | 说明 |
|---|---|
| Gamma 2.0 / 2.2 / 2.4 | 切换曲线，约 6 秒并黑屏一次 |
| 关闭补丁 | 恢复原始 sRGB |
| MPO 多平面叠加 | 切换 MPO，会重启 DWM 生效 |
| 副屏栈（冰刃 Duo） | 手动停止 / 启动副屏栈 |
| 副屏亮度跟随主屏 | 主屏 ≤50% 时副屏 ×2，>50% 时副屏 100%；关闭后副屏恢复 100% |
| 开机自启 | 注册/删除计划任务，并同步副屏栈启动类型 |

## 卸载

```powershell
# 以管理员身份运行
.\uninstall.ps1
```

会删除计划任务、恢复副屏栈为自动启动、并可选删除安装目录。

## 风险与免责

- ⚠️ **本工具会主动终止 `dwm.exe`**。这是让它生效的必要步骤，但属于有风险操作。
- ⚠️ Windows 自己重启 DWM 是协调过的；外部强杀不是。**在未知机型上有小概率触发类似的死锁。**
- ⚠️ 修改系统进程内存可能不符合 Microsoft 的许可条款。使用风险自负。
- ⚠️ 会停止/启动 ASUS 的显示器服务；在非 ASUS 机器上这些服务不存在，脚本会自动跳过。
- 本项目按 MIT 协议 **AS IS** 提供，不对任何数据丢失或系统损坏负责。

## 已知限制

- 补丁只存在于 DWM 进程内存中，DWM 重启即失效（托盘会自动重打）
- 每次打补丁会黑屏约 6 秒（停服务 + 重启 DWM 的必然代价）
- 如果托盘未能启动，副屏栈会保持手动启动状态（面板仍亮，但 ScreenPad 控制功能不可用），可用 `uninstall.ps1` 恢复

## 参与贡献

- 提 Issue / PR 前请先读 [CONTRIBUTING.md](CONTRIBUTING.md)
- 安全问题请勿公开报告，见 [SECURITY.md](SECURITY.md)
- 版本变更见 [CHANGELOG.md](CHANGELOG.md)

## 致谢与许可

- 补丁核心来自 [SERGEYDJUM/dwm_eotf_rs](https://github.com/SERGEYDJUM/dwm_eotf_rs)（MIT，© 2026 Sergey Dzhumageldiev），本项目不打包其二进制，需单独获取
- 曲线理论参考 [ledoge/dwm_eotf](https://github.com/ledoge/dwm_eotf) 与 [dylanraga/win11hdr-srgb-to-gamma2.2-icm](https://github.com/dylanraga/win11hdr-srgb-to-gamma2.2-icm)
- 本项目代码以 MIT 协议发布，见 [LICENSE](LICENSE)

---

## English summary

A Windows tray helper that applies the `dwm_eotf_rs` HDR/SDR transfer-curve patch **without** triggering a known hard-lock on ASUS dual-screen laptops.

The upstream tool always force-terminates `dwm.exe`. On some ASUS Zephyrus Duo machines, `AsusScreenXpert` deadlocks in the display-topology path when DWM is killed externally, freezing the whole system with no bugcheck. This wrapper stops that service stack first, verifies it is fully down, patches, then restarts it — and re-applies automatically when HDR is toggled.

No binary is bundled. MIT licensed. Use at your own risk.
