# 翻译器可用性缺陷修复计划

目标：修复上一轮审查确认的会话 revision 冲突、权限门禁不一致、保护状态发送边界、首次窗口描述暂失和超长 AX 原文静默跳过。
分支：codex/readiness-fixes-20260906，自本轮 fetch 后 origin/main 683b2c1c498d4fcbc7f28996c28dac65c9b3e057 建立；保留所有既有未提交源码、测试与文档。

约束：macOS 14+ / Swift 6 / Apple Silicon；保持裸 Mach-O、双后端、Keychain、内存缓存与云视觉 opt-in；不提交、推送、发布，不调用真实云端计费接口。当前模型按用户非 Sol 门禁直接执行，不调用 CLI 子代理。所有源码修改均在本工作目录；临时日志另存本机临时目录。

- [x] 会话隔离：先用真实 OverlayPanelController + ApplicationController 设置变更的回归测试复现；ApplicationController.rebuildSession 重建 overlay，使新 monitor 的 revision 不与旧面板冲突。
- [x] 权限与保护：先测试 AX-only/OCR-only 显示、撤权/安全输入发生在捕获 await 期间、发生在第二批发送前的请求计数；PermissionSnapshot 集中校验来源，CapturePipeline/TranslationSession/TranslationCoordinator 在对应边界校验，保护暂停取消在途任务并恢复监视。
- [x] 初始窗口恢复：对允许的前台应用描述符暂时为空添加有界重试与测试；无前台应用、排除应用、保护状态和停止后不持续轮询。保留历史首轮漏采根因尚未独立确认的事实。
- [x] 长 AX 文本：为超过模型单请求限制的单个 AX 区域增加可读的回退或拆分路径；用真实管线回归证明不会直接以空译文结束，不伪造屏幕坐标，不放宽 24 区域或单请求大小限制。
- [x] 验证与收尾：逐项记录失败→通过证据；完整 strict-concurrency + warnings-as-errors 测试及 Release 构建；运行本地适配器和 CLI/隔离实例的真实场景；更新修复记录和现有限制。安装版变更须由当前任务授权范围明确后执行，源码修复不等于已上线。

本轮不承诺全部应用全文亚秒翻译、不新增分发形式，不把未执行的多屏/真实锁屏场景写成通过。

阶段证据：session-red.log / capture-red.log / engine-protection-red.log / window-red-engine-green.log 均观察到预期失败；capture-session-green.log（9 tests）、window-green.log（3 tests）、window-red-engine-green.log 中 EngineCaptureProtectionTests 全通过。日志目录 /tmp/global-translator-fixes-9DWMMJ。长 AX 文本采用当前可见画面 OCR 回退，无屏幕录制权限时明确报告缺权限，不伪造长文分段坐标。

新增核对：仅屏幕录制权限的窗口位置查询现已通过 CoreGraphics 正常窗口列表回退，不依赖 AX；测试覆盖排序、所属 PID、隐藏/非正常窗口及权限/保护拒绝。完整 196 tests / 19 suites 通过，Release 构建通过，14 个关键源码/新增测试文件 LSP 无错误。独立 CLI 实例启动/重复启动/停止均通过；生产引擎连接本机模型完成 7 段、2 批、12325 ms。原生 GUI 前台被切回 Codex，未宣称完整界面通过，隔离实例已停止。只读复核已结束并归档。

最终复核：独立 reviewer 的重试预算问题已经失败测试复现后修复；窄范围补审 PASS，确认 descriptor/capture 两类预算独立且有界，AX-only 临时窗口查询可正常恢复。最终 196 tests / 19 suites、严格 Release、LSP、独立 CLI 生命周期全部通过。真实 GUI 端到端因无法稳定保持前台，记录为本次验证限制；没有将其算作通过。

后续 Git 收尾：用户已明确授权提交、推送、合并，覆盖修复阶段的暂不提交约束；在最终提交的独立 worktree 绑定检查证据后，经 PR 合并并快进同步 main。
