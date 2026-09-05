# Global Translator — Menu-Bar UI & Translation Overlay Design

## 0. Context & Goals

Global Translator is an operational, privacy-conscious macOS menu-bar utility. It watches the
active window, translates on-screen text into 简体中文, and renders the result on click-through
overlay panels. The final executable is a terminal-launched Mach-O: no `.app` bundle, no Dock
icon, no DMG. The UI therefore lives entirely in the status bar and in borderless floating
panels.

Design intent: Apple-system language — quiet, compact, clear state. The user should be able to
glance at the menu bar and know exactly what the tool is doing, open the popover and change one
thing, then leave. Nothing decorative, nothing that competes with the translated content it
overlays.

- DESIGN_VARIANCE: 3 — one strong, restrained system; no alternate themes.
- MOTION_INTENSITY: 2 — state changes only; standard popover/system motion; no decorative animation.
- VISUAL_DENSITY: 6 — compact utility spacing on a strict 4px grid; generous hit targets preserved.

## 1. Research Log

Shortlist of native macOS utility references:

- **Apple system UI** (System Settings, Control Center, menu-bar status items such as Wi-Fi,
  Battery, Focus): the authoritative source for semantic materials, SF Symbols, segmented
  pickers, permission rows, and destructive-action labeling. Chosen as the primary reference.
- **Raycast**: excellent command-driven utility, but its UI is a custom dark command palette
  with heavy branding; its look is deliberately *not* stock AppKit, so it informs workflow
  (fast keyboard reach, clear state) rather than visuals.
- **Ollama / native menu-bar utilities**: validate the pattern of a transient NSPopover from an
  NSStatusItem with a small preference surface and a clear running state.

Decision: follow **Apple system UI** for taste and construction. Raycast and Ollama-class
utilities confirm the interaction model (status item → transient popover → system settings
deep links) but not the surface treatment.

The provided screenshot reference is contextual evidence for a **monochrome macOS menu bar
only** — it confirms the template-rendering, single-color symbol idiom for the status item.
It is explicitly *not* a pixel target for the popover.

Because this target is native SwiftUI/AppKit, web-oriented references (lazyweb-style landing
pages, Imagen-generated art direction) are inappropriate: there is no web surface, no marketing
page, and no custom artwork. Material, color, type, and motion all come from the system.

## 2. Design Principles

1. **State is textual.** Every state the tool can be in is named in words (menu-bar tooltip /
   accessibility label, popover header). Color and symbols are reinforcement, never the carrier.
2. **Privacy is visible.** Key entry never echoes or prefills; the vision fallback states
   plainly that a cropped screenshot is uploaded to DeepSeek before it can be enabled;
   permissions show their real status.
3. **System first.** Semantic colors, system materials, SF Symbols, SF Pro via system text
   styles. No raw hex, no custom art, no emojis, no gradients.
4. **Compact but touchable.** 4px spacing grid, small system type, minimum practical 44pt
   vertical hit areas on interactive rows, full keyboard and VoiceOver operability.
5. **The overlay is a guest.** Click-through, nonactivating, never shadowed or keyed; it sits
   below menu/status chrome, vanishes instantly on demand, and never shows stale text.

## 3. Design Tokens (system semantic mappings)

All tokens resolve to system semantics in `DesignTokens.swift`; no raw values.

- **Spacing (4px grid):** `xxSmall 4`, `xSmall 8`, `small 12`, `medium 16`, `large 20`,
  `xLarge 24`.
- **Corner radius:** `row 6` (small controls), `card 10` (grouped sections), `overlay 8`.
- **Color:** `Color.primary` / `Color.secondary` for text hierarchy; `Color.accentColor` for
  the single primary action; `Color(nsColor: .systemRed)` reserved for destructive labels and
  error text; `Color(nsColor: .controlBackgroundColor)` for filled section backgrounds.
- **Material / tonal depth:** popover uses `NSVisualEffectView` (`.popover` material, system
  provided by NSPopover); overlay uses `.regularMaterial` over `.thinMaterial` vibrancy with a
  **solid fallback** (`NSColor.windowBackgroundColor`) when Reduce Transparency is on.
