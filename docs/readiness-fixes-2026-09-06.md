# 2026-09-06 可用性缺陷修复记录

## 版本与范围

- 分支：`codex/readiness-fixes-20260906`，从本轮 fetch 后的 `origin/main`（`683b2c1c498d4fcbc7f28996c28dac65c9b3e057`）建立。
- 继承并保留此前未提交改动。此记录只描述本次新增修复，不将完整 HEAD diff 都算作本次工作。
- 本记录完成时尚未提交、推送、合并或安装到用户正式路径；后续 Git 提交与合并以仓库历史为准。正式翻译器 PID 11310 与用户 Ollama 保留运行。
- 新 Release SHA-256：`479b0e400cb9c2e991ddbf05a61e5d3afbe1ab5f748549e27316c8c00e405c0e`。
- 用户正在运行的 `~/.local/bin/global-translator` 仍为旧 SHA-256：`dbf531e125e0454075e0b6d87b6ba135c36dbd19a2ed19fc45a5e9e2b9f2812c`。源码修复不等于安装版已经更新。

## 修复结果

1. **会话编号隔离。** `ApplicationController.rebuildSession()` 新建覆盖层控制器。旧会话的失效编号继续阻止旧结果，但不再污染新监视器从 1 开始的结果。回归在旧 revision=50 后重建会话，新 revision=1 正常接受。
2. **来源权限一致。** `PermissionSnapshot.validateCapture` 按 AX/OCR 来源要求对应权限。AX-only 可显示 AX 文字；screen-only 可走 OCR，窗口位置通过 CoreGraphics 窗口列表回退。无屏幕录制权限不启动画面检测。缺失权限提示指明需要辅助功能还是屏幕录制。
3. **保护状态边界。** 捕获开始、AX/截图/OCR 返回、提交调度前、每批后端调用前后及最终输出前复查保护状态和来源权限。拒绝事件带 window revision，仅当前会话处理；进入保护状态后取消调度及后端在途任务，解除后恢复监视。不能撤回已经发出的请求，也不承诺与操作系统保护状态变化原子同步；本轮修复的是原来缺失的检查边界。
4. **窗口描述暂失恢复。** 对允许的前台应用，窗口描述暂时不可用时最多额外重试两次，每次间隔 350 ms；描述符重试与截图失败重试各有独立的两次预算，定位成功后不会耗尽后续截图恢复机会；停止、排除应用、没有前台应用和保护状态不会继续读取。加入 AX 不可用且有屏录权限时的正常窗口列表定位。历史 soak 首次漏采的唯一根因依然没有被独立证实，不能仅凭此重试修复宣称历史现象彻底消失。
5. **超长 AX 原文回退。** 可翻译 AX 区域超过 4000 字符时重新读取当前可见画面走 OCR；无屏录权限时明确报告所需权限。没有为全文虚构屏幕坐标，也没有放宽模型请求长度限制。只翻译当前可见内容，不承诺整篇文档导出。

## 改动模块

产品源码集中于 `ApplicationController`、`TranslationSession`、`CapturePipeline`、`ActiveWindowMonitor`/AX 扩展、`TranslationCoordinator`/scheduler/event contracts；新增 `CapturePermissionValidation.swift` 和 `WindowListDescriptor.swift`。

新增四个回归测试文件：`ApplicationReadinessTests.swift`、`CaptureReadinessTests.swift`、`EngineCaptureProtectionTests.swift`、`WindowReadinessTests.swift`。原有引擎测试显式注入授权快照，避免依赖运行测试机器的 TCC 授权。此前测试均保留。

## 验证证据

- 修复前，新增会话/权限/捕获保护/超长文本和批次保护用例均观察到预期失败；实现后通过。
- `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`：196 tests / 19 suites 全部通过（此前 177 tests / 16 suites，新增 19 个测试声明）。
- `swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`：退出 0，arm64 Mach-O。
- 关键源码与新增回归文件 LSP 检查无错误。语言服务曾因新文件未刷新报旧接口错误，重启该项目的 SourceKit 后消失；不是忽略真实编译错误。
- 独立 runtime root 下新版本 `start` → `status` → 重复 `start` → `stop` 全部通过；重复启动保持同一 PID，停止后 PID/socket 清理，正式用户实例不受影响。
- 直接链接新 Release 的真实 `TranslationCoordinator` 与 `LocalOpenAIBackend`，调用已有本机 Ollama：7 段合成英文，2 批，7 条中文结果，耗时 12325 ms。没有 mock 模型响应，没有调用计费云接口。模型仍可能改写短代码标识符（本轮将 `timeout_ms` 意译），不能把协议成功写成准确率全通过。
- 原生 TextEdit 合成文档已打开，隔离实例观察到捕获 4 个区域并提交；但前台采样持续为 Codex，未观察到本轮可靠的覆盖层完成。因此 GUI 端到端仍记未完成，不将此归因为新产品缺陷。测试实例已停止，测试文档已关闭。

本机原始日志、基线快照、临时驱动位于 `/private/tmp/global-translator-fixes-9DWMMJ`，权限受控，不进入 Git。截图未写入仓库，日志不记录用户原文、译文或密钥；实际本地模型样例均为本轮合成文本。

## 仍保留的限制

24 区域上限、覆盖层最多 3 行、复杂窗口首译偏慢、菜单栏裁切、多屏/4K、真实锁屏/睡眠恢复和持续翻译负载验收仍需后续工作。只授权 AX 时，缺少滚动 AX 通知的应用不会获得画面变化检测。这轮不承诺全面正式验收或稳定亚秒翻译。

## 复核处理

只读复核提出共享重试预算会阻止后续截图恢复，已用失败回归复现并将两类预算分开。复核另建议 AX-only 在 AX 窗口暂不可读时立即因屏录缺失而停止；此建议未采纳，因为 AX 是已授权来源，临时定位失败应允许有界重试，不能把可选 OCR 回退未授权误当成 AX 无权读取。新增测试证明仅 AX 授权时仍能从首次 nil 恢复；实际截图权限拒绝仍走明确提示，不发起捕获重试。

最终补测：窗口两类重试预算分离后，全量 196 tests / 19 suites 再次通过，Release 严格构建再次通过；最终产物 SHA 见本页版本信息。该产物另起独立进程完成 start/status/stop，运行目录清空，正式 PID 11310 仍运行。此前 7 段真实模型结果验证相同引擎修复代码，发生在最后一次仅调整窗口重试计数之前，不冒充新的整窗性能基准。

只读补审结果：PASS（窗口重试最终差异）。确认两类预算独立、共享可取消任务、每类最多两次、成功定位不耗尽后续截图恢复预算；AX-only 瞬态查询仍可恢复。该结论绑定本页列出的最终源码与 Release SHA，不构成全部硬件/真实 GUI 场景的发布批准。

后续授权：用户已明确要求提交、推送并合并本轮代码与验收记录。此操作不包含替换正在运行的本机安装版。
