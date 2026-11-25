# Global Translator — UI, Overlay & Extension Design Specification

## 0. Context & Goals

Global Translator is an operational, privacy-conscious macOS utility paired with a Chrome Bridge extension (`Global Translator Bridge`). The desktop product ships as a signed/ad-hoc `.app` bundle (`Global Translator.app`) with a menu-bar status item, borderless Liquid Glass popovers, click-through window translation overlays, and a full-screen region capture overlay.

Design intent: quiet Apple-system craft — crisp hierarchy, scannable controls, zero decorative clutter. Users open the menu-bar popover to check status, toggle a mode, or configure a backend in seconds without fighting a long scrolling form.

- `DESIGN_VARIANCE`: 3 — one restrained native system + unified extension palette.
- `MOTION_INTENSITY`: 2 — crisp `ease-out` micro-interactions and popover fades; high-frequency shortcuts/overlays stay `0ms` instantaneous; full `Reduce Motion` compliance.
- `VISUAL_DENSITY`: 6 — compact `4px` spacing grid with generous interactive hit targets and full Dynamic Type scaling.

## 1. Visual Authority (Single Source of Truth)

### macOS Desktop Surface
- **Outer Shell (Single-Layer Liquid Glass):** Menu-bar settings (`DropdownPanel`) and floating selection/screenshot popovers (`SelectionTranslatePanel`) use **one** outer layer of macOS 27 `.glassEffect(.regular, in:)` (no `.interactive()` on static container shells).
- **Inner Cards (Tonal Surfaces, Never Nested Glass):** Cards inside the settings panel (`GTSettingsCard`) use `GTColor.cardSurface` (`controlBackgroundColor.opacity(0.72)`) with a `1pt` `GTColor.hairline` (`separatorColor`) border. Nesting `.glassEffect` inside `.glassEffect` is strictly forbidden.
- **Button Hierarchy:**
  - Primary CTA (Save API Key, Test Connection when unvalidated, Banner "去配置/去授权", Copy / Open Settings on selection popovers): `.borderedProminent` or `GTColor.accent` fill with `GTColor.selectedSegmentText`.
  - Secondary Actions (Cancel, Replace, Apply, Refresh, Choose Apps, Clear Cache, Logs, Record): `.bordered` or `GTColor.cardSurface` with `GTColor.hairline`.
  - Destructive Actions (Delete Key, Quit App): explicit `role: .destructive` with `GTColor.destructive`.
- **Click-Through Translation Patches (`OverlayView`):** Solid `GTColor.overlaySolidFallback` (`GTPanelBackground`) — never translucent material — so original window text underneath never bleeds through.

### Chrome Extension Surface (`extension/`)
- Aligns with the desktop palette via CSS custom properties (`--bg`, `--surface`, `--border`, `--text-primary`, `--text-secondary`, `--accent`, `--ok`, `--warn`, `--bad`) with `color-scheme: light dark` and `@media (prefers-color-scheme: dark)`.
- Body copy `>= 13px`, secondary captions `>= 12px`, interactive controls `min-height: 30px`, explicit `:focus-visible` ring, and `aria-live` / `role="status"` / `role="alert"` announcements.

## 2. Information Architecture (3-Tab Menu-Bar Settings)

To eliminate long-form cognitive overload (`360pt` width), `SettingsPopoverView` organizes controls into:
1. **Pinned Header & Setup Banner:** Live `MenuBarStatus` icon + text, automatic translation master switch, contextual setup banner when backend or permissions block activation, and a 3-segment `SettingsTab` bar:
   - **翻译 (`translation`):** 滑词翻译 (plus inline Accessibility warning if missing), 优化场景 segmented picker + explanation, 视频翻译, 要翻译的应用 allow-list (with "添加当前" & "选择应用…"), and 截图翻译 (hotkey recorder, auto-copy/save/copy-image toggles with clipboard precedence note).
   - **后端 (`backend`):** 翻译后端 switcher (DeepSeek 云端 / 本地服务), explicit bidirectional target language note, Keychain-isolated API key entry (Enter submits, never prefilled), native menu `Picker` for models, connection test, and collapsible `DeepSeekStatsSection` (`DisclosureGroup`).
   - **高级 (`advanced`):** 系统权限 (`辅助功能` & `屏幕录制` with clear per-permission purpose and uniquely labeled action buttons), 维护与诊断 (`清除缓存`, `打开日志`), and 关于与开源 (`Global Translator` version, `maodashu` author attribution, `MIT`, and a persistent `GitHub Star` entry).
