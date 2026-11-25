# 视频翻译（Phase A + B1 + B2）

桌面端设置页「翻译」分区里，**「视频翻译」** 默认关闭；Chrome 扩展弹窗（v1.1.0+）现也支持直接切换视频字幕翻译并与桌面端实时同步，同时提供可选本地 SRT/VTT 侧车字幕上传。打开后，Chrome 扩展优先读取页面 `<video>` 的标准 `textTracks` cue、可选本地 SRT/VTT 侧车，或 **YouTube 用户已打开的字幕 / 本会话 timedtext**，经现有桌面端桥 `POST /translate` 译成简体中文，以 **叠加层** 显示在视频上方。

**没有可用外语字幕轨时**（Phase B2）：桌面端用独立的 ScreenCaptureKit 流采集 **系统/窗口音频**（不是麦克风），本地 Whisper.cpp 把英语转成文本，再走同一个 `POST /translate`，把简体中文叠在现有视频 overlay 上。失败只打日志/提示，**绝不停止播放**。音频不出本机；API Key 仍只在本地桥 / Keychain。

**视觉采集路径不变**：`WindowVisualUpdates` 仍是 `capturesAudio = false`。B2 采音在 `SystemAudioCapture.swift`，单独一条 SCStream。扩展无 `tabCapture` / `desktopCapture` / 麦克风 / `getUserMedia`。不改原片、不改原字幕文件、不构造 timedtext 抓取 URL、不用 PoToken。

桌面端与扩展共享同一个视频翻译开关状态；「翻译后端」（DeepSeek / 本地 Ollama）仍在桌面端「后端」分区统一切换，本功能复用该后端。

## 能力边界

| 场景 | 阶段 | 结果 |
| --- | --- | --- |
| 带 WebVTT/`<track>` / `addTextTrack` 的 HTML5 `<video>` | A | 支持 |
| 用户选择的本地 `.srt` / `.vtt`，按时间轴叠加 | A | 支持；侧车优先于 YouTube 轨 |
| YouTube 网页（本机 Chrome）且用户已打开播放器字幕 | B1 | 支持：读当前轨 / 本会话 `timedtext` 后叠简体中文 |
| YouTube 未开字幕、无字幕轨、或只有简体中文字幕 | B1/B2 | 先走字幕探测；无外语轨时 B2 尝试本机系统/窗口音频。失败则提示，不停播 |
| YouTube Music / YouTube TV / YouTube Studio | B1 | **不做** |
| 第三方站点里的跨域 YouTube iframe / `youtube-nocookie` 嵌入 | B1 | **不保证**（内容脚本默认不进跨域 iframe） |
| B 站等其它自绘字幕播放器 | A/B2 | 无标准字幕轨时，若系统音频许可且 Whisper 可用，可叠中文 |
| 烧录硬字幕、无 CC 的 Shorts、无 timedtext 的直播 | B2 | 无字幕时走系统/窗口音频；效果取决于本机权限与模型 |
| 语音转写（本地 Whisper.cpp） | B2 | 支持；英语 → 文本 → `/translate` → 简体叠层 |
| 麦克风 / `getUserMedia` / DeepSeek ASR / 云端上传音频 | — | **不做** |
| 改写视频元素 `src`、暂停、保存观看记录、裸爬 timedtext / PoToken | — | **不做** |

预存的视觉 ScreenCaptureKit 流 **`capturesAudio` 保持 `false`**。B2 独立模块才把 `capturesAudio` 设为 `true`，且 `captureMicrophone = false`。扩展无 `tabCapture` / `desktopCapture` / 麦克风权限。B1 仍不主动点 CC、不 `setOption` 开字幕、不自己请求 `/api/timedtext`。

## YouTube B1 范围（可测）

**会做的：**

