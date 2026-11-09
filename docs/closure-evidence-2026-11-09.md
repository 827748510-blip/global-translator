# 遗留问题关闭证据（2026-11-09）

本轮针对两份待办清单做闭环取证，基线为 `main` 的 `1c4ae01`（Merge PR #34，提交时间 2026-10-27 16:41 +0800），工作区仅有未跟踪的 `.trae-html-share-packages/`。

工具链：macOS 27.2（26B123）、Xcode 27.2（27B52）、Apple Swift 6.4.2，`xcode-select -p` 指向 `/Applications/Xcode.app/Contents/Developer`。

## 一、缓存目标语言：已关闭

**实现证据。** `TranslationCacheKey` 自 2a95d83（PR #33）起就是五元组，目标语言与来源语言都参与哈希：

- `Sources/GlobalTranslatorCore/TranslationCache.swift:3-24`：`source / backend / model / targetLanguage / sourceLanguage` 全部为 `let` 字段，`Hashable` 自动合成。
- `Sources/GlobalTranslatorEngine/TranslationCoordinator.swift:175-181`：查缓存时写入 `targetLanguage: effectiveTargetLanguage` 与 `sourceLanguage: sourceLanguage`。
- `Sources/GlobalTranslatorEngine/TranslationCoordinator.swift:279` 起：写回缓存使用同一构造，键完全对称。

**回归证据（本轮实跑通过）。**

| 测试 | 覆盖点 |
| --- | --- |
| `SelectionDirectionCoordinatorTests.cacheSeparatesChineseAndEnglishTranslationsOfTheSameText` | 同一句「你好世界」先译英、再译中，第二次不得命中第一次的缓存；断言后端请求数为 2 |
| `SelectionDirectionCoordinatorTests.coordinatorThreadsTargetLanguageIntoRequestAndCacheKey` | 划词中文→英文请求携带 `targetLanguage=en`；覆盖层路径保持 `nil` |
| `GlobalTranslatorCoreTests.translationCacheUsesLruAndSeparatesKeys` | 键的模型维度隔离 + LRU 淘汰顺序 |
| `GlobalTranslatorEngineConcurrencyTests.staleDelayedResultCannotPopulateCache` | 过期 revision 的迟到结果不得写缓存 |

结论：该问题在代码与自动化测试两层已闭环，无遗留缺陷。

## 二、长译文限制：已关闭（有明确边界与提示）

相关常量与行为：

| 位置 | 值 / 行为 |
| --- | --- |
| `Sources/GlobalTranslatorCore/LocalOpenAIBackend.swift:143-147` | `maxTokens(itemCount:sourceCharacters:)`：≤320 字符走覆盖层预算 128（1 条）/256（3 条）；超过后按 `sourceCharacters + 128` 放大，上限 2048 |
| `Sources/GlobalTranslatorCore/LocalOpenAIBackend.swift:149` | 纯文本兜底固定 1024 tokens |
| `Sources/GlobalTranslatorCore/SelectionTranslate.swift:503` | 单次选区硬上限 `48_000` 字符 |
| `Sources/GlobalTranslatorCore/SelectionTranslate.swift:507` | 纯文本兜底只对 ≤600 字符的块生效 |
| `Sources/GlobalTranslatorCore/SelectionTranslate.swift:511` | 截断文案「原文过长，仅翻译了部分内容」 |
| `Sources/GlobalTranslatorCore/AdapterSupport.swift:7` | 单条译文输出上限 8192 字符，超限判为 `invalidResponse`，不静默接受 |

设计取舍已写入 `docs/selection-translate.md`：>600 字符的块**不**回退纯文本补答，因为 1024 token 预算可能静默截断长译文；宁可保留明确失败。这是有意的边界，不是未修复缺陷。

**回归证据（本轮实跑通过）。**

- `GlobalTranslatorCoreTests.localBackendUsesBoundedMaxTokens...`：断言 128 / 256 / 长文本 >256 且 ≤2048，并校验实际请求体里的 `max_tokens` 等于计算值。
- `SelectionTranslateTests` / `SelectionTranslatePopoverTests` / `ApplicationControllerTests`：断言超硬上限时 `displayTranslation` 含截断文案，未超限时不含。
- `SelectionFallbackTests`：超 600 字符的块不进入纯文本兜底。

结论：长译文的预算阶梯、硬上限与用户可见提示三者一致，且有正向与反向断言，已闭环。

