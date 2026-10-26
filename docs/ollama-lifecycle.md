# Ollama 生命周期（随翻译后端切换）

## 目标

把翻译后端切到 **DeepSeek 云端** 时停止本机 Ollama，释放内存/GPU；切回 **本地模型** 时先启动 Ollama，再执行本地后端健康检查。

## 实现边界

- 只管理 **Homebrew 服务**：调用 `/opt/homebrew/bin/brew` 或 `/usr/local/bin/brew` 的 `brew services`，不直接 `kill` 任意 `ollama serve`，也不调用未公开的模型卸载接口。需要 Homebrew 支持 `brew services stop --keep`；本机 Homebrew 7.0.9 已验证。旧版 brew 会停止失败但不会误停服务。
- 只管理默认本机 Ollama 地址：`http://127.0.0.1:11434/v1`（也接受 `localhost` / `::1`）。自定义端口、远程地址、LM Studio 等本地 OpenAI 兼容服务一律不动。
- 不需要额外权限；`brew services` 运行在当前登录用户域。
- 停止的是**全局 Homebrew Ollama 服务**，其他依赖 Ollama 的 App 会同时断掉。这是本功能的明确代价。
- 切换发生的瞬间，正在进行的本地翻译请求可能失败或中断；不会重放，也不会改发到云端。
- 切换操作异步执行，brew 不阻塞设置界面；连续快速切换时按“最后一次选择”收敛。

## 命令与恢复策略

暂停：

1. `brew services info ollama --json` 确认服务处于运行状态。
2. `brew services stop --keep ollama`。`--keep` 保留 LaunchAgent plist，登录注册状态跨进程保留；不会在应用退出/重启后丢失。
3. 轮询确认 `running/loaded` 已停止；超时记为失败并写日志。

恢复：

1. `brew services info ollama --json` 确认服务已停止，并读取 `registered`。
2. 如果当前服务已注册登录自启，执行 `brew services start ollama`；否则执行 `brew services run ollama`，避免新增登录项。判断来自 brew 的 `registered` 字段，不依赖内存状态，因此应用在云端状态重启后仍正确。
3. 轮询确认服务启动，并探测 `http://127.0.0.1:11434/api/tags` 直到 HTTP 就绪；就绪后才交给现有 `refreshBackend` 做模型/接口健康检查，避免 launchd 已报 PID 但端口尚未监听时把本地后端判成不可用。

超时：单条 brew 命令 75 秒（高于 brew `stop` 默认 60 秒等待），状态等待 15 秒，状态轮询间隔 1 秒。失败只记固定原因码（如 `stop_exit_1`、`start_not_observed`），不记录命令输出，避免日志带入本地路径等信息。

## 不会处理的情况

- 服务不是 Homebrew 管理（例如手工 `ollama serve`、Ollama.app、远程服务）。
- 本地地址不是默认 `:11434` 回环 HTTP 端口，或使用 HTTPS。
- brew 未安装或服务信息不可用：返回 unsupported，不尝试杀进程。
- 应用启动时如果已经是云端后端，不会额外执行暂停；只有发生**后端切换**才触发本功能。
- 应用在云端状态退出时不会自动重新启动 Ollama；下次切回本地才会启动。因为停止用了 `--keep`，原来的登录注册不受影响。

## 失败与手工恢复

如果日志出现 `ollama_lifecycle` 且结果为 `failed:*`，Ollama 可能仍处于停止状态。可手工恢复：

```bash
# 原本未注册登录自启
brew services run ollama

# 原本已注册登录自启
brew services start ollama

# 查看当前状态
brew services info ollama --json
```

若只是暂停失败，Ollama 仍在运行，不一定要手工操作；再次切换后端会重试。应用不会自动重放翻译请求。

## 日志

- `ollama_lifecycle`：`action=suspend|resume`，`result=started|stopped|already_running|already_stopped|unsupported:*|failed:*`
- `ollama_lifecycle_skipped`：`reason=endpoint_not_ollama`

只记录动作、结果和枚举原因，不记录模型内容、API Key 或 brew 输出。

## 验证

```bash
# 不触碰真实 Ollama 的单元/集成测试（使用 fake runner / fake lifecycle）
swift test -Xswiftc -warnings-as-errors --filter 'HomebrewOllamaLifecycleTests|switchingToCloudStopsOllama|customLocalEndpointNeverStopsOllama|defaultOllamaEndpointIsManaged'

# 全量
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

真机验收时请手动确认：

1. 本地后端运行中，切到 DeepSeek 云端，`brew services info ollama --json` 的 `running` 变为 `false`。
2. 切回本地模型，服务恢复运行，本地翻译可用。
3. 如果原本 `registered=false`，恢复后仍不应新增登录自启；若原为 `registered=true`，恢复后仍应保持注册。
4. 运行其他依赖 Ollama 的 App 时，注意本功能会中断它们；当前行为随后端切换自动执行，没有单独开关，需要关闭时只能改代码或改用非默认本地端口。
