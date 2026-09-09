# Global Translator

macOS 14+ 的全局翻译工具，提供可双击的 `Global Translator.app`、独立设置窗口、菜单栏图标及命令行入口。启动后处理当前活动窗口，通过 Accessibility 优先提取文本，必要时使用 Vision OCR，并用鼠标穿透的透明覆盖层显示简体中文。划选文字（滑词翻译）可在任意 App 的选区附近弹出译文，并可一键优化成通用生成提示词；默认开启、可在设置中关闭。授予屏幕录制权限且自动翻译开启时，ScreenCaptureKit 对当前窗口持续进行最高 4 帧/秒、256×256 的本地变化检测，包括 Accessibility 能读取文字的窗口；检测帧不保存、不上传。

## 环境要求

- Apple Silicon Mac
- macOS 14 或更高版本
- 建议至少 16 GB 内存
- Swift 6 工具链
- 辅助功能或屏幕录制权限至少一项；建议两项均授权，以支持完整的 AX/OCR 回退与滚动变化检测

## 构建与安装

```bash
bash scripts/package-app.sh
```

产物位于 `.build/desktop/Global Translator.app`，包含蓝色“译”字图标及本机 ad-hoc 签名（未公证）。首次安装可将它复制到 `~/Applications/`，并让 `~/.local/bin/global-translator` 链接到包内的 `Contents/MacOS/global-translator`；升级前先停止旧进程并备份已有应用及命令行入口。CLI 链接与 `.app` 使用同一份可执行文件，配置路径保持不变。

双击应用或点击 Dock 中的蓝色“译”字图标即可打开设置，菜单栏图标也打开同一个窗口。关闭窗口后继续翻译；使用“退出全局翻译”或 `⌘Q` 完全退出。再次打开只唤起已有进程。更换为 `.app` 身份后，macOS 可能要求在设置窗口中重新授予辅助功能／屏幕录制权限。

1.1.1 修复退出后残留通信文件导致的 Finder 双击无反应；启动会恢复失效的 socket，其他启动失败会弹出错误提示。实机验证见 [Finder 启动修复记录](docs/finder-launch-fix-2026-09-07.md)。

1.1.2 增加返回应用时自动刷新权限及“重新检查”按钮。当前本机构建使用 ad-hoc 签名，更新后旧版授权可能不再匹配新版；遇到系统已开启但应用仍显示未授权时，需要为当前版本重新授权并重启。诊断证据见 [权限刷新记录](docs/permission-refresh-2026-09-07.md)。

确保 `~/.local/bin` 已加入 `PATH`，然后也可使用：

```bash
global-translator doctor
global-translator start
global-translator settings
global-translator status
global-translator logs --follow
global-translator stop
```

开发调试可执行：

```bash
global-translator run --foreground
```

`start` 在后台启动并快速返回；关闭终端不会停止进程。系统重启或注销后不会自动启动。

## 后端

### DeepSeek 云端

- 固定官方基址：`https://api.deepseek.com`
- 固定模型探测：`deepseek-v4-flash-vision-exp`
- Key 只保存在 macOS 登录 Keychain，Service 为 `com.maodashu.global-translator.deepseek`
- 默认只发送待翻译文字；局部截图视觉兜底必须在弹窗中明确授权
- 不自动切换到本地后端，不自动重放状态不确定的请求

选择云端后端启动时，会探测该实验模型是否仍在账号的 `/models` 列表中。已在用户授权下验证真实 DeepSeek 接口；自动化测试使用 mock，不自动调用计费接口。详细结果见 [真实云端验收记录](docs/real-acceptance-2026-09-05.md)。

### 本地模型

- 默认基址：`http://127.0.0.1:11434/v1`
- 只接受 `localhost`、`127.0.0.1` 或 `::1` 的 HTTP 地址
- 支持 Ollama 等 OpenAI 风格的 `/models` 与 `/chat/completions`
- 健康检查会验证服务、已选模型和一次结构化翻译样例
- 工具不下载模型、不启动模型服务，也不发送截图给本地模型

## 数据与安全

- 普通配置：`~/Library/Application Support/GlobalTranslator/config.json`，权限 `0600`
- PID/socket：`~/Library/Application Support/GlobalTranslator/runtime/`
- 脱敏日志：`~/Library/Logs/GlobalTranslator/`，权限 `0600`
- API Key 不进入配置、参数、环境、日志或翻译缓存
- 截图、原文、译文和翻译缓存均不持久化
- 滑词翻译仅监听鼠标左键抬起以读取 Accessibility 选区；不注入键盘。AX 读不到字时，仅在真实拖选后（或 AX 报告有选区范围却无字符串）、且剪贴板能完整备份时才临时 ⌘C 并立即恢复；单击不拖选不发 ⌘C。备份不全、密码框、本应用窗口则跳过。弹层提供翻译与「优化提示词」（通用生成提示词，非即梦/可灵专用）
- 不修改第三方 App 中的文本（扩展桥 / CDP 入页翻译除外）

## 架构

- `GlobalTranslatorRuntime`：CLI、单实例、后台进程、Unix socket、日志与 doctor
- `GlobalTranslatorCapture`：活动窗口、Accessibility、ScreenCaptureKit、Vision OCR
- `GlobalTranslatorCore`：配置、Keychain、HTTP 与双后端适配
- `GlobalTranslatorEngine`：过滤、批处理、缓存、调度、熔断与旧结果淘汰
- `GlobalTranslatorUI`：状态项、独立设置窗口和透明覆盖层
- `GlobalTranslatorApp`：生命周期与模块装配

## 验证

```bash
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

已使用真实 DeepSeek 和本机 Ollama 验证翻译链路。跨 App 交互证据及尚未达到的性能目标见 [当前真实验收记录](docs/real-acceptance-current.md)，本机启动方式见 [本地模型配置](docs/local-model-setup.md)。新版应用的构建和实机结果见 [桌面应用验收记录](docs/desktop-app-2026-09-07.md)。滑词翻译的开关、权限与验证步骤见 [滑词翻译](docs/selection-translate.md)。应用不捆绑模型权重。

## 本轮可用性修复

已修复会话重建后覆盖层版本编号冲突、来源权限检查不一致和捕获/模型批次间的保护状态检查缺口。活动窗口描述暂时不可用时最多重试两次；仅屏幕录制权限模式通过系统窗口列表定位窗口。超过 4000 字符的可翻译 AX 区域改为可见画面 OCR 回退，缺少屏幕录制权限时明确提示，不再静默跳过。

只授权辅助功能时不会启动画面变化检测，滚动更新取决于目标 App 的 AX 通知支持。本轮没有放宽 24 区域上限、覆盖层 3 行上限或承诺亚秒速度。源码、测试与实际安装状态见 [可用性修复记录](docs/readiness-fixes-2026-09-06.md)。

## 已知系统限制

macOS 26 在当前机器上把裸可执行文件的 `NSStatusItem` 交给 ControlCenter 以 `.ephemeral`、`neverClip: false` 方式托管。菜单栏空间不足或系统布局裁剪时，`NSStatusItem.isVisible` 仍可能为 `true`，但图标像素不显示；公开 AppKit API没有强制优先级或 `neverClip` 选项。

新版使用标准 `.app` 身份、方形 `NSStatusItem` 和稳定 autosave 名称。菜单栏仍由 macOS 排布，空间不足时请通过 Dock、双击应用或 `global-translator settings` 打开设置。用户已批准 `.app` 与独立窗口，[ADR-001](docs/decisions/001-bare-executable-status-item.md) 中的旧产品约束已被 [ADR-002](docs/decisions/002-desktop-settings-entry.md) 取代。
