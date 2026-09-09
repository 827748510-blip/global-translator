# 本机本地翻译配置

安装日期：2026-09-06。设备实测为 Apple M5、16 GB 内存、macOS 26.6.2。

## 已安装

- Homebrew Ollama CLI `0.33.3`，路径 `/opt/homebrew/bin/ollama`，未安装 Ollama GUI。
- 官方模型 `qwen3:4b-instruct-2507-q4_K_M`，模型 ID `0edcdef34593`。
- 翻译器使用的配置别名 `global-translator-local:qwen3-4b`，ID `e6834c2faa46`。
- 两个模型名共享权重，`~/.ollama/models` 实际约 2.3 GiB；加载时实测约 3.2 GB、100% GPU。
- 翻译器可执行文件：`~/.local/bin/global-translator`。

模型为约 2.5 GB 的 4.02B、Q4_K_M 指令版本，支持多语言翻译。来源：[Ollama 官方模型页](https://ollama.com/library/qwen3:4b-instruct-2507-q4_K_M)。选择它是为了给这台 16 GB Mac 上的其他应用保留内存，性能以实测为准。

## 配置位置

- 服务环境：`~/.homebrew/services/ollama.env`，权限 0600。
- 模型文件：`~/.ollama/models`，不在 Git 仓库内。
- 翻译器配置：`~/Library/Application Support/GlobalTranslator/config.json`，权限 0600。

服务只监听 `127.0.0.1:11434`，设置单并发、最多加载一个模型、Flash Attention、q8_0 KV cache 和 `OLLAMA_NO_CLOUD=1`。建议在 `ollama.env` 里加 `OLLAMA_KEEP_ALIVE=30m`，避免每次冷加载。不要用 `keep_alive=-1` 把模型永久占在显存里。

推荐模型别名参数（已在用户机器上把 `num_ctx`/`num_predict` 从 8192/2048 收紧；上下文缩小能省显存，短句延迟主要由结构化输出决定）：

```text
FROM qwen3:4b-instruct-2507-q4_K_M
PARAMETER num_ctx 2048
PARAMETER temperature 0
PARAMETER num_predict 256
```

翻译器默认选择 `local` 后端、`http://127.0.0.1:11434/v1`、`global-translator-local:qwen3-4b`；云端视觉回退关闭。默认排除 Codex、Passwords、CC Switch、微信和企业微信。未创建翻译器安装包、登录项或模型自动下载逻辑。

本地页内/扩展桥与覆盖层都按最多 3 段拆批（与扩展 `CHUNK_SIZE` 对齐），并复用相同文字的在途结果。请求带 `max_tokens`（单条 128、三条约 256），`response_format` 为 `json_object`，系统提示极短，用户侧用 `0:`/`1:`/`2:` 短键（客户端映射回 UUID）。不静默切到云端。用户已批准对 AX/OCR 当前窗口都启用最高 4 帧/秒、256×256 的本地变化检测；检测画面不保存、不上传。完整验收结果及性能边界见 [当前真实验收记录](real-acceptance-current.md)。

## 启动与停止

```bash
# 注销/重启之后，手动启动本地模型服务，不注册登录自启
brew services run ollama

# 启动翻译器
~/.local/bin/global-translator start
~/.local/bin/global-translator status

# 停止翻译器
~/.local/bin/global-translator stop

# 不再需要本地模型服务时
brew services stop ollama
```

本次 `brew services info ollama --json` 实测 `running=true`、`registered=false`。不要用 `brew services start/restart` 代替上面的 `run`，前者会注册登录自启。

## 接口与实测边界

本地服务必须支持 OpenAI 风格 `/models`、`/chat/completions`，以及 `response_format.type=json_object` 与 `max_tokens`。本机对照：应用风格的长 system + UUID JSON 用户体，无论 `json_object` 还是 `json_schema` 都是约 1.26–1.32s/短句。极短提示 `Translate to Simplified Chinese only: Hello world` 约 0.12–0.21s 且会出中文。过短的 `To zh-Hans` 会让模型原样回英文。本地路径用短 JSON 合同 + `Translate to Simplified Chinese`、`0:`/`1:`/`2:` 短键（客户端映射回 UUID）。解析后会剥掉译文里漏进来的 `0：`/`1:` 前缀，并接受把三句写进一条编号字符串、或把 `0:source` 当 JSON 键的回包。仍对「该译的拉丁文被原样回写」做校验失败重试。DeepSeek 云端仍用长提示 + JSON Schema。不静默切云。来源：[Ollama 结构化输出文档](https://docs.ollama.com/capabilities/structured-outputs)。

生产适配器早期连续 10 个单句（当时还是 schema）中位数约 1.60 秒。PR #3 第一轮约 1.35s；第二轮瘦提示词约 **0.33s/句、0.80s/三句**，但曾把英文原样返回。本轮目标：短句本机常常 **0.3–0.6s** 且译文为简体中文。以本机 `engine_completed` 为准。

本地模式启动不读取 DeepSeek Keychain。切换云端或运行涉及 Keychain 的诊断时，重编译/移动二进制仍可能引起 macOS 的钥匙串授权提示；请直接在系统界面处理，不向助手发送登录密码。
