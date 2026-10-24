# 滑词翻译失灵修复记录（2026-10-22）

## 结论

「划词翻译频繁失灵」不是单一 UI bug，而是两条叠加的链路问题：

1. **本地模型回声品牌词 → 被判为翻译失败。** 结构化 `json_object` 请求要求 JSON，质量校验把「译文 == 原文」判为 `invalidResponse`，滑词层再把它显示成红色「翻译失败」。
2. **Electron / 飞书类 App 的 ⌘C 剪贴板兜底等待太短且阻塞主线程。** 旧实现同步轮询 10×5ms（50ms），重页面/高负载时目标 App 还没把选区写进剪贴板就放弃，表现为「划过去没反应」。

## 真实日志证据（本机 `~/Library/Logs/GlobalTranslator/`）

- `runtime.log.2`（2026-10-20 15:30）：同一选区在 12 秒内重试 4 次，全部失败：

  ```
  15:30:12.271 engine_snapshot region_count=1 revision=17
  15:30:12.731 engine_failed status=invalidResponse
  15:30:12.732 selection_translate_failed status=error
  ... revision=18 / 19 / 20 同样失败
  ```

  revision 17–20 是滑词专用的 `selectionRevision`（窗口覆盖层 revision 为 6000+），可确认失败发生在滑词链路，不是覆盖层。
- `runtime.log`（2026-10-22 06:11、06:31）：同一模式仍在出现。

## 本机复现（真实 Ollama：`global-translator-local:qwen3-4b`）

直接按 App 的请求体调用 `POST /v1/chat/completions`（system=`LocalTranslationPrompt.system`、`response_format=json_object`、`max_tokens=128`）：

| 选区 | 模型 content | App 质量校验结果 |
| --- | --- | --- |
| `Figma` | `0：Figma` | 回声原文 → `invalidResponse` → 「翻译失败」 |
| `Spotify` | `0：Spotify` | 同上 |
| `Python` | `0：Python` | 同上 |
| `npm` | `0:npm` | 同上 |
| `Webpack` | `0：Webpack` | 同上 |
| `Jira` | `0：Jira` | 同上 |
| `Docker` | `0：Docker` | 同上 |
| `The quick brown fox…` | `0：快速的棕色狐狸…` | 正常翻译 |

对 83 个常见界面 / 技术词抽样，**28 个（34%）被原样回声**，其中通过 `TextFilter`（会真正请求模型）的单品牌/单词大约占 1/5。这类词在技术文档、GitHub、产品页面里被划选的频率很高，与「频繁失灵」吻合。

## 修复

### 1. 结构化失败 → 一次纯文本兜底（`TranslationSession`）

- 结构化请求抛 `invalidResponse`（回声、JSON 截断、格式跑偏、空结果）时，对 **≤600 字** 的块用 `SelectionFallbackInstructions`（`GlobalTranslatorCore`）重试一次纯文本补答。
- 提示词要求「专有名词保留原名 + 极短中文注释」，实测 `Figma → Figma（设计工具）`、`Python → Python（编程语言）`、`npm → npm（节点包管理器）`。
- 补答仍与原文相同（忽略大小写）时：若选区像专有名词（单个短词，或 ≤4 个首字母大写/驼峰词），抛 `SelectionTranslateError.noTranslationNeeded`，弹层显示「专有名词，无需翻译」（可拷贝 / 可优化），不再红字；普通句子回声仍按失败处理，避免把模型故障伪装成成功。
- 多块选区中只有某个短块回声时不会把整段标成「无需翻译」（转为失败），只有单块选区才可能进入软提示。
- 补答为空或再次失败 → 保持「翻译失败」。
- `networkFailure` / `timeout` / 凭据错误不重放，避免状态不确定的重试和重复计费。
- >600 字的块不回退：纯文本补答预算 1024 token，长译文可能被静默截断；宁可保留明确失败。
- 日志 `selection_plain_fallback`（`status` / `reason`，不含选区文字）。

### 2. 剪贴板兜底改异步、延长等待（`GlobalTranslatorCapture`）

- `SelectedTextReading.readSelection` / `ClipboardSelectionFallingBack.copySelectedTextRestoringClipboard` 改为 `async`；协议标 `@MainActor`，AX / `NSScreen` / `NSPasteboard` 仍在主线程，只有等待处挂起。
- `RestoringClipboardSelectionFallback` 不再 `Thread.sleep`，改为最多 40×5ms（200ms）的异步等待。
- 等待使用不可取消的 main-queue timer：**取消只决定返回值，不缩短 steal-and-restore 窗口**。否则新划选取消 settle 后会在几毫秒内先恢复备份，随后目标 App 的迟到 ⌘C 又把剪贴板覆盖成选区文字。
- 同一次读取的 capture → ⌘C → read → restore 用串行 gate 包起来；重叠读取会排队，避免第二次把第一次的临时选区当作用户备份。
- 开始前已取消则不發 ⌘C；滑词控制器在 await 之后用 `SelectionSettleGate` 代际 token 校验，过期结果不会弹到新选区上。

