# ADR-002：桌面应用与独立设置窗口

日期：2026-09-07。状态：接受，用户在本任务明确回复“允许”。

用户无法找到菜单栏图标，已批准新增可双击的 `.app` 和独立设置窗口，保留现有菜单栏、翻译进程与 CLI。

使用同一 Swift 可执行文件封装 `Global Translator.app`，Bundle ID 为 `com.maodashu.global-translator`，安装到用户的 `~/Applications/`。CLI 安装路径链接到包内的程序，启动子进程前解析链接，保证后续启动也从包内运行。

桌面无参数启动会检查已有进程，经 Unix socket 的 `showSettings` 动作唤起原设置窗口。并发启动由原 PID 锁排他保护，唤起操作在有限时间内等待正在启动的 socket。所有入口共用 `ApplicationController`、`SettingsViewModel` 与原配置存储。

Dock 重开和菜单栏点击打开同一个窗口，关闭窗口保留翻译会话；退出经原 runner 停止会话、刷新配置并移除 PID/socket。正常编辑菜单支持设置输入框的剪切、复制、粘贴。

保留公开 AppKit API；不保证菜单栏在任意布局中都有空间。标准 Dock/Finder/CLI 入口解决设置不可达问题。Bundle 身份变化可能要求用户重新授权 TCC，构建脚本只做本机 ad-hoc 签名，不操作系统授权数据库，不发布或公证。
