# Global Translator

macOS 14+ 的终端启动式全局翻译工具。产物是 Apple Silicon 独立 Mach-O 可执行文件，不生成 `.app`、DMG 或 pkg；启动后处理当前活动窗口，通过 Accessibility 优先提取文本，必要时使用 ScreenCaptureKit 与 Vision OCR，并用鼠标穿透的透明覆盖层显示简体中文。

## 环境要求

- Apple Silicon Mac
- macOS 14 或更高版本
- 建议至少 16 GB 内存
- Swift 6 工具链
- 辅助功能或屏幕录制权限

## 构建与安装

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 0755 .build/release/global-translator ~/.local/bin/global-translator
```

确保 `~/.local/bin` 已加入 `PATH`，然后使用：

```bash
global-translator doctor
global-translator start
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

该实验模型是否仍在账号的 `/models` 列表中会在每次启动时重新探测。本项目测试未调用真实、可能计费的云端接口。

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
- 不监听或注入鼠标键盘，不修改剪贴板或第三方 App 内容

## 架构

- `GlobalTranslatorRuntime`：CLI、单实例、后台进程、Unix socket、日志与 doctor
- `GlobalTranslatorCapture`：活动窗口、Accessibility、ScreenCaptureKit、Vision OCR
- `GlobalTranslatorCore`：配置、Keychain、HTTP 与双后端适配
- `GlobalTranslatorEngine`：过滤、批处理、缓存、调度、熔断与旧结果淘汰
- `GlobalTranslatorUI`：状态项、设置弹窗和透明覆盖层
- `GlobalTranslatorApp`：生命周期与模块装配

## 验证

```bash
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

当前实现通过 154 个测试、15 个测试套件；真实本地 mock 链路已观察到活动窗口捕获、结构化翻译、缓存命中、覆盖层绘制、单实例与优雅退出。Release 产物为 arm64 Mach-O，未生成安装包或模型权重。

## 已知系统限制

macOS 26 在当前机器上把裸可执行文件的 `NSStatusItem` 交给 ControlCenter 以 `.ephemeral`、`neverClip: false` 方式托管。菜单栏空间不足或系统布局裁剪时，`NSStatusItem.isVisible` 仍可能为 `true`，但图标像素不显示；公开 AppKit API没有强制优先级或 `neverClip` 选项。

代码仍使用标准方形 `NSStatusItem`、稳定 autosave 名称和 `NSPopover`，且 VoiceOver 可发现并能唤起弹窗。若必须在任何菜单栏布局下保证图标可见，只能释放菜单栏空间，或另行放宽“禁止 App Bundle/禁止备用配置入口”的产品约束。详见 [ADR-001](docs/decisions/001-bare-executable-status-item.md)。