## 三、完整 macOS 编译与测试：通过

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
```

- Release 构建：`Build complete! (28.39秒)`，退出码 0，197 个编译单元。构建期仅有 `PIF: Ignoring settings assignments for unknown platform 'DoesNotExist'` 提示，来自 SwiftPM 对 Xcode 项目模型的解析，不影响产物。
- 全量测试：**627 tests / 62 suites 全通过**，退出码 0。分 suite 汇总：

| 套件组 | 用例数 | 套件数 | 耗时 |
| --- | --- | --- | --- |
| Core | 100 | 7 | 1.312 s |
| Runtime | 26 | 1 | 1.025 s |
| Capture | 35 | 3 | 0.606 s |
| UI | 150 | 23 | 0.206 s |
| Engine | 93 | 14 | 1.895 s |
| App | 223 | 14 | 12.831 s |

完整日志：`.build/test-full-20261109-123047.log`（构建产物目录，未入库）。

上一轮记录（`docs/merged-acceptance-2026-10-24.md`）的 545 tests 与本轮 627 的差异来自参数化用例展开与后续 PR 新增测试，不是漏跑。

## 四、打包与签名：通过

`bash scripts/package-app.sh` 退出码 0：

- 产物 `.build/desktop/Global Translator.app`，`Info.plist` 版本 1.1.3 / build 2026102701。
- 签名 `Authority=Global Translator Dev`，`codesign --verify --strict` 通过（valid on disk / satisfies its Designated Requirement）。
- 可执行文件 md5 `61c244fd2b55d1b7c239a0649326399a`。

注意：`security find-identity -v -p codesigning` 在本机返回 **0 valid identities**，但自签名证书 `CN=Global Translator Dev` 确实存在于登录钥匙串，`codesign` 仍可正常签名。该证书未被标记为代码签名信任，因此不进入 `find-identity` 的有效列表。这会影响公证，不影响本地 ad-hoc 级别的自签名分发。

打包前已把旧产物完整备份到 `.build/desktop/backup-pre-rebuild-20261109-123147/`。

## 五、界面验收：设置面板通过，两项受环境限制

**通过项。** 用隔离 runtime root 启动构建产物（`GLOBAL_TRANSLATOR_RUNTIME_ROOT=.build/iso-ui`），经 `settings` 命令唤起下拉设置面板，`CGWindowList` 读到 `onscreen=true`、`X=1109 Y=30 W=360 H=600`，截图 `.build/iso-ui/settings-panel.png` 完整可读：

- 顶部状态卡：自动翻译已关闭 / DeepSeek 后端已就绪；滑词翻译开关为开、视频翻译为关。
- 优化场景分段控件：沟通润色（选中）/ 任务指令 / 用词修正。
- 截图翻译组：快捷键 ⌃⇧T（隔离 root 无用户配置，取默认值；安装版读用户配置，实测为 ⌥`）与「录制」按钮、自动复制译文（关）、保存截图（关）、复制截图（关）。
- 要翻译的应用：选择应用按钮与未选择占位。
- 翻译后端：DeepSeek 云端（选中）/ 本地模型分段，附 Ollama 切换说明。

深色系统下为浅灰玻璃卡片、深色文字，对比度正常，无裁切、无重叠、无空白块。

**限制一：菜单栏图标不可见。** 菜单栏截图中没有蓝色「译」图标；`peekaboo menubar list` 只枚举到系统 `MenuBarAgent`（frame 宽高为 0）。这与 README「已知系统限制」一致：ControlCenter 以 `.ephemeral` 托管状态项，空间不足时不渲染像素。

由此派生的缺陷**已修复（PR #35，merge `db31daa`）**。修复前：用 `open -n` 首次启动实例后，面板虽被创建（`layer=3`、360×600）但 `onscreen=false`，必须再执行一次 `global-translator settings` 才显示。三处改动：

- `DropdownLayout.panelAnchor`：图标几何不可用（无 window、零尺寸、不在可见区域）时退回可见区域右上角，顶边夹在可见范围内；
- `DropdownPanel.present`：把 `anchorTopLeft` 正确换算成窗口左下角 origin，不再依赖 AppKit 隐式 constrain；
- `StatusItemController`：去掉 `didResignActive` 的强制关闭，`resignKey` 延迟 300 ms 再判断「App 是否仍在前台」。

实测证据（隔离 root，`open -n --env GLOBAL_TRANSLATOR_RUNTIME_ROOT=…`）：冷启动 1.5 s 后 `onscreen=true`、`X=1552 Y=38 360×600`、`alpha=1.0`，截图确认面板渲染完整；再点击外部后 `onscreen=false`，关闭行为未回归。全量 630 tests / 62 suites 通过。

**同一区域的两处回归（P3/P2，已修复，PR #37，merge `3c45379`）**

