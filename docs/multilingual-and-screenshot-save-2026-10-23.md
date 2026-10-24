# 中英双向互译 + 截图保存/复制（2026-10-23）

## 目标

1. **划词翻译双向互译**：在现有划词翻译上扩展多语言互译 —— 英文 / 其他外文 → 简体中文，简体中文 → 英文，方向自动判定，无需设置。
2. **截图翻译增强**：
   - 截图后自动提取图像文字（OCR，本机 Vision，沿用既有实现）；
   - 新增「保存截图为 PNG 文件」「复制截图到剪贴板」两个开关，提供默认保存路径并在界面 / 弹层明确展示路径提示。

## 设计要点

### 双向互译

- 方向只在**划词 / 截图翻译**这条独立链路生效；窗口覆盖层与 Chrome 扩展桥保持「只译成简体中文」不变（它们的 `TextFilter.shouldTranslate` 语义没动）。
- `TextFilter.selectionDirection(_:)`：简体中文源 → `.toEnglish`；其余可翻译文本 → `.toChinese`；URL / 标识符 → nil（不弹层）。`.noTranslationNeeded`（品牌词）仍 → `.toChinese`。
- 新增 `SelectionTranslationDirection`，`TranslationRequest` 增加可选 `targetLanguage`（默认 nil）。协调器把它贯通到批处理和**缓存键**（同一文本的中文/英文译文分开缓存），后端按它选 prompt：
  - 本地 `LocalTranslationPrompt`：中文目标仍是 `JSON {"0":"中文"…}`；英文目标是 `JSON {"0":"English"…}` + `Translate to English:`。
  - 云端 `TranslationInstructions.system(for:)` 按方向切换；`SelectionFallbackInstructions`（回声兜底）也按方向切换。
- 划词控制器里「已是中文」分支改为直接翻译（译成英文）；截图 OCR 出中文也译成英文。「优化提示词」对中文草稿仍可用（作用于中文原文）。
- `presentAlreadyChinese` 已删除；`SelectionPopoverStatus.alreadyChinese` 状态保留但未再产出（UI 兼容）。

### 截图保存 / 复制

- 配置：`saveScreenshotImage`、`copyScreenshotImage`（默认均关）、`screenshotSaveDirectory`（默认 `~/Pictures/Global Translator 截图`，可改，缺失/空白时回退默认）。旧 config 无这三个键也能解码。
- 保存 / 复制发生在 **OCR 之前**（图片先写入剪贴板；若「自动复制译文」也开，译文随后会覆盖剪贴板，剪贴板终态是译文文本）：即使识别不到文字或翻译失败，截图也已按开关保留。
- `ScreenshotImageIO`（App 层）：PNG 写入、目录自动创建、文件名 `截图翻译-YYYYMMDD-HHMMSS-xxxx.png`（秒级 + 短后缀防覆盖）、剪贴板写 PNG。注入点分离，便于测试。
- 保存成功后弹层在译文下方显示 **已保存到 <路径>**（`~` 缩写、中间截断、可选中复制）。保存失败只记日志（`screenshot_save_failed`），不阻断翻译。
- 设置页新增「保存截图」「复制截图」两个开关和「保存位置」行（显示当前目录 + 选择…按钮）。

## 改动文件

- Core：`TextFilter.swift`（方向枚举 + selectionDirection）、`TranslationInstructions.swift`（方向感知 prompt）、`Domain.swift`（TranslationRequest.targetLanguage）、`LocalOpenAIBackend.swift`、`DeepSeekBackend.swift`、`AppConfiguration.swift`（三个新字段）、`SelectionTranslate.swift`（savedImagePath + displayPath + 提示文案）。
- Engine：`TranslationBatcher.swift`、`TranslationCoordinator.swift`（targetLanguage 贯通 + 缓存键）。
- App：`TranslationSession.swift`（自动判向 + 贯通结构/兜底两条路）、`SelectionTranslateController.swift`（中文→英文）、`ScreenshotTranslateController.swift`（中文→英文 + 保存/复制）、`ScreenshotImageIO.swift`（新增）、`ApplicationController.swift`、`ApplicationActions.swift`（含目录选择器）。
- UI：`SettingsSections.swift`（两个开关 + 路径行）、`SettingsViewModel.swift`、`UIContracts.swift`、`PrimitiveShowcase.swift`、`SelectionTranslatePopoverView.swift`（路径提示）、`SelectionTranslatePanelController.swift`（高度）。
- 测试：`SelectionDirectionTests.swift`、`SelectionDirectionCoordinatorTests.swift`、`ScreenshotImageIOTests.swift` 新增；其余若干更新。
- 文档：`docs/selection-translate.md`、`docs/screenshot-translate.md`、`README.md`、本文件。

## 验证

| 项目 | 结果 |
| --- | --- |
| `swift test -Xswiftc -warnings-as-errors` | 全绿：544 tests / 52 suites（新增方向检测、双后端 prompt 方向、协调器贯通、缓存分离、截图保存/复制/失败、配置 Codable、ViewModel 开关） |
| `swift build -c release -Xswiftc -warnings-as-errors` | 通过（15.6s） |
| `cd extension && node --test` | 6/6（扩展未改动） |
| 真实 Ollama prompt 冒烟 | `Translate to English:` + 英文 system prompt 下，「你好世界 / 一个女孩站在雨里 / 请在合并之前审查该拉取请求 / 请在周四前把报告发给我」均得到正确英文 |

## 未覆盖 / 残余风险

- **真机 GUI 未验收**：本机终端缺 TCC，未截图/未点界面；行为由单元测试 + 真实 Ollama prompt 冒烟覆盖。安装后实机验证（划词选中文看英文、截图保存路径提示）需人工。
- **DeepSeek 云端**：双向互译的云端 prompt 改动（`TranslationInstructions.system(for:)`）只经单测，未做真实往返（无 Key）。
- 中文源被模型回声时不会被「回声检测」拒绝（回声检测只覆盖含 ASCII 字母的源）；中文源回声会以原文当「英文」展示，属质量降级而非报错。
- 日文 / 韩文等仍译成简体中文（未扩展到其他语向）。

## 回滚

- 分支 `dsh/feature-multilingual-screenshot`（基于 `dsh/fix-selection-translate-resilience` `f4357d8`）。回滚切回 main 即可；config 新字段可向后兼容（缺失键回退默认值）。
