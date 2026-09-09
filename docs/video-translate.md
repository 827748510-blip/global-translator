# 视频翻译（Phase A + B1）

菜单栏设置里，**「视频翻译」与「滑词翻译」同一行并列**，**默认关闭**。不要单独再占一行。打开后，Chrome 扩展读取页面 `<video>` 的标准 `textTracks` cue、可选本地 SRT/VTT 侧车，或 **YouTube 用户已打开的字幕 / 本会话 timedtext**，经现有桌面端桥 `POST /translate` 译成简体中文，以 **叠加层** 显示在视频上方。不改原片、不改原字幕文件、不暂停播放。

**Phase B1** 只提高 YouTube 字幕可靠性。本阶段 **不做** Whisper / 麦克风 / `getUserMedia` / DeepSeek ASR / 云端上传音频 / `ScreenCaptureKit` 采音（那些是 B2）。`capturesAudio` 保持 `false`。

开关只在菜单栏设置；扩展弹窗不再另放开关，只提供可选侧车字幕。菜单栏「翻译后端」（DeepSeek / 本地 Ollama）未改，本功能复用该后端。

## 能力边界

| 场景 | 阶段 | 结果 |
| --- | --- | --- |
| 带 WebVTT/`<track>` / `addTextTrack` 的 HTML5 `<video>` | A | 支持 |
| 用户选择的本地 `.srt` / `.vtt`，按时间轴叠加 | A | 支持；侧车优先于 YouTube 轨 |
| YouTube 网页（本机 Chrome）且用户已打开播放器字幕 | B1 | 支持：读当前轨 / 本会话 `timedtext` 后叠简体中文 |
| YouTube 未开字幕、无字幕轨、或只有简体中文字幕 | B1 | 探测后提示「未检测到外语字幕（请先打开 YouTube 字幕）」或「未检测到外语内容」，不停播 |
| YouTube Music / YouTube TV / YouTube Studio | B1 | **不做** |
| 第三方站点里的跨域 YouTube iframe / `youtube-nocookie` 嵌入 | B1 | **不保证**（内容脚本默认不进跨域 iframe） |
| B 站等其它自绘字幕播放器 | A | **不保证**；探测后提示「未检测到外语内容」 |
| 烧录硬字幕、无 CC 的 Shorts、无 timedtext 的直播 | B1 | **不保证** |
| 语音转写 / OCR | B2 | **不做** |
| 改写视频元素 `src`、暂停、保存观看记录、裸爬 timedtext / PoToken | — | **不做** |

`ScreenCaptureKit` 的 `capturesAudio` 保持 `false`。扩展无 `tabCapture` / `desktopCapture` / 麦克风权限。不主动点 CC、不 `setOption` 开字幕、不自己请求 `/api/timedtext`。

## YouTube B1 范围（可测）

**会做的：**

1. 用户在本机 Chrome 打开 `youtube.com` / `m.youtube.com` 观看页（含 `/watch`、`/embed`、用户已开 CC 的 Shorts）。
2. 用户自己打开播放器字幕（CC 按钮为按下，画面上已有外文字幕）。
3. 菜单栏「视频翻译」显式打开，桌面端翻译会话可用。
4. 扩展读取：(a) 播放器已拉取的本会话 `/api/timedtext` 响应（json3 / srv1 / srv3 / vtt）；(b) 已显示的 `.ytp-caption-segment` 作为画面上的外语 cue 来源（与 timedtext 冲突时以画面为准）。经 `POST /translate` 叠简体中文（视频 cue 走 bridge 的 `lane: "video"`，不会被整页翻译队列饿死）。全屏时叠层跟到全屏元素内。
5. 整页翻译会跳过 YouTube 字幕 DOM，避免改掉用户已开的原文幕。

**不会做的：**

- 用户没开字幕时去「帮你打开」或去 InnerTube 裸爬。
- 使用或转发 `pot` / PoToken。
- 改 `capturesAudio`、开麦克风、Whisper、上传音频。
- YouTube Music / TV、第三方站跨域嵌入、无 CC 的视频。

## 失败表现

- 桌面端未运行或 `POST /translate` 失败：叠加「翻译服务不可用」，继续播放。
- 打开开关后一段时间仍无外语 cue：HTML5 页叠加「未检测到外语内容」；YouTube 且 cue 为空时叠加「未检测到外语字幕（请先打开 YouTube 字幕）」；原字幕保持不动。
- 脚本异常被吞掉，不得中断页面。

侧车字幕只放在 `chrome.storage.session`；译文缓存在内存，不写盘。API Key 仍只在 macOS Keychain，扩展请求体只有待译句子。`/health` 会带上 `videoTranslateEnabled`，扩展跟菜单栏开关走。

## Chrome 验证

### Phase A 回归

