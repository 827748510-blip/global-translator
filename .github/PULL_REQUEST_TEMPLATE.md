## 变更说明 / Summary

- 简述本次 PR 解决的问题或新增的能力：

## 隐私与安全自检 / Privacy & Security Checklist

- [ ] 未将 API Key、原文、译文、截图或音频写入持久化配置或日志
- [ ] 未扩大不必要的系统权限（例如视觉流仍保持 `capturesAudio = false`，不触碰麦克风）
- [ ] 剪贴板兜底或安全输入（`SecureTextField`）边界未被破坏

## 验证方式 / Verification

- [ ] `swift test -Xswiftc -warnings-as-errors` 通过
- [ ] `swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` 通过
- [ ] `node --test extension/*.test.js` 通过（如涉及 `extension/` 改动）
