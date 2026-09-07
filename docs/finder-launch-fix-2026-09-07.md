# Finder 双击无反应修复（1.1.1）

## 复现与原因

用户在 Finder 双击 `~/Applications/Global Translator.app` 后没有窗口。实机复现时程序未运行、PID 文件不存在，但上次运行的 `control.sock` 仍残留。直接执行包内程序返回退出码 1：`错误：控制 socket 已被占用`。

CLI `start` 原先会清理失效 socket，桌面入口直接启动 `RuntimeWorker`，遗漏了同等恢复逻辑。Finder 启动时终端错误不可见，因此表现为双击无反应。此前使用 `open`／命令行启动的验收没有覆盖这一现场。

## 修复

- `RuntimeWorker.start()` 在取得 PID 排他锁后检查遗留通信文件；仅清理当前用户拥有、连接明确被拒绝且 inode 未变化的 socket。
- 连接成功、连接状态不确定、普通文件或符号链接均拒绝清理。CLI 与桌面入口复用恢复函数。
- 活动 socket 探测的连接断开场景暴露 SIGPIPE 异常退出；通信写入增加每次发送的 `MSG_NOSIGNAL`，保留原有错误返回，不设置全局忽略信号。
- 桌面启动失败时显示错误弹窗，CLI 继续使用原退出码及标准错误输出。
- Bundle 版本更新为 1.1.1（2026090702）。

## 验证

- 新增直接启动恢复残留 socket 的回归测试，修复前失败并准确报 `socketInUse`，修复后通过。
- 覆盖活动端点无 PID 时仍受保护、连续 10 次探测断开、普通文件和符号链接内容保留。
- 严格并发、warnings-as-errors：217 tests / 21 suites 通过；Release 构建和包签名验证通过。
- 安装时保留现场失效 socket，确认 inode 未变，没有手工删除残留文件或先用 CLI 启动。
- 使用 Computer Use 在 Finder 真正双击图标后，应用启动 PID 59075，完整设置窗口显示；恢复后关闭窗口再双击，仍使用 PID 59075。
- `⌘Q` 后进程停止且 PID/socket 均删除；再次从 Finder 双击，启动 PID 60392 并显示窗口。
- 配置与安装前备份逐字节一致。最终仍显示辅助功能／屏幕录制未授权，自动翻译需要用户授予新版系统权限；此项与窗口打不开的问题分开验收。

测试中曾用临时 SIGPIPE 栈记录诊断问题，诊断代码已删除。最终测试保留全部用例，无跳过或全局信号屏蔽。

## 安装与证据

- 安装位置：`~/Applications/Global Translator.app`，CLI 链接保持不变。
- 包内程序 SHA-256：`84faa4a6c812e4ef21d3a7c90749d1f1348880b9c80c134d2d089b4b3d293bc6`。
- 原应用及配置备份：`~/.local/share/global-translator/backups/20260907-100111-finder-launch/`。
- 本地证据目录：`.git/task-evidence/finder-launch/`，包括修复前失败测试、最终测试、构建日志和设置窗口截图；不提交截图。
- 沿用当前 `codex/fix-overlay-flicker` 分支，未提交或推送。