1. 用户在本机 Chrome 打开 `youtube.com` / `m.youtube.com` 观看页（含 `/watch`、`/embed`、用户已开 CC 的 Shorts）。
2. 用户自己打开播放器字幕（CC 按钮为按下，画面上已有外文字幕）。
3. 菜单栏「视频翻译」显式打开，桌面端翻译会话可用。
4. 扩展读取：(a) 播放器已拉取的本会话 `/api/timedtext` 响应（json3 / srv1 / srv3 / vtt）；(b) 已显示的 `.ytp-caption-segment` 作为画面上的 cue 来源。外语 live CC 与 timedtext 冲突时以外语画面为准；画面已是简体中文时改用同时刻的外语 timedtext（若有）。已经是简体中文的 cue **不会**送去 `/translate`，也不会停在 `on wait`。经 `POST /translate` 叠简体中文（视频 cue 走 bridge 的 `lane: "video"`）。`/health` 与开关同步不进翻译队列，避免桌面端已开、扩展 `storage.local` 仍为 false。全屏时叠层跟到全屏元素内。
5. 整页翻译会跳过 YouTube 字幕 DOM，避免改掉用户已开的原文幕。

**不会做的：**

- 用户没开字幕时去「帮你打开」或去 InnerTube 裸爬。
- 使用或转发 `pot` / PoToken。
- 改视觉路径的 `capturesAudio`、开麦克风、把音频送出本机。
- YouTube Music / TV、第三方站跨域嵌入。

无 CC 时改由 Phase B2 的本机系统/窗口音频处理，而不是在页面里采音。

## 失败表现

- 桌面端未运行或 `POST /translate` 失败：叠加「翻译服务不可用」，继续播放。外语 cue 等译文超过数秒仍无结果时同样提示「翻译服务不可用」，不停播。
- 打开开关后一段时间仍无外语 cue：HTML5 页叠加「未检测到外语内容」；YouTube 且 cue 为空时叠加「未检测到外语字幕（请先打开 YouTube 字幕）」；**选用的 timedtext/live cue 文本已是简体中文**（CC 菜单里的中文轨，不是「英语>>中文」）时叠加「未检测到外语内容」，原字幕保持不动，`data-gt-vt` 为 `on skip`（不是 `on wait`）。
- 脚本异常被吞掉，不得中断页面。
- ScreenCaptureKit 拒绝、未安装 Whisper、转写失败：叠加对应提示（「系统音频未授权（请在屏幕录制中允许）」「未安装本地 Whisper 模型」「语音转写暂时不可用」），播放继续。

侧车字幕只放在 `chrome.storage.session`；译文缓存在内存，不写盘。ASR 音频只在内存和 `runtime/whisper-scratch/` 短时 WAV（0600，用完即删）。API Key 仍只在 macOS Keychain，扩展请求体只有待译句子，**从不上传音频**。`/health` 会带上 `videoTranslateEnabled` 与 `videoAsrStatus`，扩展跟菜单栏开关走。

## Phase B2：本机系统/窗口音频（无字幕时）

B2 **默认关闭**，与 B1 共用菜单栏「视频翻译」开关：只有显式打开后才会跑。有外语字幕（A/B1）时 **不采音**。扩展通过 `POST /video-asr` `{needed:true}` 告诉桌面端「现在没有可用外语字幕」；有字幕则 `{needed:false}` 立刻停采音。

### 打开方式

1. 本机构建并运行 Global Translator，翻译后端健康（DeepSeek 或本地 Ollama）。
2. 桌面端「翻译」分区或扩展弹窗打开 **视频翻译**（默认关）。
3. Chrome 加载仓库 `extension/`（manifest 1.1.0+），刷新视频标签页。
4. 播放 **没有可用外语字幕** 的页面（关 CC 的 HTML5 / YouTube，或无轨站点）。

### 权限（macOS）

B2 采的是 **系统或前台窗口音频**，不是麦克风。

1. **系统设置 → 隐私与安全性 → 屏幕录制**：允许 `Global Translator`。拒绝时 overlay 提示「系统音频未授权（请在屏幕录制中允许）」，播放不停。
2. 不需要、也不会申请麦克风。
3. 系统音频在部分 macOS 版本上与屏幕录制同一许可；窗口音频优先，失败则回退到当前显示器混音，并排除本进程。

