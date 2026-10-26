# DeepSeek V4.1（2026-10）适配与 Keychain 安全

## 官网当前配置

- OpenAI 兼容 Base URL：`https://api.deepseek.com`
- Responses API：`POST /responses`；模型列表：`GET /models`
- 官网当前模型：
  - `deepseek-flash`：DeepSeek-V4.1-Flash-1017，支持视觉、思考/非思考
  - `deepseek-v4-pro`：DeepSeek-V4-Pro-0813，文本模型，不支持视觉
- **本应用只适配 `deepseek-flash`**。`deepseek-v4-pro` 不在设置页展示、不会被选择或发送；`/models` 返回的其他模型也会被过滤。
- 思考模式由 `reasoning.effort` 控制；本应用翻译请求固定传 `reasoning.effort = "none"`，避免把输出预算耗在思维链上
- 官方文档：
  - [Your First API Call](https://api-docs.deepseek.com/)
  - [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing/)
  - [Responses API](https://api-docs.deepseek.com/api/create-response/)
  - [Lists Models](https://api-docs.deepseek.com/api/list-models/)
  - [Vision](https://api-docs.deepseek.com/guides/vision/)

## 迁移策略

应用启动读取旧 `config.json` 时，会在解码阶段把所有非 `deepseek-flash` 的模型 ID 迁移为 `deepseek-flash`：

| 旧 ID / 其他 ID | 迁移后 |
| --- | --- |
| `deepseek-chat` | `deepseek-flash` |
| `deepseek-reasoner` | `deepseek-flash` |
| `deepseek-v4-flash` | `deepseek-flash` |
| `deepseek-v4-flash-vision-exp` | `deepseek-flash` |
| `deepseek-v4-pro` | `deepseek-flash` |
| 未知 / 未来 ID | `deepseek-flash` |

`/models` 返回的列表只保留 `deepseek-flash`；如果账号没有该模型，健康检查明确返回模型不可用，不会回退到其他模型。设置页模型列表因此最多只有一项。

## 请求格式

- OpenAI Responses API 结构：`model`、`input`（system/user message）、`reasoning`、`temperature`、`text.format`（JSON Schema）。
- 翻译请求增加 `max_output_tokens = 8192`，避免输出失控；纯文本补答保持 2048。
- 视觉请求也使用 `deepseek-flash`，官方仅该模型支持 `input_image`。
- 请求带 `Content-Type: application/json`、`Accept: application/json`、`Authorization: Bearer <key>`。
- 固定基址，拒绝 HTTP 重定向；不把 Key 发往其他主机。

## API Key 安全

- 只存 macOS **data-protection Keychain**，Service `com.maodashu.global-translator.deepseek`，Account `default`。
- 存储属性：`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、`kSecAttrSynchronizable=false`，设备绑定、不随 iCloud Keychain 同步。
- 应用更新已有 Keychain 项时也会重新写入安全属性，修复旧版本可能较弱的可访问性。
- 保存前统一 trim，只接受可见 ASCII（禁止换行、控制字符、空格和非 ASCII），防止 `Authorization` 头注入；最长 4096 字符。
- `config.json` 只保存 `deepSeekAPIKeyConfigured: Bool`，不包含密钥；错误信息、日志、缓存、请求参数和环境变量都不含 Key。
- Settings 中的 `keyDraft` 仅在编辑期间存在，保存成功、取消替换或切换后端都会清空。
- 旧登录钥匙串条目仅在迁移时读取一次，迁移成功即删除旧项；迁移失败则保留原项，避免丢 Key。

## 验证

```bash
swift test -Xswiftc -warnings-as-errors --filter 'deepSeek|DeepSeek|credential|APIKey'
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
```

覆盖：默认模型、旧配置迁移、`/models` 选择、Responses 请求模型/字段、视觉模型固定为 flash、Key 校验与配置不含密钥。

本轮自动化测试使用 mock transport，不调用真实计费接口；正式上线前建议用户亲自在设置页点一次“测试连接”做真实账号验收。

Keychain 的最终验收需要在已签名的 `.app` 中进行：SwiftPM 测试进程没有 data-protection Keychain 权限，真实写入会返回 `errSecMissingEntitlement (-34018)`，因此自动化测试覆盖密钥校验、配置不含明文和 mock 凭据路径，真实钥匙串读写请在安装后的 App 设置页保存一次 Key、重启后再翻译验证。
