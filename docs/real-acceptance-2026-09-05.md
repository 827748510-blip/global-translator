# 2026-09-05 真实验收记录

后续本地模型安装和跨 App 验收进展见 [2026-09-06 记录](real-acceptance-2026-09-06.md)。本文保留当时结果，不代表最新验收结论。

结论：真实 DeepSeek 翻译、Safari 两段文字的应用内翻译/缓存路径、受控覆盖层渲染及真实 Vision OCR 已验证。完整跨 App、屏幕捕获、输入穿透和性能验收尚未完成，不作为完整交付通过记录。

代码基线：`683b2c1c498d4fcbc7f28996c28dac65c9b3e057`。本轮修复位于 `codex/real-deepseek-acceptance` 工作区，尚未提交或推送。

## 已观察结果

| 项目 | 证据与结果 | 验收范围 |
| --- | --- | --- |
| DeepSeek 凭据 | 从 CC Switch DeepSeek 配置读取，写入 GlobalTranslator 登录 Keychain，并在内存比较一致 | 未显示 Key；保留本地 Keychain 条目 |
| 模型探测 | 官方 `/models` 返回 `deepseek-v4-flash-vision-exp`；生产适配器健康状态 `healthy` | 仅证明当前账号、当前接口可用 |
| 真实翻译 | 生产 `DeepSeekBackend` 翻译固定英文句成功；版本号、区域 ID 匹配；耗时 1440 ms | 单次样例，不是 p50/p95 |
| Safari 捕获 | 生产 Accessibility 采集器读到 14 个区域，包含两段固定测试文字；一次读取 89 ms | 未证明所有网页/滚动状态 |
| Safari 应用内翻译 | 15:16:00.239 UTC：`engine_completed`、`status=success`、`translated_count=2`、`duration_ms=1837` | 应用日志证据；不是覆盖层截图证据 |
| 内存缓存 | 后续五条 `cacheOnly` 日志各有两段译文，耗时整数记录为 0 ms | 不将日志分辨率下的 0 ms 理解为物理零耗时 |
| 真实覆盖层 | 独立驱动调用生产 `DeepSeekBackend`、`OverlayPanelController`；真实面板数为 1；检查自身 NSView 渲染图可见完整中文 | 固定测试文字、受控坐标；未包含第三方窗口截图 |
| 覆盖层属性 | `mouse_passthrough=true`、`nonactivating=true`、`foreground_unchanged=true`、`rendered_text_matches=true`；隐藏后面板数 0 | 属性与焦点观测通过；不能代替真实鼠标穿透点击验收 |
| 本机 Vision OCR | 对内存生成的固定英文测试图调用生产 `VisionOCRService`，识别匹配，1 个区域，514 ms | 冷启动单样本；未证明快速 OCR p95 ≤400 ms |
| 系统权限 | Release 可执行文件在正常宿主执行 `doctor`：辅助功能、屏幕录制预检、Keychain 读取通过 | 工具沙箱内会产生未授权结果；本表采用正常宿主结果 |
| 生命周期 | 连续两次 `start` 返回相同 PID 28314；`status` 正常；`stop` 后最终 PID/socket 均消失 | 同一宿主调用内验证；独立 Terminal 窗口关闭后存活未重验 |
| 自动化测试 | 严格并发全量复跑：155 tests、15 suites 通过 | 首次全量曾出现退出时序失败，见下文 |
| Release | `swift build -c release -Xswiftc -strict-concurrency=complete` 成功 | arm64 Mach-O；未生成安装包 |

## 修复的真实故障

DeepSeek 实际返回 HTTP 200，`output` 包含 `reasoning` 和 `message` 两项。原解析器要求整个数组恰好一项，因此抛出 `invalidResponse("response output message is missing or ambiguous")`。

新增回归测试先失败、修复后通过。修复仅允许附带 `reasoning`，仍要求恰好一个 `message`、恰好一个 `output_text`，仍校验译文 ID、数量和文本长度，其他输出类型仍拒绝。

变更：`Sources/GlobalTranslatorCore/AdapterSupport.swift`、`Tests/GlobalTranslatorCoreTests/GlobalTranslatorCoreTests.swift`。

## 尚未通过或被阻塞的项目

- 本地真实模型：未找到 `ollama` 命令，正常宿主请求 `127.0.0.1:11434/v1/models` 连接失败。没有安装、下载模型或启动模型服务。
- 完整 App 矩阵：Chrome、Finder、Terminal、Electron、Preview PDF/图片的完整自动捕获→翻译→覆盖层交互尚未验证。
- 真实 ScreenCaptureKit→OCR 回退、滚动/移动/缩放后的视觉定位、跨桌面空间、睡眠恢复、4K 缩放尚未完整验证。
- 密码框、安全输入、锁屏、撤销权限等真实系统场景尚未重验；单元测试不能替代这些场景。
- Safari 全屏与重载操作已执行，但窗口级截图未包含独立覆盖层，不能据此确认全屏叠加效果。
- 图形验收工具多次报告 ScreenCaptureKit `-3811`。一次复查被自动审批拒绝，理由是 Safari 可访问结构包含书签/潜在私有链接。随后停止自动云端捕获；替代驱动只翻译代码内固定文字并截取自身 NSView，未绕过该拒绝。
- 首次严格全量测试发生 `runnerStartsWorkerBeforeControllerAndStopsLoopAfterWorkerStop` 的 `stopCount=2`（期望 1）。该组单独复测 3 项通过，随后全量 155 项通过。仍记录为退出时序不稳定线索，本轮未修改相关代码。
- PID/socket 最终会清理，但本次立即紧随 `stop` 的文件存在性检查曾失败，随后目录为空；不能声称 `stop` 返回时文件必定已经清理。
- 单次延迟和进程瞬时资源读数不构成 p95、平均空闲 CPU、内存上限或主线程 16 ms 指标验收。
- 既有裸可执行文件菜单栏图标被系统裁切的限制仍见 `decisions/001-bare-executable-status-item.md`。

## 安全与收尾

本轮确实调用了计费翻译接口，包括诊断和重测；被取消或结果被淘汰的请求是否计费不能由本机成功日志推断，准确费用以 DeepSeek 账单为准。未开启云端视觉回退。

验收结束后关闭自动翻译并停止隔离实例，清理临时驱动、测试配置、测试图片和日志。Keychain 条目保留；既有 `.codegraph` 不修改。本记录仅保留固定测试样例和脱敏计数，不保存用户窗口原文、译文或密钥。
