# 贡献指南 / Contributing Guide

欢迎提交 Bug 修复、文档改进、跨应用兼容补丁或新的模型后端适配！在提交 PR 前，请先阅读以下开发约定。

## 开发环境准备

- Apple Silicon Mac，macOS 27+，Xcode / Swift 6.4 工具链
- Node.js 20+（用于运行 `extension/` 下的浏览器扩展单元测试）

克隆仓库后可通过以下命令完成编译与本地验证：

```bash
# 运行全部 Swift 单元测试（开启严格警告即错误）
swift test -Xswiftc -warnings-as-errors

# 运行 Release 严格并发构建检查
swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

# 运行 Chrome 扩展单元测试
node --test extension/*.test.js
```

## 本地打包与权限调试技巧

默认执行 `bash scripts/package-app.sh` 会使用 `-`（ad-hoc）签名生成 `.build/desktop/Global Translator.app`，开箱即用无需证书。注意 `scripts/make-release.sh` 出于安全考虑默认拒绝 ad-hoc 签名产物，若本地无证书仅做打包自测，请显式传入 `ALLOW_ADHOC=1 bash scripts/make-release.sh`。

如果你在反复修改代码并真机调试辅助功能 / 屏幕录制权限，建议在「钥匙串访问」中创建一张名为 `Global Translator Dev` 的本机自签名代码签名证书，然后通过环境变量固定签名身份，避免每次重编译后 `cdhash` 变化导致需要重新开关系统权限：

```bash
CODESIGN_IDENTITY="Global Translator Dev" bash scripts/package-app.sh
```

## 工程与架构红线

1. **Swift 6 严格并发**：所有模块必须在 `-strict-concurrency=complete` 与 `-warnings-as-errors` 下零警告通过编译。
2. **遵守隐私与设计约束**：修改 UI 前请阅读 [DESIGN.md](DESIGN.md)；涉及网络、日志、Keychain、剪贴板或音视频采集时，请严格遵守 [SECURITY.md](SECURITY.md) 中的五条安全不变量。
3. **保持测试覆盖**：修复边界缺陷（如特定应用的选区回退、字幕解析或模型返回格式容错）时，请在 `Tests/` 或 `extension/*.test.js` 中补充对应的回归单元测试。
