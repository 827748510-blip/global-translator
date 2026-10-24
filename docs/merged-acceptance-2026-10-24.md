# 合并后真机验收记录（2026-10-24）

## 合并与构建

- PR #26（划词翻译失灵修复）已合并，merge commit `3da3dec`。
- PR #27（中英双向互译 + 截图保存/复制）已合并，merge commit `31e4263`。
- 合并后 `main`：`swift test -Xswiftc -warnings-as-errors` **545 tests / 52 suites 全绿**。
- 合并版已通过 `scripts/package-app.sh` 安装到 `/Applications` 与 `~/Applications`，三处二进制 md5 均为 `311a34cde88fac52db2da24fc172dcb0`。
- 安装前旧版备份：`.build/desktop/backup-20261024-114156/`。

## 划词双向互译（真实划选 + 可控后端）

使用本机 TextEdit 和安装版 App，通过真实鼠标拖选触发划词翻译。临时把 `localBaseURL` 指向 `127.0.0.1:11435` 的 mock，记录 App 实际发出的 system/user prompt；mock 只返回可解析译文，验收后已恢复真实 Ollama 配置并重启。

| 场景 | 证据 | 结果 |
| --- | --- | --- |
| 中文选区 | mock 记录 `REQ dir=toEnglish sys_en=True user_first='Translate to English:' source='发给我。'` | 中文→英文，通过 |
| 英文选区 | mock 记录 `REQ dir=toChinese sys_en=False user_first='Translate to Simplified Chinese:' source='wn fox jumps over the lazy'` | 英文→简体中文，通过 |

另外，直接用真实 Ollama 验证新英文 prompt：中文「你好世界 / 一个女孩站在雨里 / 请在合并之前审查该拉取请求 / 请在周四前把报告发给我」均得到正确英文。

## 截图保存/复制验收边界

- `saveScreenshotImage` / `copyScreenshotImage` 的开关、目录创建、PNG 落盘、弹层路径提示、失败不阻断翻译均有自动化测试（`ScreenshotImageIOTests`、`ScreenshotTranslateControllerTests`、`GlassUIRenderTests`）。
- 本机键盘自动化被权限限制：`cliclick` 的 `t:t` 与直接 `CGEvent` 都没有触发 `screenshot_hotkey` 日志，因此本轮**没有完成真实 ⌃⇧T → 区域拖选 → OCR → 保存/复制** 的完整 GUI 验收。
- 划词验收不依赖截图/键盘注入，使用运行日志 + mock 请求记录；未伪造截图通过证据。

## 当前状态

- mock 服务已停止；配置恢复为 `http://127.0.0.1:11434/v1`，真实 Ollama 可用。
- 合并版安装后已升级为毛玻璃 UI 新版（见 `docs/glass-ui-2026-10-24.md`），回滚备份仍在 `.build/desktop/`。