- **P3：正常菜单栏图标被误判为不可用。** 归属判断原先用 `visibleFrame`，而真实菜单栏图标整块位于该矩形之外、只与它的上沿相接；`CGRect.intersects` 对零面积交集返回 `false`，于是每个正常图标都被判成不可用，面板被推到备用角落。修法：归属判断改用 `screenFrame`，位置约束仍用 `visibleFrame`，并追加「图标必须落在顶部 60 pt 菜单栏带内」——实测 ControlCenter 托管时会返回 `(0,0,44,24)` 这类无意义 frame，它跟 `screenFrame` 相交，只靠相交判断会把面板锚到屏幕左下角（实测 `X=8 / Y=394`）。
- **P2：键盘切换应用后面板不关闭。** 移除 `didResignActive` 强制关闭后，Cmd-Tab 与切空间不产生鼠标事件，outside-click 监控看不到。修法：改听 `NSWorkspace.didActivateApplicationNotification` 与 `activeSpaceDidChangeNotification`，新增 `DropdownFocusPolicy`（显示后 1.2 s 内的失焦视为启动噪声），冷启动另给一次 5 秒内有效的豁免，避免把真正的切换漏掉。
- 实测：冷启动 2.2 s `onscreen=true`；切 Finder、切 Chrome 后 1 s 内均 `onscreen=false`；正常图标路径锚点 `X=1324`（贴近图标），无有效几何时 `X=1552`（右上角）。全量 633 tests / 62 suites 通过。

**限制二：划词弹层未完成实机取证。** 用 `cliclick` 在 TextEdit 中真实拖选（7→48 个拖拽事件、位移 228–489 pt），日志确认手势判定为 `verdict=textSelection`，随后出现 `selection_unreadable`：注入式拖拽没有让 TextEdit 真正产生选中文本，AX 读不到、⌘C 兜底也拿不到内容。该链路的弹层渲染与交互由 `SelectionTranslatePopoverTests`、`GlassUIRenderTests`、`ApplicationControllerTests` 中的 45 个以上用例覆盖并通过，但**真机划词弹层本轮仍记未完成**，不用自动化结论替代。

**限制三已解除：截图翻译热键实机验收通过，此前记录有误。** 多轮记录称「⌃⇧T 键盘注入无法触发 `screenshot_hotkey`」，根因是键位假设错误：安装版读取用户配置 `~/Library/Application Support/GlobalTranslator/config.json`，其中 `screenshotTranslateHotkey = {control: false, option: true, shift: false, command: false, keyCode: 50}`，即 **⌥`**，早已不是默认的 ⌃⇧T；而隔离实例读默认配置，所以本页第 91 行的截图仍显示 ⌃⇧T。按真实键位注入后：

| 步骤 | 观测 |
| --- | --- |
| 注入 ⌥` | 出现 `layer=1000`、`1920×1080`、`onscreen=true` 的全屏覆盖层 |
| 注入 Esc（keyCode 53） | 覆盖层消失，取消路径正常 |

同轮修掉一个显示缺陷：`KeyboardShortcutSpec.namedKeys` 未收录 keyCode 50，UI 把 ⌥` 渲染成 `⌥Key50`。已补齐 ANSI 标点键（`` ` `` `-` `=` `[` `]` `\` `;` `'` `,` `.` `/` `§`），新增 `punctuationKeysRenderAsSymbolsInsteadOfRawNumbers` 覆盖断言；未收录键码仍回退 `Key<code>`，保证不渲染空白。

**本次验证边界：** 只覆盖「热键 → 覆盖层 → Esc 取消」。拖选区域 → 本机 Vision OCR → 后端翻译 → 结果弹层的全链路未在真机取证，该部分由 `ScreenshotTranslateCoreTests` 与 UI 层测试覆盖。

修完键名后全量 `swift test -Xswiftc -warnings-as-errors`：**634 tests / 62 suites 通过**（较上轮新增 1 个键名用例）。

## 六、隔离启动链退出 71：未复现，待确认原始命令

在隔离 root 上逐项实测，**未出现 71**：

| 变体 | 命令 | 退出码 |
| --- | --- | --- |
| status（空 root） | `--runtime-root .build/isolated-71 status` | 1（未运行，符合设计） |
| start / status / stop | `--runtime-root .build/isolated-71 start` → `status` → `stop` | 0 / 0 / 0 |
| doctor | `--runtime-root .build/iso-doctor doctor` | 0（8 PASS + 1 WARN） |
| 前台运行 | `--runtime-root .build/iso-fg run --foreground` | 存活 4 s，SIGTERM 正常退出 |
| GUI 直启 | `GLOBAL_TRANSLATOR_RUNTIME_ROOT=… Contents/MacOS/global-translator` | 存活，`bridge_listening port=9233` |
| LaunchServices | `open -n …app --env GLOBAL_TRANSLATOR_RUNTIME_ROOT=…` | 0，worker 正常启动 |
| 最小环境 | `env -i <bin> --runtime-root … status` | 1（未运行） |
| 相对路径 | `--runtime-root .build/iso-rel status` | 2（参数无效，符合设计） |
| `/tmp` 路径 | `--runtime-root /tmp/gt-iso-test status` | 1（未运行；本版未因符号链接拒绝） |