### 3. 诊断与状态清理（`SelectionTranslateController`）

- 真实拖选但 AX / 剪贴板都读不到时记录 `selection_unreadable`（verdict / 位移 / 路程 / `clipboardAllowed` / `degraded`，不含文本），让「划词没反应」可定位。
- 选区被 `TextFilter` 判为 skip（URL / 标识符）时清空 `suppressedSource`；否则被 Esc 关掉的同一句会永远不再弹层。
- 复制/优化逻辑不变。

### 4. 复用与测试基建

- 新增 `CopiedSourceDetector`（`TextFilter.swift`），后端质量门与滑词兜底共用同一套「回声」定义。
- `SelectionTranslateSupport.cleanPlainFallback` 去掉纯文本补答的包裹引号 / 「译文：」前缀。

## 改动文件

- `Sources/GlobalTranslatorCore/TranslationInstructions.swift`：`SelectionFallbackInstructions`。
- `Sources/GlobalTranslatorCore/TextFilter.swift`：`CopiedSourceDetector`。
- `Sources/GlobalTranslatorCore/SelectionTranslate.swift`：`plainFallbackMaxCharacters`、`isProperNounPhrase`、`cleanPlainFallback`。
- `Sources/GlobalTranslatorCore/AdapterSupport.swift`：质量门复用 `CopiedSourceDetector`。
- `Sources/GlobalTranslatorCapture/SelectedTextReader.swift`：读取协议异步化 + `@MainActor`。
- `Sources/GlobalTranslatorCapture/ClipboardSelectionFallback.swift`：异步等待、不可取消窗口、串行 gate、取消安全恢复。
- `Sources/GlobalTranslatorApp/SelectionTranslateController.swift`：await + 代际校验 + `selection_unreadable` + skip 清理。
- `Sources/GlobalTranslatorApp/TranslationSession.swift`：结构化→纯文本兜底、回声→软提示、多块选区的短块回声 guard。
- 测试：新增 `SelectionFallbackTests.swift`、`LiveOllamaSelectionSmokeTests.swift`；capture 新增 200ms 迟到复制、取消后迟到复制两个回归；app 新增兜底成功/回声/句子回声/网络失败/超长跳过/兜底失败/多块 guard/过期读取/诊断日志/skip 清理用例。
- 文档：`docs/selection-translate.md`、本文件、README。

## 独立评审与复审修复

改动完成后由独立评审 agent 只读复审，发现并已修复：

- **H1（高危，已修）**：异步等待最初用 `try? await Task.sleep`，task 被取消时 40 次等待在约 3ms 内跑完 → 先恢复剪贴板 → 目标 App 迟到的 ⌘C 覆盖恢复结果，用户剪贴板变成选区文字。评审用逐行复刻探针实测复现。现在默认等待改为不可取消的 main-queue timer，并新增「取消后迟到复制仍能恢复」回归测试。
- **M1（中，已修）**：nonisolated async 会把 AX / AppKit 调用挪到后台线程。协议改为 `@MainActor`，等待仍异步，不阻塞主线程。
- **M2（中，已补）**：await 后的 settle token 复核原先零覆盖。新增 `GatedSelectedTextReader` 测试：旧 gesture 的结果晚到不得弹层，新 gesture 结果正常显示。
- 其余低优先级项（4xx 重放边界、错误 reason 字符串匹配、`cleanPlainFallback` 极端输入、诊断日志命名等）已记录在残余风险，未扩大本轮改动。
- 复审确认：`CopiedSourceDetector` 与旧 `isEligibleLatin` 严格等价；catch 顺序不会吞网络/凭据/取消错误；新增日志不含选区文字或密钥；长块不会被伪装成成功。

## 验证

| 项目 | 结果 |
| --- | --- |
| `swift test -Xswiftc -warnings-as-errors` | 全绿：6 个 target / 48 个 suite / **524 tests**（含异步兜底、兜底链路、H1 取消回归、M2 过期读取、诊断日志、skip 清理用例） |
| `swift build -c release -Xswiftc -warnings-as-errors` | 通过（22.9s） |
| `cd extension && node --test` | 6/6 通过（扩展未改动） |
| `GT_LIVE_OLLAMA=1 swift test --filter LiveOllamaSelectionSmokeTests` | 2/2 通过：真实 Ollama 结构化调用对 `Figma` 抛「copied the source」；纯文本补答对 `Figma` / `Spotify` / `Python` 均给出非回声结果 |
| 定向回归 | `SelectionTranslateControllerTests` 40、`SelectedTextReaderTests`+`ClipboardRestoreTests` 19、`CopiedSourceDetectorTests`+`SelectionFallbackInstructionsTests` 8 全绿 |

## 安装与真机验收（2026-10-22）

安装：

- `scripts/package-app.sh` 产出 `.build/desktop/Global Translator.app`，用 `ditto` 覆盖 `/Applications` 与 `~/Applications` 两份；三处二进制 md5 均为 `6eeb4d275c3300fc5c4a53fe4f843844`。
- 替换前旧版备份在 `.build/desktop/backup-20261022-151100/`（gitignored，可回滚）。
- 运行进程为 `/Applications/Global Translator.app/Contents/MacOS/global-translator`（验收期间多次重启），日志有 `worker_started` + `bridge_listening port=9233`；`global-translator doctor` 显示辅助功能已授权。