1. 本机构建并运行 Global Translator，配置 DeepSeek 或本地 Ollama，保持自动翻译可用（桥依赖桌面端翻译会话）。
2. Chrome → 扩展程序 → 加载已解包扩展 → 选仓库 `extension/`。
3. 打开菜单栏设置：确认 **视频翻译** 在 **滑词翻译同一行右侧**，默认关；此时播放带字幕的 HTML5 视频，不应出现中文叠层。不要出现单独的视频翻译区块。
4. 打开「视频翻译」。用本地 HTTP 打开演示页（内容脚本不匹配 `file://`）：

   ```bash
   python3 -m http.server 8765 --directory extension/fixtures
   ```

   访问 `http://127.0.0.1:8765/video-translate-demo.html`，选择任意本地视频，播放。约 0–3 秒、3–6 秒应看到中文叠层；9–12 秒的中文 cue 不应再译。播放过程中关掉同一行的开关，叠层消失且视频不停。
5. 可选：扩展弹窗点「选择本地字幕」，选 `extension/fixtures/sample.en.srt` 或 `.vtt`，叠层按侧车时间轴对齐。
6. 退出桌面端后再播放外语 cue，应出现「翻译服务不可用」，视频继续。

### Phase B1：YouTube（必须开字幕）

推荐片源：`https://www.youtube.com/watch?v=Ks-_Mh1QhMc`（英文 CC）。不要用只有烧录字幕、没有 CC 按钮的片子。页面简介被整页翻译成中文 **不算** 通过。

1. 保持桌面端运行、视频翻译 **开**、扩展已加载（若刚更新，在 `chrome://extensions` 点「重新加载」，然后 **刷新 YouTube 标签页**；已打开的标签不会自动注入新脚本）。
2. 打开上述 watch 页，先 **不要** 开 CC：播放数秒后，**视频画面底部**可出现「未检测到外语字幕（请先打开 YouTube 字幕）」；视频必须继续。DevTools 应能看到 `<body>` 下的 `[data-gt-video-translate]`（不要找 `#movie_player` 内部，也不要找 `<html>` 直接子节点以外的旧挂载点）。
3. 点播放器 **CC**，选英文字幕（不要选简体中文）。数秒内应在 **视频画面上** 出现简体中文叠层，盖在英文 CC 附近。简介区中文不算。
4. 拖动进度条：中文叠层应跟上新 cue，播放不停。
5. 关掉 CC：中文叠层在无外语 cue 后收起或回到提示，视频不停。
6. 再打开 CC：叠层恢复。
7. 点进另一条同样有英文字幕的视频（站内跳转）：应重新对齐，不整页卡死。
8. 全屏播放：中文叠层仍应可见。
9. 关掉菜单栏「视频翻译」：叠层消失，YouTube 字幕与播放不受影响。
10. **反例（应失败/提示，不算回归）**：CC 始终关闭；只有简体中文字幕；无字幕的 Shorts；YouTube Music；第三方博客里的 youtube-nocookie iframe。

诊断（不打印原文、不含 cue 文本）：

```js
document.documentElement.getAttribute("data-gt-ytcap")  // MAIN 页脚本已跑应为 "1"
document.querySelector("[data-gt-video-translate]")
document.querySelector("[data-gt-video-translate]")?.getAttribute("data-gt-vt")
```

`data-gt-vt` 形如 `c1 t412 on zh pw1 dom1`：

| 段 | 含义 |
| --- | --- |
| `cN` | 当前选用的 cue 条数 |
| `t412` | 主播放器 `currentTime` 取整；TED 中段应是几百，不应是 `t0` |
| `on` / `off` | 该时刻有没有命中外语 cue |
| `wait` / `zh` | cue 已抓住但译文未回 / 已有简体译文 |
| `pw1` / `pw0` | MAIN 世界 `youtube-captions-page.js` 是否打了 `data-gt-ytcap` |
| `dom1` / `dom0` | 隔离世界能否读到 `.ytp-caption-segment` |

英文 CC 可见但没有中文叠层时：有 host 且 `on wait` = 正在等这条 cue 的 `/translate`；`on zh` 但看不见 = CSS/挂载问题；`off` 且 `dom0` = 没抓到画面字幕；`pw0` = 页脚本没注入（仍应靠 `dom1` 走 live DOM）。需要控制台轨迹时：`localStorage.setItem("gtVtDebug","1")` 后刷新，过滤 `[gt-vt]`（仍不含字幕原文）。

### 自动化（任意机器）

```bash
node extension/text-filter.test.js
node extension/subtitle-cues.test.js
node extension/youtube-captions.test.js
node extension/video-translate.test.js
node extension/bridge-queue.test.js
```

macOS 上另跑 `swift test -Xswiftc -warnings-as-errors`。