CLI 显式退出码只有 0 / 1 / 2（`Sources/GlobalTranslatorCLI/main.swift:27,32`），源码里不存在 `exit(71)`。因此 71 只能来自外部：`launchctl` 在受限会话下的 `bootstrap` 失败（EX_OSERR / EPERM 封装）、被 Gatekeeper 或 TCC 拒绝的 `exec`、或某条自定义 shell 链路的 `set -e` 透传。

**需要 BOSS 提供当时那条隔离启动链的完整命令与上下文**（是否经过 `launchctl`、是否在 SSH/无 GUI 会话、是否用了已经失效的二进制路径），才能定位到具体环节；在拿到原始命令前不臆测根因。

## 七、开源发布与发行包：准备完成，公开动作待授权

原始事实核查：

- `gh repo view`：`827748510-blip/global-translator`，`visibility=PRIVATE`，`licenseInfo=null`。
- 仓库根目录无 `LICENSE` / `COPYING` / `NOTICE`。
- `scripts/package-app.sh` 只产出本地 `.app`，没有 zip / dmg / 校验和的生成步骤。

无许可证的仓库即使转公开，默认仍是「保留所有权利」，他人不能合法使用、修改或分发。按本轮决策已补齐：

**1. 许可证。** 新增 `LICENSE`（MIT，`Copyright (c) 2026 maodashu`），README 增加「许可证」与「发行包」两节。

**2. 发行包脚本。** 新增 `scripts/make-release.sh`：读 `Info.plist` 取版本与 build、`lipo` 取架构、`codesign --verify --strict` 校验签名、`ditto` 打包、生成同名 `.sha256`。脚本只写 `dist/`，不触碰已安装副本；`dist/` 已加入 `.gitignore`。

**3. 实际产物。** `bash scripts/make-release.sh` 退出码 0：

| 项目 | 值 |
| --- | --- |
| 文件 | `dist/Global-Translator-1.1.3-arm64.zip` |
| 大小 | 1.6 MB |
| 版本 / build | 1.1.3 / 2026102701 |
| 签名 | `Global Translator Dev` |
| SHA256 | `e7edf3c1c139ca0ac02850a65d04564ea91ebf2006ac768ba79060a63248d39c` |
| 包内结构 | `Global Translator.app`、`LICENSE`、`README.md`、`安装说明.txt` |

**4. 解包冒烟。** `ditto -x` 解到 `.build/verify-release/` 后：`codesign --verify --strict` 通过（valid on disk / satisfies its Designated Requirement）；`shasum -a 256 -c` 返回 OK；解包后的二进制执行 `doctor` 全 PASS（仅固定路径 WARN）。

**仍未执行（需 BOSS 授权）：** 把仓库转公开、创建 GitHub Release 并上传 zip。这两步属于对外发布动作，按规则必须人工确认后单独执行。

## 八、本轮结论

| 事项 | 状态 |
| --- | --- |
| 缓存目标语言 | 已关闭（实现 + 4 项回归证据） |
| 长译文限制 | 已关闭（预算阶梯 + 硬上限 + 可见提示，正反向断言齐全） |
| 完整 macOS 编译 | 通过（Release，warnings-as-errors，28.39 s） |
| 全量测试 | 通过（627 tests / 62 suites） |
| 打包与签名 | 通过（1.1.3，自签名 valid） |
| 界面验收 | 设置面板通过；划词弹层未取证；截图热键已通过（⌥`） |
| 菜单栏图标不可见 | 系统层限制（ControlCenter 托管，图标宽高为 0），面板定位已加兜底 |
| 菜单栏面板冷启动不显示 | 已修复并实测通过（PR #35，merge `db31daa`） |
| 键盘切换不关面板 / 正常图标被误判 | 已修复并实测通过（PR #37，merge `3c45379`） |
| 截图热键显示为 `⌥Key50` | 已修复（补齐 ANSI 标点键名），测试覆盖 |
| 隔离启动退出 71 | 九种变体均未复现，待原始命令 |
| 开源发布 / 发行包 | 许可证与 zip 发行包已就绪；转公开与 Release 上传待授权 |