2. **Pinned Footer & Star Guidance Banner:** A dismissible warm-tinted GitHub Star guidance banner above the footer (persisted via `githubStarPromptDismissed`) plus the pinned footer showing `Global Translator · by maodashu` (or transient `actionFeedbackMessage`) and destructive `退出应用` (`⌘Q`).
3. **Dynamic Sizing & Scrollbars:** `.scrollIndicators(.automatic)` with `onGeometryChange` keeping panel height fitted to the active tab up to the screen's `visibleFrame`.

## 3. Design Tokens (`DesignTokens.swift`)

- **Spacing (`4px` grid):** `xxSmall 4`, `xSmall 8`, `small 12`, `medium 16`, `large 20`, `xLarge 24`.
- **Radii:** `row 6`, `card 10`, `overlay 8` (selection/screenshot popovers), `GTOverlayMetrics.patchCornerRadius 4` (click-through patches).
- **Type Scale (Dynamic Type safe):** `stateLine (.headline)`, `cardTitle / sectionTitle (.subheadline.weight(.semibold))`, `body (.body)`, `secondary (.footnote)`, `caption (.caption)`, `overlay (.callout)`. Controls use `minHeight` rather than rigid clipping heights.
- **Colors:** System semantic colors only (`GTColor`), including `separatorColor` for hairlines and `alternateSelectedControlTextColor` for text on `Color.accentColor`.

## 4. Motion & Responsiveness

- **0ms Instant Surfaces:** Click-through overlay patches (`OverlayPanel`), region capture overlay (`RegionSelectionPanel`), and selection popovers (`SelectionTranslatePanel`) keep `animationBehavior = .none`.
- **Menu-Bar Dropdown (`DropdownPanel`):** Anchored cleanly at top-left without animating window `height`. Enter uses a `160ms` `cubic-bezier(0.23, 1, 0.32, 1)` (`ease-out`) opacity fade; dismiss uses a `120ms` interruptible `ease-out` fade guarded by `presentationGeneration`.
- **Controls:** Segmented picker active pill animates with `matchedGeometryEffect` (`180ms ease-out`); popover action buttons use `120ms` hover and `scaleEffect(0.97)` press feedback.
- **Extension Video Overlay:** Uses `ResizeObserver`, `passive` `scroll`/`resize` listeners batched with `requestAnimationFrame`, and GPU `transform: translate3d(...)`, dynamically clearing bottom player controls without fixed `56px` clipping.

## 5. Accessibility & Privacy Commitments

- **Keyboard & Focus:** `DropdownPanel`, `SelectionTranslatePanel`, and `RegionSelectionPanel` all support `Esc` (`cancelOperation`) dismissal; `RegionSelectionPanel` becomes key so `Esc` works even without Accessibility permission. Recording a screenshot shortcut cleans up deterministically when the popover closes. Selection popovers support `⌘C` and `⌘1/2/3`.
- **Assistive Settings:** `accessibilityReduceTransparency` falls back from Liquid Glass to solid `GTColor.panelBackground` / `GTColor.sectionFill`; `accessibilityReduceMotion` / `prefers-reduced-motion` suppresses movement and window fade animations.
- **VoiceOver & Screen Readers:** All icons/buttons carry distinct Chinese labels; developer layout notes are never exposed in accessibility labels; extension popups and subtitle overlays expose `role="status"`, `aria-live="polite"`, and `role="alert"`.
- **Privacy:** Keychain credentials are never echoed or prefilled; `UISafeError` maps backend failures to fixed safe Chinese copy; `Info.plist` accurately discloses local screenshot capture, window translation, and local audio transcription purposes.
