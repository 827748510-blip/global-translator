import Foundation
import NaturalLanguage

public enum TextFilter {
    private static let traditionalToSimplified = StringTransform(rawValue: "Traditional-Simplified")

    private static let modifierWords: Set<String> = [
        "cmd", "command", "ctrl", "control", "alt", "option", "opt", "shift", "fn", "win", "windows"
    ]
    private static let technicalAbbreviations: Set<String> = [
        "AI", "API", "CPU", "GPU", "USB", "HTTP", "HTTPS", "JSON", "HTML", "CSS", "PDF",
        "PNG", "JPG", "JPEG", "URL", "IP", "DNS", "RAM", "SSD", "SDK", "CLI", "SQL", "UTF"
    ]

    public static func shouldTranslate(_ text: String) -> Bool {
        switch selectionDecision(text) {
        case .translate:
            return true
        case .skip, .alreadyTargetLanguage, .noTranslationNeeded:
            return false
        }
    }

    /// Overlay/bridge keep using `shouldTranslate`. Selection UX distinguishes
    /// “already Simplified Chinese” (skip auto-translate, still offer 优化提示词)
    /// from identifiers/URLs that must not spawn a popover.
    public static func shouldOfferSelectionPopover(
        _ text: String,
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage
    ) -> Bool {
        selectionDecision(text, targetLanguage: targetLanguage) != .skip
    }

    public static func shouldAutoTranslateSelection(
        _ text: String,
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage
    ) -> Bool {
        selectionDecision(text, targetLanguage: targetLanguage) == .translate
    }

    public static func shouldOfferPromptOptimization(
        _ text: String,
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage
    ) -> Bool {
        selectionDecision(text, targetLanguage: targetLanguage) != .skip
    }

    public static func selectionDecision(
        _ text: String,
        targetLanguage: String = SelectionTranslateSupport.defaultTargetLanguage
    ) -> SelectionTranslationDecision {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .skip }
        guard !isURL(value), !isEmail(value), !isFilePath(value), !isShortcutOnly(value), !isIdentifierOrUnit(value) else {
            return .skip
        }
        guard value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return .skip
        }
        if SelectionTranslateSupport.isChineseTarget(targetLanguage), isAlreadySimplifiedChinese(value) {
            return .alreadyTargetLanguage
        }
        if isTechnicalTokenPhrase(value) {
            return .noTranslationNeeded
        }
        return .translate
    }

    private static let glueWords: Set<String> = [
        "and", "or", "with", "for", "to", "of", "in", "on", "vs", "versus", "plus"
    ]

    /// Product names with a *real* strong signal: internal CamelCase
    /// (SwiftUI, ScreenCaptureKit, NSView), or an ALL-CAPS abbrev plus another
    /// tech token (Vision + OCR). Title-case + a number (`Sentence 0`) and
    /// UI labels (`File / Edit`, `Copy + Paste`) still translate. `+`/`/`
    /// joiners are not a strong signal by themselves.
    private static func isTechnicalTokenPhrase(_ value: String) -> Bool {
        if value.contains(where: { $0 == "?" || $0 == "!" || $0 == "。" || $0 == "？" }) {
            return false
        }
        let hasCJK = value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
        guard !hasCJK else { return false }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "+/|&,"))
        let tokens = value.components(separatedBy: separators).filter { !$0.isEmpty }
        guard (2...8).contains(tokens.count) else { return false }
        guard tokens.allSatisfy({ isTechnicalToken($0) || glueWords.contains($0.lowercased()) }) else {
            return false
        }
        if tokens.contains(where: hasInternalCamelCase) {
            return true
        }
        let hasAllCaps = tokens.contains { isAllCapsAbbreviation($0) }
        let hasPeerName = tokens.contains { token in
            !isVersionToken(token)
                && !isAllCapsAbbreviation(token)
                && (hasInternalCamelCase(token) || isCapitalizedProductWord(token) || isIdentifierOrUnit(token))
        }
        return hasAllCaps && hasPeerName
    }

    private static func isTechnicalToken(_ token: String) -> Bool {
        isVersionToken(token)
            || hasInternalCamelCase(token)
            || isIdentifierOrUnit(token)
            || isAllCapsAbbreviation(token)
            || technicalAbbreviations.contains(token.uppercased())
            || isCapitalizedProductWord(token)
    }

    private static func isVersionToken(_ token: String) -> Bool {
        token.range(of: #"^v?\d+(?:\.\d+)*[A-Za-z]?$"#, options: .regularExpression) != nil
    }

    private static func isCapitalizedProductWord(_ token: String) -> Bool {
        token.range(of: #"^[A-Z][a-zA-Z0-9]*$"#, options: .regularExpression) != nil
    }

    private static func isAllCapsAbbreviation(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard (2...8).contains(letters.count), letters.allSatisfy(\.isUppercase) else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func hasInternalCamelCase(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        let upperCount = letters.filter(\.isUppercase).count
        let hasLower = letters.contains(where: \.isLowercase)
        return hasLower && upperCount >= 2
    }

    private static func isAlreadySimplifiedChinese(_ value: String) -> Bool {
        let hasCJK = value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        let foreignLetters = value.unicodeScalars.filter { scalar in
            CharacterSet.letters.contains(scalar) &&
                !(0x3400...0x4DBF).contains(scalar.value) && !(0x4E00...0x9FFF).contains(scalar.value)
        }
        let hasKana = value.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
        }
        let hasHangul = value.unicodeScalars.contains { scalar in
            (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
        }
        guard hasCJK, !hasKana, !hasHangul,
              let converted = value.applyingTransform(traditionalToSimplified, reverse: false) else {
            return false
        }
        guard converted == value else { return false }
        guard !foreignLetters.isEmpty else { return true }
        if foreignLetters.allSatisfy(\.isASCII) {
            let words = value.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").inverted)
                .filter { $0.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) }
            if !words.isEmpty, words.allSatisfy({ technicalAbbreviations.contains($0.uppercased()) }) { return true }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(value)
        return recognizer.dominantLanguage == .simplifiedChinese
    }

    private static func isURL(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace) else { return false }
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
        let nestedPath = !value.contains(where: \.isWhitespace) && (value.contains("/") || value.contains("\\")) &&
            value.range(of: #"[/\\][^/\\]+(?:[/\\]|\.[a-z0-9]+$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return prefixPath || windowsPath || nestedPath
    }

    private static func isIdentifierOrUnit(_ value: String) -> Bool {
        if value.count == 1, value.unicodeScalars.allSatisfy({ $0.isASCII }) { return true }
        let patterns = [
            #"^\.[A-Za-z][A-Za-z0-9_.-]*$"#,
            #"^[A-Za-z_][A-Za-z0-9_]*_[A-Za-z0-9_]+$"#,
            #"^[a-z]+(?:[A-Z][A-Za-z0-9]*)+$"#,
            #"^[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+$"#,
            #"(?i)^\.?[A-Za-z0-9_.-]+\.(?:swift|tsx?|jsx?|json|ya?ml|toml|md|plist|lock|sh|css|html)(?:\s+[AMUDR?]|\s+\d+)?$"#,
            #"(?i)^0x[0-9a-f]+$"#,
            #"(?i)^v?\d+(?:\.\d+){2,}(?:[-+][a-z0-9.-]+)?$"#,
            #"(?i)^\d+(?:\.\d+)?\s*(?:[kmgt]i?b|bytes?|fps|hz|khz|mhz|ghz|px|dpi|ms|s|sec|min|%)$"#,
            #"(?i)^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#,
            #"^[A-Za-z_][A-Za-z0-9_.]*\(\)$"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
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
