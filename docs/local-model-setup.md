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

服务只监听 `127.0.0.1:11434`，设置单并发、最多加载一个模型、默认 8192 上下文、Flash Attention、q8_0 KV cache 和 `OLLAMA_NO_CLOUD=1`。

模型别名额外固定参数：

```text
FROM qwen3:4b-instruct-2507-q4_K_M
PARAMETER num_ctx 8192
PARAMETER temperature 0
PARAMETER num_predict 2048
```

翻译器默认选择 `local` 后端、`http://127.0.0.1:11434/v1`、`global-translator-local:qwen3-4b`；云端视觉回退关闭。默认排除 Codex、Passwords、CC Switch、微信和企业微信。未创建翻译器安装包、登录项或模型自动下载逻辑。

本地请求现按最多 6 段拆批，并复用相同文字的在途结果。用户已批准对 AX/OCR 当前窗口都启用最高 4 帧/秒、256×256 的本地变化检测；检测画面不保存、不上传。完整验收结果及性能边界见 [当前真实验收记录](real-acceptance-current.md)。

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

本地服务必须支持 OpenAI 风格 `/models`、`/chat/completions` 以及 `response_format.type=json_schema`。小模型在仅使用 `json_object` 时曾输出裸数组，且曾改写区域 ID；现在通过 JSON Schema 限定对象结构、结果数量和可用 ID，再由客户端验证完整性。来源：[Ollama 结构化输出文档](https://docs.ollama.com/capabilities/structured-outputs)。不支持该能力的其他本地服务不会被静默降级或切到云端。

生产适配器连续 10 个单句测试全部成功。延迟为 1823、1727、1488、1469、1556、1724、1567、1605、1665、1601 ms，中位数约 1.60 秒；这不是“亚秒达标”。整窗首次翻译可达约 9–11 秒。当前资源环境下，不能承诺方案中的本地 p50 ≤800 ms 或 p95 ≤1.5 s。

本地模式启动不读取 DeepSeek Keychain。切换云端或运行涉及 Keychain 的诊断时，重编译/移动二进制仍可能引起 macOS 的钥匙串授权提示；请直接在系统界面处理，不向助手发送登录密码。