`global-translator doctor` 里「屏幕录制预检」为 WARN/FAIL 时，B2 不能采音；「本地 Whisper.cpp」为 WARN 时，B2 不能转写，B1 字幕路径仍可用。

### Whisper 模型安装预期

应用 **不捆绑、不下载** 权重。请本机安装 whisper.cpp CLI 与英语 ggml 模型，任选：

- 环境变量：`GLOBAL_TRANSLATOR_WHISPER_BIN`、`GLOBAL_TRANSLATOR_WHISPER_MODEL`（本地路径）
- `~/Library/Application Support/GlobalTranslator/whisper/whisper-cli` + `ggml-base.en.bin`（或 `ggml-tiny.en.bin` / `ggml-small.en.bin`）
- Homebrew：`/opt/homebrew/bin/whisper-cli`，模型可与 CLI 同目录

推荐先用 `ggml-tiny.en.bin` 或 `ggml-base.en.bin`。CLI 以 `-l en -nt -np` 跑，只把 stdout 当英语文本。找不到 CLI/模型时 overlay「未安装本地 Whisper 模型」，**不会**回退到云端 ASR 或 DeepSeek 语音。

临时 WAV 写在 `~/Library/Application Support/GlobalTranslator/runtime/whisper-scratch/`，权限 0600，转写后删除。日志只记 `chars`/`ms`/`kind`，不记原文、不记音频。

### Mac 手测（Tech Lead / QA）

CI / Linux **不能**跑真实 ScreenCaptureKit 或 Whisper.cpp 端到端。下面必须在 Apple Silicon macOS 14+ 上做。

**准备**

```bash
swift test -Xswiftc -warnings-as-errors
bash scripts/package-app.sh
# 安装 whisper-cli + ggml-*.en.bin（见上）
global-translator doctor   # 屏幕录制、Whisper 两项
global-translator start
```

Chrome 加载 `extension/`，打开视频翻译开关。

**有字幕（B1 仍须通过）**

1. TED 英文 CC：`https://www.youtube.com/watch?v=Ks-_Mh1QhMc`，打开 CC。叠层走字幕，`data-gt-vt` 含 `on zh`，且为 `asr0`（有外语轨时不采音）。
2. 走廊片自动英文字幕：`https://www.youtube.com/watch?v=iJ53c1zKgr8`，选 English (auto-generated)。不要用走廊片当 skip。

**无字幕（B2）**

3. 同一 TED 页 **关掉 CC**：数秒后 `data-gt-vt` 应出现 `asr1`（在转写）或 `asrErr`（权限/模型问题）。视频必须继续。授权且模型可用时，应出现简体中文叠层（允许 3–8 秒延迟，跟块级语音而不是逐帧）。
4. 用 `extension/fixtures` 演示页但 **不加载字幕轨 / 清掉侧车**：打开开关后无外语 cue，B2 可对系统里正在播放的英语声音出叠层（本机扬声器播放任意英语视频亦可）。
5. 拒绝屏幕录制：提示「系统音频未授权（请在屏幕录制中允许）」，播放不停。
6. 暂时改名/移走 Whisper 模型：提示「未安装本地 Whisper 模型」，播放不停。
7. 停翻译后端：已有 ASR 英文仍走 `/translate` 时出现「翻译服务不可用」，播放不停。
8. 关掉菜单栏「视频翻译」：采音停止，叠层消失，播放不停。

**隐私抽查**

- 扩展 Network 面板：只有 `127.0.0.1:9233` 的 `/health`、`/translate`、`/video-asr`。`/video-asr` 响应含 `text` 字符串（英语转写），**没有** audio/wav。`/translate` 仍只有句子。
- 运行日志 `~/Library/Logs/GlobalTranslator/runtime.log`：可有 `video_asr_start` / `video_asr_denied` / `video_asr_whisper_missing`，字段不含 cue 原文、邮箱、Cookie、密钥。