- **Status tokens:** state → SF Symbol + text mapping is centralized (`MenuBarStatus`), so the
  status item, popover header, and VoiceOver always agree.

## 4. Type Scale (SF Pro via system styles)

- Overlay translation text: `.callout` weight regular — readable at glance, caps at 3 lines.
- Popover header state line: `.headline`.
- Section titles: `.subheadline` semibold.
- Body/rows: `.body`.
- Secondary/explanatory text: `.footnote` and `.caption` (permission hints, health messages).
- All styles are dynamic system styles: Dynamic Type and system font scaling work unchanged;
  Chinese text uses the system fallback chain (PingFang SC) with line limits that never clip.

## 5. Component States

Every interactive element defines: **default, hover (where applicable), focused (keyboard ring),
disabled (real `disabled`, with a textual reason nearby), loading (spinner + label, control
disabled), error (red text plus preserved input), empty (textual, e.g. "未添加排除应用",
"未获取模型列表").**

- Secure key field: empty draft → Save disabled; configured → "已配置 · 不显示" status text,
  Replace flow, Delete requires confirmation; failure keeps the draft and shows the message.
- Connection test: idle → testing (progress) → healthy (message text) / failed (error text).
- Permission rows: granted → "已授权"; missing → "未授权" + buttons (授权 / 打开系统设置).
- Buttons: primary uses `.borderedProminent` sparingly (Save); others `.bordered`; destructive
  (Quit, Clear Cache, Delete Key) are labeled in words, with confirmation where lossy.

## 6. Depth & Motion

- Depth is tonal/material only: popover material (system), section fills, overlay material.
  No shadows on overlay panels (shadow disabled), no custom elevation effects.
- Motion (intensity 2): NSPopover's own transient appearance only. Overlay panels appear,
  update, and vanish **instantaneously** — `animationBehavior = .none`, no custom fade is
  implemented (the earlier cross-fade idea was dropped; Reduce Motion handling is therefore
  moot for overlays). No looping or decorative animation anywhere.

## 7. Accessibility

- Status item: template SF Symbol plus textual accessibility label/help per state
  ("翻译中", "已暂停", "正在监听", "需要授权 / 出错"); state is never color-only.
- Popover: full keyboard traversal, every control labeled and hinted in Chinese; rows expose
  value text (permission status read as words); hit areas ≥ 44pt where practical.
- Overlay: `ignoresMouseEvents`, nonactivating, excluded from the window cycle; it is visual
  output only and never steals focus from the user's real work.
- Reduced Transparency → solid overlay background; overlays have no fade at all (Reduce
  Motion is system-managed for the popover only). Dynamic Type respected throughout via
  system text styles.

## 8. Personas & Runtime QA

Personas:

1. **Privacy-conscious reader** — wants to know exactly when screenshots leave the machine;
   needs consent text, key secrecy (never shown), visible permission state, and an obvious
   Quit. Served by: consent dialog wording, SecureField discipline, permission rows.
2. **Low-vision user** — relies on Dynamic Type, VoiceOver labels, reduced transparency/motion
   fallbacks, and state-in-words. Served by system text styles and the textual status mapping.
3. **Keyboard-first operator** — opens the popover, tabs through every control, toggles
   translation, saves a key, quits — no mouse. Served by full focus support and standard
   keyboard shortcuts on all buttons.

Runtime QA outcome:

1. **Overlay text measurement.** Default-size CJK text was verified on a live overlay. Extreme
   Dynamic Type sizes still use the conservative NSFont estimator and remain residual debt.
2. **Panel policy verification.** A real local-model flow produced click-through,
   nonactivating panels adjacent to browser text; stale panels were removed on revision change.
3. **Enablement gate reasons.** The OFF→ON refusal reason is visible below the header state in
   both light and dark appearances.
4. **Bare-executable status item.** macOS may clip the ControlCenter-hosted ephemeral item even
   when `NSStatusItem.isVisible` is true. Public AppKit has no never-clip override; see ADR-001.
