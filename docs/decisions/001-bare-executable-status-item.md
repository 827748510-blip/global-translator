# ADR-001：保留裸 Mach-O，并拒绝私有状态栏强制显示方案

## 状态

接受

## 日期

2026-09-05

## 背景

产品硬性要求只交付终端启动的独立 Mach-O，禁止 `.app`、DMG 和 pkg，同时要求顶部状态栏图标始终可见。

在 macOS 26 实机上，标准 `NSStatusItem` 能创建、能被 Accessibility 发现，点击后 `NSPopover` 也能正常显示；但 ControlCenter 将非 Bundle 进程识别为 `NOT_A_BUNDLE`，把状态项托管为 `.ephemeral` 且 `neverClip: false`。当系统裁剪该项目时，`isVisible == true` 只代表客户端请求显示，不保证存在可见像素。

验证排除了以下代码原因：

- `setActivationPolicy(.accessory)` 返回成功
- SF Symbol、文字标题、颜色、透明度和按钮尺寸均有效
- 使用真实 `NSApplication.run()`，并在事件循环启动后创建状态项
- `squareLength`、稳定 autosave 名称、重新设置 `isVisible` 和窗口前置均不能覆盖系统裁剪
- 相同行为可在真实 Terminal 启动路径复现，与 TCC 授权无关

AppKit 公开 API不提供状态项优先级或 `neverClip` 控制。

## 决策

继续遵守“无 App Bundle”约束：

- 使用公开的方形 `NSStatusItem`、Template SF Symbol 与 `NSPopover`
- 设置稳定 autosave 名称，保留系统可访问性文本
- 不调用私有行为位，不篡改 ControlCenter，不注入鼠标拖拽
- 不用自绘顶部浮窗伪装系统状态项
- 在 README 和交付说明中明确系统裁剪边界

## 备选方案

### 最小 `.app` Bundle

可提供稳定 LaunchServices 身份，并允许进一步验证非 ephemeral 托管，但直接违反当前硬性约束，因此未实施。

### 私有 `neverClip`/优先级 API

可能改变 ControlCenter 行为，但没有公开契约，存在系统升级失效和安全风险，因此拒绝。

### 自绘菜单栏浮窗

可以制造可见图标，但不是真正的状态项，容易覆盖系统内容并破坏无侵入要求，因此拒绝。

### 备用终端配置入口

可在图标被系统裁剪时保持可操作性，但属于新增产品行为，需要用户明确批准后另行设计。

## 影响

翻译、覆盖层、权限、Keychain 和终端生命周期不受影响。唯一未能在当前系统布局上满足的是“任何情况下都保证状态项有可见像素”；释放菜单栏空间后仍由 macOS 决定其呈现位置。