### 已知缺口（本机 E2E 无法在 CI 证明）

- 真实 SCK 系统/窗口音频、权限对话框、与 Chrome 播放器的口型级对齐。
- 多显示器、耳机独占、DRM 媒体对系统音频的静音。
- 非英语口播（MVP 只把 Whisper 固定为 `en`）。
- 与本机其它占用 ScreenCaptureKit 的 App 抢流。

这些留给 Mac 上手测，不阻塞本 PR 的模块与单测。

## Chrome 验证

### Phase A 回归

1. 本机构建并运行 Global Translator，配置 DeepSeek 或本地 Ollama，保持自动翻译可用（桥依赖桌面端翻译会话）。
2. Chrome → 扩展程序 → 加载已解包扩展 → 选仓库 `extension/`。
3. 打开菜单栏设置：确认 **视频翻译** 在「翻译」分区内默认关闭；此时播放带字幕的 HTML5 视频，不应出现中文叠层。
4. 打开「视频翻译」。用本地 HTTP 打开演示页（内容脚本不匹配 `file://`）：

   ```bash
   python3 -m http.server 8765 --directory extension/fixtures
   ```

   访问 `http://127.0.0.1:8765/video-translate-demo.html`，选择任意本地视频，播放。约 0–3 秒、3–6 秒应看到中文叠层；9–12 秒的中文 cue 不应再译。播放过程中关掉同一行的开关，叠层消失且视频不停。
5. 可选：扩展弹窗点「选择本地字幕」，选 `extension/fixtures/sample.en.srt` 或 `.vtt`，叠层按侧车时间轴对齐。
6. 退出桌面端后再播放外语 cue，应出现「翻译服务不可用」，视频继续。

### Phase B1：YouTube（必须开字幕）

推荐片源：

- 英文 CC（人工轨，叠层应变 `on zh`）：`https://www.youtube.com/watch?v=Ks-_Mh1QhMc`（TED / Amy Cuddy）
- 英语自动生成字幕（外语路径，**不是** `on skip`）：`https://www.youtube.com/watch?v=iJ53c1zKgr8`（走廊片「我在伦敦住了一家五星级酒店」）。播放器里的「英语>>中文」只是 YouTube 把英文字幕机翻显示，timedtext 仍是外语。

不要用只有烧录字幕、没有 CC 按钮的片子。页面简介被整页翻译成中文 **不算** 通过。

**`on skip` / 「未检测到外语内容」** 不拿走廊片做线上验收：该片没有稳定的原生简体字幕轨。跳过逻辑由 Node 单测覆盖（`subtitle-cues.test.js` / `youtube-captions.test.js` 里的简体 live cue），本机还可看 Phase A 演示页 9–12 秒那条「这是中文，不应再译」。公开 YouTube 上「CC 菜单里单独列出的中文（简体）人工轨」（不是自动翻译、也不是「英语>>中文」）会随上传者改轨，这里不钉死某个 video id；若本机遇到这种轨，预期是 `on skip` + 「未检测到外语内容」，且不停播。

