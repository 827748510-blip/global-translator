# Global Translator

macOS 14+ 的终端启动式全局翻译工具。产物是 Apple Silicon 独立 Mach-O 可执行文件，不生成 `.app`、DMG 或 pkg；启动后处理当前活动窗口，通过 Accessibility 优先提取文本，必要时使用 Vision OCR，并用鼠标穿透的透明覆盖层显示简体中文。授予屏幕录制权限且自动翻译开启时，ScreenCaptureKit 对当前窗口持续进行最高 4 帧/秒、256×256 的本地变化检测，包括 Accessibility 能读取文字的窗口；检测帧不保存、不上传。这是用户于 2026-09-06 批准的滚动识别约束变更，不再承诺 AX 成功时完全不捕获画面。

## 环境要求

- Apple Silicon Mac
- macOS 14 或更高版本
- 建议至少 16 GB 内存
- Swift 6 工具链
- 辅助功能或屏幕录制权限至少一项；建议两项均授权，以支持完整的 AX/OCR 回退与滚动变化检测

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

当前严格并发验证通过 196 个测试、19 个测试套件；已使用真实 DeepSeek 和本机 Ollama 验证翻译链路。跨 App 交互证据及尚未达到的性能目标见 [当前真实验收记录](docs/real-acceptance-current.md)，本机启动方式见 [本地模型配置](docs/local-model-setup.md)。Release 产物为 arm64 Mach-O，未生成安装包，也不捆绑模型权重。

## 本轮可用性修复

已修复会话重建后覆盖层版本编号冲突、来源权限检查不一致和捕获/模型批次间的保护状态检查缺口。活动窗口描述暂时不可用时最多重试两次；仅屏幕录制权限模式通过系统窗口列表定位窗口。超过 4000 字符的可翻译 AX 区域改为可见画面 OCR 回退，缺少屏幕录制权限时明确提示，不再静默跳过。

只授权辅助功能时不会启动画面变化检测，滚动更新取决于目标 App 的 AX 通知支持。本轮没有放宽 24 区域上限、覆盖层 3 行上限或承诺亚秒速度。源码、测试与实际安装状态见 [可用性修复记录](docs/readiness-fixes-2026-09-06.md)。

## 已知系统限制

macOS 26 在当前机器上把裸可执行文件的 `NSStatusItem` 交给 ControlCenter 以 `.ephemeral`、`neverClip: false` 方式托管。菜单栏空间不足或系统布局裁剪时，`NSStatusItem.isVisible` 仍可能为 `true`，但图标像素不显示；公开 AppKit API没有强制优先级或 `neverClip` 选项。

代码仍使用标准方形 `NSStatusItem`、稳定 autosave 名称和 `NSPopover`，且 VoiceOver 可发现并能唤起弹窗。若必须在任何菜单栏布局下保证图标可见，只能释放菜单栏空间，或另行放宽“禁止 App Bundle/禁止备用配置入口”的产品约束。详见 [ADR-001](docs/decisions/001-bare-executable-status-item.md)。
