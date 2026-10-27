# 浏览器桥接的来源语言上下文

PR #33 的前端页面语言放行没有进入桌面端：`切手`、`大丈夫` 在会话和批处理过滤中仍被当作简体中文。桥接现在把可选的 `sourceLanguage` 从整页内容脚本传给 service worker、HTTP 服务、会话、快照、批处理和模型请求，并将其加入内存缓存键。目标仍为简体中文。

`POST /translate` 保留 `texts` 数组及原有数量、UTF-8 大小和速率限制。`sourceLanguage` 可省略；存在时必须是非空字符串，最多 63 个 ASCII 字符，首段为 2–3 个字母，其余为连字符分隔的 1–8 个字母或数字。这是有界的 BCP-47 形状子集校验，不查询 IANA 注册表。`null`、非字符串、空白、换行、下划线和超长值返回 400。内容脚本会省略不合法的 HTML `lang`。

服务端只对准确匹配的 `ja`、`ko`、`zh-Hant` 或中文 TW/HK/MO 地区提示允许纯汉字翻译；显式 `zh-Hans` 优先于地区。`java`、`zh-x-tw`、`zh-Hans-TW` 不触发该例外。来源语言始终只是内容提示，URL、路径、邮箱、快捷键和标识符过滤继续执行。模型提示仅加入已校验、规范化的语言标签，原文仍是不可信数据。

旧请求缺少字段时保持原有按文本检测行为，普通简体中文不调用模型。字幕请求继续使用自己的无提示协议，不继承宿主页面语言。纯汉字没有来源提示时仍可能无法分辨日文与中文；语言声明错误或混合语言页面也不能仅凭元数据精确识别每个节点。

原版脚本在日文样例中依次提交了 `切手`、自身译文 `邮票`，证实了 DOM 回流。内容脚本现在跳过同一节点仍显示的自身译文；页面恢复原文时复用该节点缓存，出现新内容时继续翻译。繁体页面也受同样保护。

桥接仍仅监听 loopback，保留固定扩展 Origin、同源响应、主开关、队列及原有捕获权限语义；未新增扩展权限或修改任何用户设置。语言与翻译缓存仅驻内存。

## 回归验证

```sh
GT_LIVE_OLLAMA=0 GT_RENDER_UI=0 swift test -Xswiftc -warnings-as-errors --skip CDPHeadlessVerificationTests
swift build -c release -Xswiftc -warnings-as-errors
for test in extension/*.test.js; do node "$test" || exit; done
```

旧 `CDPHeadlessVerificationTests` 会自动尝试操作固定 9223 端口的现有浏览器，因此本次明确跳过。替代验证使用独立 Chromium 和合成页面。真实 Ollama 烟测保持关闭。

`BridgeLanguageIntegrationTests` 使用真实临时 HTTP 服务、真实 `TranslationSession` / `TranslationCoordinator` / `TranslationBatcher` / 缓存，以及真实本地与云端适配器；仅将模型的 HTTPTransport 替换为进程内假响应，断言调用内容及返回。包括日文纯汉字、繁体、普通中文、缺失/非法提示、Origin 拒绝、大小限制、跳过片段、主开关、批处理拆分、去重、缓存隔离、重试与旧字幕请求。测试不会读取真实 Keychain 或调用任何模型。

完整浏览器验证需已有 Playwright 和测试 Chromium，通过环境变量指定路径，无需安装依赖或复用用户登录态：

```sh
GT_LIVE_OLLAMA=0 GT_BRIDGE_BROWSER=1 \
GT_PLAYWRIGHT_MODULE=/absolute/path/to/playwright \
GT_CHROMIUM_PATH='/absolute/path/to/testing-chromium' \
swift test -Xswiftc -warnings-as-errors --filter BridgeLanguageIntegrationTests
```

该测试只在临时扩展副本中把桥接目标改为 fixture 的随机端口，沿用正式 manifest key 和 Origin。它加载正式内容脚本、background 和字幕脚本，在 loopback 合成页面中检查 DOM 与原生 TextTrack 闭合 Shadow DOM 内的中文显示，结束时关闭浏览器并清除测试配置。正式扩展版本为 1.0.12。

## CDP 与生产包装器的补充验证

CDP 提取的 `InPageText` 同样携带已校验的来源语言，会话按上下文分组后传给 pageText 快照。CDP 回写只接受尚未改变的提取原文，保留自身译文状态以避免回流。扩展和 CDP 的 DOM 写入均规范化译文首尾空白，匹配缓存与比较使用相同值。

生产 `LiveTranslationBackendFactory` 的本地链路包括 coalescer 和共用串行槽。coalescer 的进行中请求与已完成结果均按原文集合、来源语言、目标语言和 copied-source 策略隔离；ID 和 revision 仍可重映射。集成测试现在经过该实际 factory，不再只实例化裸适配器。

`CDPLanguageIntegrationTests` 使用单独 Chromium 的随机调试端口，通过真实 CDP、会话和生产 factory 验证日文、韩文、繁体、普通中文及缺失/非法语言；本地与云端适配器均使用假传输。扩展浏览器测试也分别覆盖这两个后端，云端假响应刻意保留译文尾随空格/换行，确认 DOM、原文恢复和 mutation 请求数仍幂等。`CoalescingRequestContextTests` 验证进行中请求的隔离与相同上下文的 ID/revision 重映射。

本次桌面打包版本为 1.1.3（2026102701），使用 `scripts/package-app.sh` 的既有 `Global Translator Dev` 签名身份。
