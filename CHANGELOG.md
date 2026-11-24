# Changelog

All notable changes to **Global Translator** are documented in this file.

## [1.1.3] - 2026-11-24

Initial public open-source release under the MIT License.

### Highlights

- **Desktop App & CLI**: Native Apple Silicon macOS utility featuring Liquid Glass settings and popovers, single-instance Unix socket supervision, `doctor` diagnostics, and optional `launchd` keep-alive template.
- **Click-Through Window Overlay**: Accessibility-first active window text extraction with automatic on-device Apple Vision OCR fallback, `256x256` 4 fps local visual change detection, and automatic Secure Input pause.
- **Universal Selection Translate**: Automatic bidirectional translation, async lossless clipboard fallback for Feishu/Lark/Electron apps, 3-mode prompt polishing, and automatic 15+ language code explanation mode.
- **On-Device OCR Screenshot Translate**: Local Apple Vision OCR region capture with zero cloud image uploads, plus optional auto-copy and local PNG save/clipboard copy toggles.
- **Chrome Extension (v1.0.12)**: Multi-language in-page DOM translation and dual-mode video Chinese subtitle overlay supporting HTML5 video tracks, local `.srt`/`.vtt` files, YouTube captions, and local ScreenCaptureKit + `whisper.cpp` transcription for uncaptioned videos.
- **Dual Translation Backends**: Offline loopback Ollama (`127.0.0.1:11434`) with automatic Homebrew suspend/resume and DeepSeek Cloud (`deepseek-flash`) with macOS Keychain key isolation.
