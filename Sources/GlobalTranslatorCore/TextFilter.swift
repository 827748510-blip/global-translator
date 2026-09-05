import Foundation

public enum TextFilter {
    private static let traditionalToSimplified = StringTransform(rawValue: "Traditional-Simplified")

    private static let modifierWords: Set<String> = [
        "cmd", "command", "ctrl", "control", "alt", "option", "opt", "shift", "fn", "win", "windows"
    ]

    public static func shouldTranslate(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard !isURL(value), !isEmail(value), !isFilePath(value), !isShortcutOnly(value) else {
            return false
        }
        guard value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        return !isAlreadySimplifiedChinese(value)
    }

    private static func isAlreadySimplifiedChinese(_ value: String) -> Bool {
        let hasCJK = value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        let hasLatin = value.unicodeScalars.contains { scalar in
            (0x0041...0x024F).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
        }
        let hasKana = value.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
        }
        let hasHangul = value.unicodeScalars.contains { scalar in
            (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
        guard hasCJK, !hasLatin, !hasKana, !hasHangul,
              let converted = value.applyingTransform(traditionalToSimplified, reverse: false) else {
            return false
        }
        return converted == value
    }

    private static func isURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://") ||
            lowercased.hasPrefix("https://") ||
            lowercased.hasPrefix("ftp://") ||
            lowercased.hasPrefix("www.") ||
            lowercased.range(of: #"(?i)^(?:[a-z0-9-]+\.)+[a-z]{2,}(?:[/:?#].*)?$"#, options: .regularExpression) != nil
    }

    private static func isEmail(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private static func isFilePath(_ value: String) -> Bool {
        let prefixPath = value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") ||
            value.hasPrefix("../") || value.hasPrefix(".\\") || value.hasPrefix("..\\")
        let scalars = Array(value.unicodeScalars)
        let windowsPath = scalars.count >= 3 && CharacterSet.letters.contains(scalars[0]) && scalars[1] == ":" &&
            (scalars[2] == "/" || scalars[2] == "\\")
        let nestedPath = (value.contains("/") || value.contains("\\")) &&
            value.range(of: #"[/\\][^/\\]+(?:[/\\]|\.[a-z0-9]+$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return prefixPath || windowsPath || nestedPath
    }

    private static func isShortcutOnly(_ value: String) -> Bool {
        let symbols = Set("⌘⌃⌥⇧⇪")
        let compact = value.replacingOccurrences(of: " ", with: "").lowercased()
        if modifierWords.contains(compact) {
            return true
        }
        let symbolScalars = compact.filter { symbols.contains($0) }
        let nonSymbols = compact.filter { !symbols.contains($0) && $0 != "+" && $0 != "-" }
        if !symbolScalars.isEmpty && nonSymbols.count <= 1 {
            return true
        }

        let pieces = compact.split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
        guard pieces.count >= 2, pieces.count <= 5 else { return false }
        guard pieces.dropLast().allSatisfy({ modifierWords.contains($0) }) else { return false }
        let key = pieces[pieces.count - 1]
        return key.range(of: #"(?i)^(?:[a-z0-9]|f[0-9]{1,2}|tab|enter|return|space|escape|esc|delete|backspace)$"#, options: .regularExpression) != nil
    }
}
