# 视频翻译 Phase A（无 ASR）

菜单栏设置里，**「视频翻译」与「滑词翻译」同一行并列**，**默认关闭**。不要单独再占一行。打开后，Chrome 扩展读取页面 `<video>` 的标准 `textTracks` cue（可选：本地 SRT/VTT 侧车文件），经现有桌面端桥 `POST /translate` 译成简体中文，以 **叠加层** 显示在视频上方。不改原片、不改原字幕文件、不暂停播放。本阶段 **不做** Whisper / 麦克风 / `getUserMedia` / ASR。

开关只在菜单栏设置；扩展弹窗不再另放开关，只提供可选侧车字幕。菜单栏「翻译后端」（DeepSeek / 本地 Ollama）未改，本功能复用该后端。

## 能力边界

| 场景 | Phase A |
| --- | --- |
| 带 WebVTT/`<track>` / `addTextTrack` 的 HTML5 `<video>` | 支持 |
| 用户选择的本地 `.srt` / `.vtt`，按时间轴叠加 | 支持 |
| YouTube、B 站等自绘字幕、无标准 `textTracks` 的播放器 | **不保证**；探测后提示「未检测到外语内容」 |
| 跨域 iframe 内的视频 | 不保证（内容脚本默认不进 iframe） |
| 语音转写 / OCR / 烧录硬字幕 | **不做** |
| 改写视频元素 `src`、暂停、或保存用户观看记录 | **不做** |

`ScreenCaptureKit` 的 `capturesAudio` 保持 `false`。扩展无 `tabCapture` / `desktopCapture` / 麦克风权限。

## 失败表现

- 桌面端未运行或 `POST /translate` 失败：叠加「翻译服务不可用」，继续播放。
- 打开开关后一段时间仍无外语 cue：叠加「未检测到外语内容」，原字幕保持不动。
- 脚本异常被吞掉，不得中断页面。

侧车字幕只放在 `chrome.storage.session`；译文缓存在内存，不写盘。API Key 仍只在 macOS Keychain，扩展请求体只有待译句子。`/health` 会带上 `videoTranslateEnabled`，扩展跟菜单栏开关走。

## Chrome 验证

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
7. YouTube 任意视频打开开关：允许提示「未检测到外语内容」；这是已知限制，不是回归。
8. 自动化（任意机器）：

   ```bash
   node extension/text-filter.test.js
   node extension/subtitle-cues.test.js
   node extension/video-translate.test.js
   ```

   macOS 上另跑 `swift test -Xswiftc -warnings-as-errors`。
