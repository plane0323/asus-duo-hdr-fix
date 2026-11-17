# 参与贡献

欢迎 Issue 和 PR。这个项目很小，没有繁琐流程，但以下几点能大幅提高沟通效率。

## 报告问题前

请先确认：

- [ ] 已阅读 README 的「风险与免责」与「已知限制」
- [ ] 已附上 `C:\Program Files\dwm_eotf_rs\tray.log` 与 `eotf_apply.log` 的相关片段
- [ ] 已说明 Windows 版本（`winver`）与机型

硬件相关的问题**必须**提供机型与显卡，否则基本无法定位。

## 提 Issue

使用仓库自带模板：

- **Bug**：用于「不工作 / 死机 / 黑屏 / 服务没起来」
- **Feature**：用于新功能建议

请避免在同一个 Issue 里混多个问题。

## 提 PR

1. 先开 Issue 说明要解决什么，避免白做
2. 从 `main` 拉分支，命名 `fix/xxx` 或 `feat/xxx`
3. 一个 PR 只做一件事
4. 提交信息用[约定式提交](https://www.conventionalcommits.org/zh-hans/)：`fix: ...` / `feat: ...` / `docs: ...`
5. 确保 `PSScriptAnalyzer` 无 Error 级告警（CI 会跑）
6. 涉及流程改动的，请在 PR 描述里写清「改前 / 改后」的行为差异

## 代码约定

- PowerShell 5.1 兼容（不要用 PS7 专有语法）
- **含中文的 `.ps1` 必须带 UTF-8 BOM** —— 否则 PS 5.1 会按 GBK 解析导致乱码甚至语法错误（这个坑本项目踩过多次）
- 纯 ASCII 的脚本不要加 BOM
- 日志一律带时间戳，关键步骤必须落盘（崩溃后要能复盘）
- 任何会终止 `dwm.exe` 的路径，都必须先经过「副屏栈已完全停止」的守卫
- 路径用 `$PSScriptRoot` 派生，不要硬编码安装目录

## 安全

安全问题请不要开公开 Issue，见 [SECURITY.md](SECURITY.md)。
