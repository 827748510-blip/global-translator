# Changelog

All notable changes to **Global Translator** are documented in this file.

## [1.2.0] - 2026-11-25

### Highlights

- **UI & Design System**: Rebuilt desktop settings with a single-layer Liquid Glass outer chrome, tonal inner cards, 3-segment tabs (`翻译` / `后端` / `高级`), adaptive popover sizing, dark-mode contrast fixes, and Chrome extension dark mode + icon set (`16`/`32`/`48`/`128` px).
- **Streaming & Screenshot UX**: Upgraded translation queue with high/normal priority lanes so screenshot & selection translate preempt background web translation; added SSE token streaming for both local Ollama and DeepSeek Cloud with live thinking-tag stripping, single-pass `.accurate` Vision OCR with `SCDisplay` warm cache, and a new **Copy Original (`复制原文`)** action in screenshot popovers.
- **Security Hardening (22 Fixes)**: Tightened Keychain entitlement fallback & iCloud sync exclusion, Whisper path ownership/permission validation & `0600` atomic scratch files, atomic `O_EXCL|O_NOFOLLOW` screenshot writes, full-chain lock-screen & Secure Input blocking, concealed/transient clipboard (e.g., 1Password) exclusion, `ExtensionBridgeServer` connection limits/timeouts/Host+Origin checks/token-bucket rate limiting/`pageOrigin` cache isolation, Hardened Runtime (`--options runtime`) & release script non-adhoc signing gate, and `0600` `cli.log` permissions.
- **Full-Stack Performance**: Added O(1) LRU `TranslationCache` (16 MB cap), precompiled code-detection regexes, `OSAllocatedUnfairLock` credential cache with 401 invalidation, 3-way cloud concurrency, `vDSP` audio mixing, persistent `whisper-server`, pooled `CALayer`/`CATextLayer` overlays, GPU `CAShapeLayer` region selector, and extension LRU cache / viewport-first DOM translation / binary-search subtitle cues.
- **Chrome Extension (v1.1.0)**: Added direct video subtitle toggle in the popup, automatic skipping of `translate="no"`, `.notranslate`, `aria-hidden` icon words, icon-font glyphs, PUA/symbol-only text, and mislabeled Simplified Chinese web pages (`lang="en"` / `lang="zh-TW"`), plus clean original-text restoration when disabled.

## [1.1.3] - 2026-11-24

Initial public open-source release under the MIT License.

### Highlights

- **Desktop App & CLI**: Native Apple Silicon macOS utility featuring Liquid Glass settings and popovers, single-instance Unix socket supervision, `doctor` diagnostics, and optional `launchd` keep-alive template.
- **Click-Through Window Overlay**: Accessibility-first active window text extraction with automatic on-device Apple Vision OCR fallback, `256x256` 4 fps local visual change detection, and automatic Secure Input pause.
- **Universal Selection Translate**: Automatic bidirectional translation, async lossless clipboard fallback for Feishu/Lark/Electron apps, 3-mode prompt polishing, and automatic 15+ language code explanation mode.
- **On-Device OCR Screenshot Translate**: Local Apple Vision OCR region capture with zero cloud image uploads, plus optional auto-copy and local PNG save/clipboard copy toggles.
- **Chrome Extension (v1.0.12)**: Multi-language in-page DOM translation and dual-mode video Chinese subtitle overlay supporting HTML5 video tracks, local `.srt`/`.vtt` files, YouTube captions, and local ScreenCaptureKit + `whisper.cpp` transcription for uncaptioned videos.
- **Dual Translation Backends**: Offline loopback Ollama (`127.0.0.1:11434`) with automatic Homebrew suspend/resume and DeepSeek Cloud (`deepseek-flash`) with macOS Keychain key isolation.
