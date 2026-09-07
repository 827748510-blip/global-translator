# 桌面应用交付与验收

后续用户报告 Finder 双击无反应，已在 1.1.1 修复残留 socket 阻塞启动，并完成真正 Finder 双击、关闭重开和退出后重启的验收。最新状态见 [Finder 启动修复](finder-launch-fix-2026-09-07.md)；下文保留 1.1.0 的历史记录。

用户已明确批准可双击的 `.app` 和独立设置窗口。当前修改保留在 `codex/fix-overlay-flicker`，包含此前的覆盖层稳定性与文字筛选修复，本次未提交或推送 Git。

## 已安装

- 应用：`~/Applications/Global Translator.app`，1.1.0（20260907）。
- Bundle ID：`com.maodashu.global-translator`；蓝底“译”字应用图标。
- CLI：`~/.local/bin/global-translator` 链接到包内程序，所有入口共用原 PID/socket 和配置。
- 安装程序 SHA-256：`1d86ba928956dbb5b8f153571ff5d91c7c30575fbabe8ba44137af5a0dd42547`，与最终构建包内程序一致。
- 原程序和配置备份：`~/.local/share/global-translator/backups/20260907-000629-desktop/`。
- 安装及生命周期检查后，原 `config.json` 与备份逐字节一致。本地模型和排除列表保留，未访问或修改云端密钥。

## 验证结果

- `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`：214 tests / 21 suites 通过。
- `bash scripts/package-app.sh`：严格 Release 构建、本机 ad-hoc 签名和验证通过；已安装包通过 `codesign --verify --deep --strict`。
- `git diff --check`、打包脚本语法和 Info.plist 格式检查通过。
- 双击等效的 LaunchServices `open` 启动显示完整设置窗口。实机发现并修复 SwiftUI ScrollView 无固定高度造成的窗口压缩。
- 实际点击“测试连接”返回 `Local backend is ready`，选中原本地模型。
- 连续三次 `open`、两次 CLI `settings` 保持同一 PID；关闭窗口后重开保留输入草稿，测试草稿已恢复。
- `⌘Q` 实测发现过旧 PID/socket 残留，已让菜单退出走设置按钮相同的异步清理流程；最终版本复验进程停止且 PID/socket 均移除。
- 停止状态下 CLI `start`、`settings` 可重新启动包内程序，并继续保持单实例；CLI `stop` 清理通过。
- 最终通过 `.app` 打开，交付时运行 PID 30169。截图保存在本机 `.git/task-evidence/desktop-app/settings-window.png`，不提交原始截图。

激活真实窗口的自动化测试会触发同时执行的活动窗口监测测试，已将窗口操作放到上述实机流程验证；原有监测测试保留并全通过。

## 尚需用户操作与边界

LaunchServices 启动的新版应用显示辅助功能、屏幕录制均未授权，自动翻译开关因此禁用。需要用户在窗口的“系统权限”区域为新版应用授权，之后开启自动翻译。代码保留原自动翻译偏好；不得把进程 `running` 等同于翻译已就绪。

从已有授权终端启动时曾观察到两项权限已授权，但这不能代表用户双击启动的授权状态；最终按 `.app` 启动的未授权状态交付。未修改系统授权数据库或替用户授予权限，尚未复验新版 `.app` 身份下的完整捕获翻译流程。此前覆盖层稳定性及文本筛选的实机证据见 `overlay-flicker-and-text-selection-2026-09-06.md`。

Dock/ControlCenter 的 Computer Use 读取超时，因此没有声称已验证当前菜单栏图标的可见像素；用户可通过可双击应用、独立窗口和 CLI settings 操作。只使用公开 AppKit API，本次未公证或公开发布。

## 回退

先退出应用，确认进程已停止，再把 CLI 链接移动到备份位置，并将上述备份中的原 `global-translator` 复制回 `~/.local/bin/global-translator`，保留执行权限。新版 `.app` 可保留在备份目录；普通配置未改变，无需覆盖。重新运行 CLI `start` 即恢复此前的裸程序入口。