1. 保持桌面端运行、视频翻译 **开**、扩展已加载（若刚更新，在 `chrome://extensions` 点「重新加载」，然后 **刷新 YouTube 标签页**；已打开的标签不会自动注入新脚本）。
2. 打开上述 watch 页，先 **不要** 开 CC：若 Whisper/屏幕录制未就绪，**视频画面底部**可出现「未检测到外语字幕（请先打开 YouTube 字幕）」或 B2 的权限/模型提示；若 B2 正在跑则为 `asr1` 且可能暂无提示。视频必须继续。DevTools 应能看到 `<body>` 下的 `[data-gt-video-translate]`（不要找 `#movie_player` 内部，也不要找 `<html>` 直接子节点以外的旧挂载点）。
3. 点播放器 **CC**，选英文字幕（不要选简体中文）。数秒内应在 **视频画面上** 出现简体中文叠层，盖在英文 CC 附近。简介区中文不算。
4. 拖动进度条：中文叠层应跟上新 cue，播放不停。
5. 关掉 CC：中文叠层在无外语 cue 后收起或回到提示，视频不停。
6. 再打开 CC：叠层恢复。
7. 点进另一条同样有英文字幕的视频（站内跳转）：应重新对齐，不整页卡死。
8. 全屏播放：中文叠层仍应可见。
9. 关掉菜单栏「视频翻译」：叠层消失，YouTube 字幕与播放不受影响。
10. **反例（应失败/提示，不算回归）**：CC 始终关闭；无字幕的 Shorts；YouTube Music；第三方博客里的 youtube-nocookie iframe。
11. **走廊片自动英文字幕**（`iJ53c1zKgr8`）：打开播放器 **English (auto-generated)**。不要把 YouTube「英语>>中文」当成原生简体轨。timedtext 是外语，GT 叠层应变 `on zh`（允许短暂 `on wait`），**不应**稳定停在 `on skip`。`chrome.storage.local.videoTranslateEnabled` 须与菜单栏/桥 `videoTranslateEnabled` 一致（桌面开则为 `true`）。YouTube 自己画的中文机翻框不算 GT 叠层。
12. **`on skip`**：用自动化单测 + Phase A 演示页中文 cue；不要用走廊片当 skip 样例。

诊断（不打印原文、不含 cue 文本）：

```js
document.documentElement.getAttribute("data-gt-ytcap")  // MAIN 页脚本已跑应为 "1"
document.querySelector("[data-gt-video-translate]")
document.querySelector("[data-gt-video-translate]")?.getAttribute("data-gt-vt")
```

`data-gt-vt` 形如 `c1 t412 on zh pw1 dom1 asr0`：

| 段 | 含义 |
| --- | --- |
| `cN` | 当前选用的 cue 条数 |
| `t412` | 主播放器 `currentTime` 取整；TED 中段应是几百，不应是 `t0` |
| `on` / `off` | 该时刻有没有命中一条 cue |
| `wait` / `zh` / `skip` / `idle` | 外语 cue 等译文 / 已有简体译文 / 已是简体中文（不送译） / 当前无 cue |
| `pw1` / `pw0` | MAIN 世界 `youtube-captions-page.js` 是否打了 `data-gt-ytcap` |
| `dom1` / `dom0` | 隔离世界能否读到 `.ytp-caption-segment` |
| `asr1` / `asr0` / `asrErr` | B2 系统音频转写进行中 / 未采音 / 权限或模型失败 |

英文 CC 可见但没有中文叠层时：有 host 且 `on wait` = 正在等这条 cue 的 `/translate`（数秒后应变 `zh` 或出现「翻译服务不可用」）；`on zh` 但看不见 = CSS/挂载问题；`on skip` = **当前选用的 cue 文本已是简体中文**（不是 YouTube「英语>>中文」机翻显示）；`off` 且 `dom0` = 没抓到画面字幕；`pw0` = 页脚本没注入（仍应靠 `dom1` 走 live DOM）。走廊片在自动英文字幕下应走 `wait`/`zh`，不要当 skip 样例。需要控制台轨迹时：`localStorage.setItem("gtVtDebug","1")` 后刷新，过滤 `[gt-vt]`（仍不含字幕原文）。

### 自动化（任意机器）

```bash
node extension/text-filter.test.js
node extension/subtitle-cues.test.js
node extension/youtube-captions.test.js
node extension/video-asr.test.js
node extension/video-translate.test.js
node extension/bridge-queue.test.js
```

macOS 上另跑 `swift test -Xswiftc -warnings-as-errors`。Linux CI 只能跑 Node 单测；真实 ScreenCaptureKit / Whisper 必须在 Mac 上手测（见 Phase B2）。
