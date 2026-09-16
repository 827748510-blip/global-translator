import Foundation

/// User-configurable global hotkey stored in `config.json`. Booleans are used
/// instead of Carbon bitmasks so the file stays readable and platform-neutral.
public struct KeyboardShortcutSpec: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(
        keyCode: UInt16,
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false
    ) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// Control+Shift+T. Avoids macOS region-screenshot ⌘⇧4 and Chrome's ⌘⇧T.
    public static let screenshotTranslateDefault = KeyboardShortcutSpec(
        keyCode: KeyCode.t,
        control: true,
        shift: true
    )

    /// Carbon `RegisterEventHotKey` modifier mask.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if command { mask |= CarbonModifier.command }
        if shift { mask |= CarbonModifier.shift }
        if option { mask |= CarbonModifier.option }
        if control { mask |= CarbonModifier.control }
        return mask
    }

    public var hasPrimaryModifier: Bool {
        control || option || command
    }

    /// Shift-only or unmodified keys are rejected so typing is not captured.
    public var isValid: Bool {
        guard hasPrimaryModifier else { return false }
        guard keyCode != KeyCode.escape else { return false }
        return true
    }

    public var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    /// Warning for a spec that Carbon may accept but the OS or this app eats.
    public var conflictWarning: String? {
        if command, shift, !control, !option, KeyCode.systemScreenshotKeys.contains(keyCode) {
            return KeyboardShortcutSupport.systemScreenshotConflictCopy
        }
        if command, !shift, !control, !option, keyCode == KeyCode.q {
            return KeyboardShortcutSupport.quitConflictCopy
        }
        return nil
    }

    public enum KeyCode {
        public static let a: UInt16 = 0
        public static let s: UInt16 = 1
        public static let d: UInt16 = 2
        public static let f: UInt16 = 3
        public static let h: UInt16 = 4
        public static let g: UInt16 = 5
        public static let z: UInt16 = 6
        public static let x: UInt16 = 7
        public static let c: UInt16 = 8
        public static let v: UInt16 = 9
        public static let b: UInt16 = 11
        public static let q: UInt16 = 12
        public static let w: UInt16 = 13
        public static let e: UInt16 = 14
        public static let r: UInt16 = 15
        public static let y: UInt16 = 16
        public static let t: UInt16 = 17
        public static let one: UInt16 = 18
        public static let two: UInt16 = 19
        public static let three: UInt16 = 20
        public static let four: UInt16 = 21
        public static let six: UInt16 = 22
        public static let five: UInt16 = 23
        public static let nine: UInt16 = 25
        public static let seven: UInt16 = 26
        public static let eight: UInt16 = 28
        public static let zero: UInt16 = 29
        public static let o: UInt16 = 31
        public static let u: UInt16 = 32
        public static let i: UInt16 = 34
        public static let p: UInt16 = 35
        public static let returnKey: UInt16 = 36
        public static let l: UInt16 = 37
        public static let j: UInt16 = 38
        public static let k: UInt16 = 40
        public static let n: UInt16 = 45
        public static let m: UInt16 = 46
        public static let tab: UInt16 = 48
        public static let space: UInt16 = 49
        public static let delete: UInt16 = 51
        public static let escape: UInt16 = 53
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126

        public static let systemScreenshotKeys: Set<UInt16> = [three, four, five]
    }

    public enum CarbonModifier {
        public static let command: UInt32 = 256
        public static let shift: UInt32 = 512
        public static let option: UInt32 = 2_048
        public static let control: UInt32 = 4_096
    }

    public static func keyName(for keyCode: UInt16) -> String {
        if let name = namedKeys[keyCode] { return name }
        return "Key\(keyCode)"
    }

    private static let namedKeys: [UInt16: String] = [
        KeyCode.a: "A", KeyCode.s: "S", KeyCode.d: "D", KeyCode.f: "F",
        KeyCode.h: "H", KeyCode.g: "G", KeyCode.z: "Z", KeyCode.x: "X",
        KeyCode.c: "C", KeyCode.v: "V", KeyCode.b: "B", KeyCode.q: "Q",
        KeyCode.w: "W", KeyCode.e: "E", KeyCode.r: "R", KeyCode.y: "Y",
        KeyCode.t: "T", KeyCode.one: "1", KeyCode.two: "2", KeyCode.three: "3",
        KeyCode.four: "4", KeyCode.six: "6", KeyCode.five: "5", KeyCode.nine: "9",
        KeyCode.seven: "7", KeyCode.eight: "8", KeyCode.zero: "0",
        KeyCode.o: "O", KeyCode.u: "U", KeyCode.i: "I", KeyCode.p: "P",
        KeyCode.l: "L", KeyCode.j: "J", KeyCode.k: "K", KeyCode.n: "N",
        KeyCode.m: "M", KeyCode.returnKey: "↩", KeyCode.tab: "⇥",
        KeyCode.space: "空格", KeyCode.delete: "⌫", KeyCode.escape: "Esc",
        KeyCode.leftArrow: "←", KeyCode.rightArrow: "→",
        KeyCode.downArrow: "↓", KeyCode.upArrow: "↑"
    ]
}

public enum KeyboardShortcutSupport {
    public static let invalidCopy = "请使用带 ⌃ / ⌥ / ⌘ 的组合，例如 ⌃⇧T"
    public static let alreadyInUseCopy = "该快捷键已被占用，请改用其他组合"
    public static let registrationFailedCopy = "快捷键注册失败，请改用其他组合"
    public static let systemScreenshotConflictCopy = "该组合与系统截图快捷键冲突，可能无法生效"
    public static let quitConflictCopy = "该组合与退出应用快捷键冲突"
    public static let recordingPromptCopy = "按下新快捷键…"
}

public enum HotkeyRegistrationError: Error, Equatable, Sendable {
    case alreadyInUse
    case invalid
    case failed

    public var userMessage: String {
        switch self {
        case .alreadyInUse:
            return KeyboardShortcutSupport.alreadyInUseCopy
        case .invalid:
            return KeyboardShortcutSupport.invalidCopy
        case .failed:
            return KeyboardShortcutSupport.registrationFailedCopy
        }
    }
}
