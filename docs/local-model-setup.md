# 本地模型配置指南（Ollama）

本文说明如何在 16 GB 及以上内存的 Apple Silicon Mac 上配置纯离线、低内存占用的本地翻译后端（基于 Homebrew Ollama 与 Q4_K_M 轻量指令模型）。

## 推荐组件与模型

- **Ollama CLI**：通过 Homebrew 安装（`/opt/homebrew/bin/ollama`），无需安装常驻 GUI。
- **推荐模型**：官方 `qwen3:4b-instruct-2507-q4_K_M`（约 2.3–2.5 GiB 权重，加载后约占 3.2 GB 统一内存）。来源：[Ollama 官方模型页](https://ollama.com/library/qwen3:4b-instruct-2507-q4_K_M)。
- **可选精简别名**：可基于官方权重创建自定义别名 `global-translator-local:qwen3-4b`，仅在需要收紧上下文窗口以节省显存时使用（两套名称共享底层权重，不重复占用磁盘）。
- **可执行文件入口**：`~/.local/bin/global-translator`（指向 `.app/Contents/MacOS/global-translator`）。

## 推荐配置位置

- **服务环境变量**：`~/.homebrew/services/ollama.env`（建议 `chmod 0600`）
- **模型文件目录**：`~/.ollama/models`（不在 Git 仓库内）
- **应用配置文件**：`~/Library/Application Support/GlobalTranslator/config.json`（应用自动强制 `0600` 权限）

建议让 Ollama 仅监听 `127.0.0.1:11434`，开启单并发、最多加载一个模型、Flash Attention、q8_0 KV cache 以及 `OLLAMA_NO_CLOUD=1`。可在 `ollama.env` 中设置 `OLLAMA_KEEP_ALIVE=30m` 以减少冷启动加载耗时，但不要设为 `-1` 避免模型永久锁死统一内存。

可选 Modelfile 精简参数（将 `num_ctx`/`num_predict` 从默认 `8192`/`2048` 收紧，进一步节省 16 GB 机型的显存占用）：

```text
FROM qwen3:4b-instruct-2507-q4_K_M
PARAMETER num_ctx 2048
PARAMETER temperature 0
PARAMETER num_predict 256
```

应用在「本地模型」模式下默认填写 `http://127.0.0.1:11434/v1`，并自动通过 `/v1/models` 枚举本机已拉取模型，不会擅自下载模型权重，也绝不静默切往云端。开启「自动翻译」时，对当前窗口启用最高 4 帧/秒、`256×256` 的内存内变化检测，图像样本不保存、不上传。

## 启动与停止

```bash
# 按需前台/后台启动本地模型服务（不强制注册登录自启）
brew services run ollama

# 启动与管理翻译器
~/.local/bin/global-translator start
~/.local/bin/global-translator status

# 停止翻译器
~/.local/bin/global-translator stop

# 不再需要本地模型服务时
brew services stop ollama
```

手工启动建议使用 `brew services run`（避免新增登录自启项）；若你本身已使用 `brew services start ollama` 注册了开机自启，应用在自动暂停后恢复服务时会严格还原你原先的注册状态。

### 切换后端时的自动启停

设置页把翻译后端从 **本地模型** 切到 **DeepSeek 云端** 时，应用会执行 `brew services stop --keep ollama`；`--keep` 保留 `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist`，因此无论应用是否在云端状态退出、重启，原登录注册状态都不会丢。切回本地模型前再启动服务并等待健康检查：

- 暂停前/当前已注册（`registered=true`）：恢复用 `brew services start`。
- 未注册：恢复用 `brew services run`，不新增登录项。
- 切到云端时即使 DeepSeek Key 尚未配置也会停止 Ollama；这是“切云端即暂停本地模型”的明确语义。
- 只处理默认回环地址 `:11434`、HTTP、且由 Homebrew 管理的服务。改用 LM Studio、HTTPS、非默认端口或手工 `ollama serve` 时，应用不会杀进程。
- 详细边界与验证见 [Ollama 生命周期](ollama-lifecycle.md)。

## 接口与实测边界

本地服务必须支持 OpenAI 风格 `/models`、`/chat/completions`，以及 `response_format.type=json_object` 与 `max_tokens`。本机对照：应用风格的长 system + UUID JSON 用户体，无论 `json_object` 还是 `json_schema` 都是约 1.26–1.32s/短句。极短提示 `Translate to Simplified Chinese only: Hello world` 约 0.12–0.21s 且会出中文。过短的 `To zh-Hans` 会让模型原样回英文。本地路径用短 JSON 合同 + `Translate to Simplified Chinese`、`0:`/`1:`/`2:` 短键（客户端映射回 UUID）。解析后会剥掉译文里漏进来的 `0：`/`1:` 前缀，并接受把三句写进一条编号字符串、或把 `0:source` 当 JSON 键的回包。仍对「该译的拉丁文被原样回写」做校验失败重试。DeepSeek 云端仍用长提示 + JSON Schema。不静默切云。来源：[Ollama 结构化输出文档](https://docs.ollama.com/capabilities/structured-outputs)。

生产适配器早期连续 10 个单句（当时还是 schema）中位数约 1.60 秒。PR #3 第一轮约 1.35s；第二轮瘦提示词约 **0.33s/句、0.80s/三句**，但曾把英文原样返回。本轮目标：短句本机常常 **0.3–0.6s** 且译文为简体中文。以本机 `engine_completed` 为准。

本地模式启动不读取 DeepSeek Keychain。切换云端或运行涉及 Keychain 的诊断时，重编译或替换签名不同的二进制文件可能会触发 macOS 系统钥匙串访问确认弹窗，按系统提示在界面确认即可（或使用固定本地签名身份打包）。