能力限制：本机终端 / peekaboo / cliclick 没有辅助功能与屏幕录制 TCC，系统拒绝截图和 System Events，因此本轮验收用 **真实鼠标拖选（cliclick 事件可注入）+ App 运行日志 + 可控 mock 后端请求记录** 取证，没有视觉截图。

1. **普通文本（真实 Ollama 本地后端）**：TextEdit 拖选英文句子
   - `selection_gesture verdict=textSelection`；
   - `engine_snapshot revision=1` → `engine_batch` → `engine_completed status=success translated_count=1 duration_ms=1382`；
   - 剪贴板哨兵 `GT-SENTINEL-20261022-KEEP-ME` 保持不变（AX 路径未借用剪贴板）。
2. **品牌词回声（真实 Ollama 本地后端，安装版）**：TextEdit 拖选 `Kubernetes`
   - `engine_failed status=invalidResponse`（结构化请求回声）；
   - `selection_plain_fallback reason=copied_source status=success`（纯文本兜底成功）；
   - **没有** `selection_translate_failed`；剪贴板哨兵 `GT-SENTINEL-FINAL-KEEP-ME` 保持不变。
3. **可控 mock 端到端复核**：临时把 `localBaseURL` 指向本机 mock（`127.0.0.1:11435`），mock 对结构化请求回原文回声、对纯文本回「…（兜底译文）」：
   - mock 连续两次记录 `STRUCTURED source='tadog' -> '0：tadog'` 与 `PLAIN source='tadog' -> 'tadog（兜底译文）'`；
   - App 日志对应 `engine_failed invalidResponse` + `selection_plain_fallback reason=copied_source status=success`；
   - 验收脚本带 `trap`，结束后已恢复 `localBaseURL=http://127.0.0.1:11434/v1`、重启 App，并用 `curl /v1/models` 确认真实 Ollama 恢复；mock 端口已关闭。
   - 说明：拖选起点比文字左边界偏左 2 个字符，实际选中 `tadog`；不影响回声 → 兜底链路验证。

未覆盖：Electron / 飞书类 App 的真实 ⌘C 兜底（本机未安装飞书 / Lark）；覆盖层、优化提示词、截图翻译未在本轮重测。

## 残余风险 / 未验证

- **DeepSeek 云端真实往返未验证**：本机未配置云端 Key；兜底同样适用于云端 `invalidResponse`，每次失败最多多一次短请求（仅 ≤600 字块）。
- **Electron 类 App 的剪贴板兜底未真机覆盖**：本机无飞书 / Lark；取消竞态、200ms 等待与串行 gate 由单元/回归测试覆盖，真实 Electron 页面仍需后续人工验收。
- **视觉/截图未取证**：终端与自动化工具缺 TCC，本轮以日志 + mock 请求取证，未做截图或屏幕元素级验证。
- **双击选词**在 Electron 类 App 中仍不触发剪贴板兜底（只认拖选手势），属于既有产品约束，本次未改。
- **长块（>600 字）**不做纯文本兜底，仍可能显示失败，需要用户点「翻译」重试。
- 回声判定复用 `TextFilter.shouldTranslate`：已判为「专有名词，无需翻译」的选区（`Mac Studio` 等）平时不请求模型；用户强制点「翻译」时若模型回声，沿用后端既有口径保留原文，不再触发兜底。
- **4xx 归类**：`AdapterHTTPMapping` 未映射的 4xx（400/404/413/422）会落到 `invalidResponse`，因此也会触发一次兜底；每个选区最多多一次调用（不是 2× 全部块），但对永久性 4xx 属无效重试，后续可细化。
- **错误原因靠字符串匹配**：`fallbackReason` 通过 `"copied the source"` 识别回声，后端文案改动会让 reason 退化为 `invalid_response`（不影响功能）。
- **`cleanPlainFallback` 极端输入**：只剥首尾包裹引号和开头标签；若模型把解释性长文塞进 ≤600 字补答，会被当作译文展示（≤600 字 + 1024 token 下风险低），后续可加最小输出形态校验。
- **两次重叠读取已串行化**，但 200ms 等待会让快速连续划选里的第一次读取最多占用 gate 200ms，第二次会排队；不会改错剪贴板，只是延迟。

## 回滚

- 分支：`dsh/fix-selection-translate-resilience`，提交 `e62dd10`，已推送并开 PR #26。
- 本机已安装新构建（两份 App）；回滚用 `.build/desktop/backup-20261022-151100/` 覆盖回 `/Applications` 与 `~/Applications`，再 `global-translator stop` / 重启。
- 验收用的 mock 配置已恢复：`localBaseURL=http://127.0.0.1:11434/v1`，11435 端口未监听，无配置残留。
- 代码回滚直接切回 `main` 即可；本次没有数据库或网络协议变更（`invalidResponse` 语义未变）。
