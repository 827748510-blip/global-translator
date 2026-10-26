import Foundation

/// A language recognized by the lightweight 划词 code detector. This is a
/// hint for the model, not a parser: the explanation path must still tolerate
/// ambiguous or fragmentary snippets.
public enum CodeSnippetLanguage: String, CaseIterable, Equatable, Sendable {
    case javaScript = "JavaScript"
    case typeScript = "TypeScript"
    case python = "Python"
    case java = "Java"
    case kotlin = "Kotlin"
    case swift = "Swift"
    case c = "C"
    case cpp = "C++"
    case cSharp = "C#"
    case go = "Go"
    case rust = "Rust"
    case php = "PHP"
    case ruby = "Ruby"
    case shell = "Shell"
    case sql = "SQL"
    case generic = "代码"

    public var displayName: String { rawValue }
}

public struct CodeSnippetDetection: Equatable, Sendable {
    public let language: CodeSnippetLanguage

    public init(language: CodeSnippetLanguage) {
        self.language = language
    }
}

/// Heuristic detector for text selected in any app. It intentionally combines
/// strong language signatures (declarations, imports, known APIs) with a
/// conservative generic fallback. A miss only means the normal prose
/// translation path runs; a false positive would explain a sentence as code,
/// so pure keywords alone never qualify.
public enum CodeSnippetDetector {
    public static func isCode(_ text: String) -> Bool {
        detect(text) != nil
    }

    public static func detect(_ text: String) -> CodeSnippetDetection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              value.utf8.count <= 128_000,
              value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
        else { return nil }
        let scan = value.count > scanCharacterLimit ? String(value.prefix(scanCharacterLimit)) : value

        for rule in rules where rule.patterns.contains(where: {
            matches($0, in: scan, caseSensitive: rule.caseSensitive)
        }) {
            return CodeSnippetDetection(language: rule.language)
        }
        guard hasGenericCodeStructure(scan) else { return nil }
        return CodeSnippetDetection(language: languageByKeyword(in: scan) ?? .generic)
    }

    /// A selection over the 48k hard cap would otherwise run every regex many
    /// times on the main actor. Syntax that decides the language is expected
    /// near the beginning of a snippet; the model still receives every chunk.
    private static let scanCharacterLimit = 8_000

    private struct LanguageRule: Sendable {
        let language: CodeSnippetLanguage
        let patterns: [String]
        let keywords: Set<String>
        let caseSensitive: Bool

        init(
            _ language: CodeSnippetLanguage,
            patterns: [String],
            keywords: [String],
            caseSensitive: Bool = false
        ) {
            self.language = language
            self.patterns = patterns
            self.keywords = Set(keywords)
            self.caseSensitive = caseSensitive
        }
    }

    private static let rules: [LanguageRule] = [
        LanguageRule(.javaScript, patterns: [
            #"(?m)^\s*(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*="#,
            #"(?m)^\s*(?:export\s+)?(?:async\s+)?function\s+[A-Za-z_$][\w$]*\s*\("#,
            #"\bconsole\.(?:log|error|warn|info|debug)\s*\("#,
            #"(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>\s*[{(]?"#,
            #"\bdocument\.(?:querySelector|getElementById|addEventListener)\s*\("#
        ], keywords: [
            "const", "let", "var", "function", "return", "async", "await", "console",
            "document", "window", "export", "import", "default", "new", "this", "typeof"
        ]),
        LanguageRule(.typeScript, patterns: [
            #"(?m)^\s*(?:export\s+)?(?:declare\s+)?interface\s+[A-Za-z_]\w*(?:\s+extends\s+[^{]+)?\s*\{"#,
            #"(?m)^\s*(?:export\s+)?type\s+[A-Z]\w*(?:<[^>]+>)?\s*="#,
            #"(?m)^\s*(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*:\s*(?:string|number|boolean|unknown|any|void|never)\b"#,
            #"(?m)^\s*(?:export\s+)?(?:async\s+)?function\s+\w+\s*\([^)]*\)\s*:\s*[A-Za-z_]\w*"#
        ], keywords: [
            "interface", "type", "string", "number", "boolean", "unknown", "any", "void",
            "never", "readonly", "enum", "implements"
        ]),
        LanguageRule(.python, patterns: [
            #"(?m)^\s*(?:async\s+)?def\s+[A-Za-z_]\w*\s*\([^)]*\)\s*(?:->\s*[^:\n]+)?:"#,
            #"(?m)^\s*from\s+[A-Za-z_][\w.]*\s+import\s+"#,
            #"(?m)^\s*import\s+[A-Za-z_][\w.]*\s*(?:as\s+\w+)?\s*$"#,
            #"(?m)^\s*elif\b[^\n]*(?:==|!=|>=|<=|>|<|\bin\b|\bnot\b|\bis\b|\(|\))\s*:\s*$"#,
            #"(?m)^\s*if\b[^\n]*(?:==|!=|>=|<=|>|<|\bin\b|\bnot\b|\bis\b|\(|\))\s*:\s*$"#,
            #"(?m)^\s*while\b[^\n]*(?:==|!=|>=|<=|>|<|\bin\b|\bnot\b|\bis\b|\(|\))\s*:\s*$"#,
            #"(?m)^\s*for\s+\w+\s+in\s+[^\n]+:\s*$"#,
            #"(?m)^\s*(?:try|else|finally)\s*:\s*$"#,
            #"(?m)^\s*except(?:\s+[A-Z_]\w*(?:\s+as\s+\w+)?)?\s*:\s*$"#,
            #"(?m)^\s*with\b[^\n]*(?:\(|\bas\b)[^\n]*:\s*$"#,
            #"(?m)^\s*print\s*\("#,
        ], keywords: [
            "def", "elif", "except", "finally", "lambda", "yield", "pass", "raise",
            "import", "from", "as", "with", "None", "True", "False", "self", "print"
        ]),
        LanguageRule(.java, patterns: [
            #"\b(?:public|private|protected)\s+(?:static\s+)?(?:final\s+)?(?:void|int|long|double|float|boolean|char|String|[A-Z]\w*(?:<[^>]+>)?)\s+\w+\s*\("#,
            #"\bSystem\.out\.print(?:ln|f)?\s*\("#,
            #"\bimport\s+java(?:x)?\."#,
            #"\bpublic\s+(?:final\s+)?(?:class|interface|enum)\s+\w+"#,
            #"\bnew\s+(?:ArrayList|HashMap|HashSet|StringBuilder|Thread)\s*[<(]"#
        ], keywords: [
            "public", "private", "protected", "static", "final", "class", "interface",
            "extends", "implements", "void", "String", "System", "new", "package", "throws"
        ]),
        LanguageRule(.go, patterns: [
            #"(?m)^\s*package\s+[a-z_]\w*\s*$"#,
            #"(?m)^\s*func\s+(?:\([^)]*\)\s*)?\w+\s*\([^)]*\w+\s+(?:string|int|int64|uint|error|bool|byte|rune|\[\]|map\[)"#,
            #"\bfmt\.(?:Print|Printf|Println|Errorf)\s*\("#,
            #"\b(?:if|for)\b[^\n]*\{\s*$"#
        ], keywords: [
            "package", "func", "import", "defer", "goroutine", "chan", "select",
            "fmt", "range", "nil", "var", "const", "go", "struct", "type"
        ]),
        LanguageRule(.kotlin, patterns: [
            #"(?m)^\s*(?:(?:public|private|internal|protected|suspend|override)\s+)*fun\s+\w+\s*\("#,
            #"(?m)^\s*(?:val|var)\s+\w+\s*:\s*[A-Za-z_]\w*"#,
            #"(?m)^\s*println\s*\("#,
            #"(?m)^\s*data\s+class\s+\w+"#
        ], keywords: [
            "fun", "val", "var", "data", "sealed", "companion", "object", "when",
            "suspend", "override", "internal", "lateinit", "println"
        ]),
        LanguageRule(.swift, patterns: [
            #"(?m)^\s*(?:@\w+\s+)?(?:(?:public|private|internal|fileprivate|open)\s+)?func\s+\w+\s*(?:<[^>]+>)?\s*\("#,
            #"(?m)^\s*(?:guard|if)\s+let\s+\w+\s*(?:=|,|\belse\b)"#,
            #"(?m)^\s*(?:let|var)\s+[A-Za-z_]\w*\s*:\s*[\[A-Z][\w<>, \[\].?:]*"#,
            #"(?m)^\s*import\s+(?:SwiftUI|Foundation|AppKit|UIKit)\s*$"#,
            #"\b(?:struct|class|enum|protocol)\s+\w+\s*:\s*[A-Z]\w+"#
        ], keywords: [
            "func", "guard", "let", "var", "struct", "enum", "protocol", "extension",
            "import", "self", "nil", "throws", "async", "await", "some", "any"
        ]),
        LanguageRule(.c, patterns: [
            #"(?m)^\s*#\s*include\s*<(?!iostream>|vector>|string>|memory>|algorithm>)[^>]+>"#,
            #"(?m)^\s*#\s*define\s+\w+"#,
            #"\b(?:int|void|char|double|float|long|size_t)\s+\w+\s*\([^;{}]*\)\s*\{"#
        ], keywords: [
            "include", "define", "int", "void", "char", "double", "float", "long",
            "struct", "sizeof", "printf", "malloc", "free"
        ]),
        LanguageRule(.cpp, patterns: [
            #"(?m)^\s*#\s*include\s*<(?:iostream|vector|string|memory|algorithm)>"#,
            #"\bstd::\w+"#,
            #"\b(?:cout|cin|cerr)\s*(?:<<|>>)"#,
            #"(?m)^\s*(?:template\s*<[^>]+>|namespace\s+\w+)\s*$"#
        ], keywords: [
            "include", "std", "cout", "cin", "cerr", "namespace", "template", "class",
            "public", "private", "vector", "string", "auto", "nullptr"
        ]),
        LanguageRule(.cSharp, patterns: [
            #"(?m)^\s*using\s+System(?:\.[\w.]+)?\s*;"#,
            #"\bConsole\.(?:WriteLine|Write|ReadLine)\s*\("#,
            #"\bnamespace\s+[A-Z]\w*(?:\.[A-Z]\w*)*\s*\{"#,
            #"\b(?:public|private|internal)\s+(?:static\s+)?(?:async\s+)?(?:Task|void|string|int|bool)\s+\w+\s*\("#
        ], keywords: [
            "using", "namespace", "Console", "static", "async", "await", "Task",
            "string", "bool", "var", "class", "public", "private"
        ]),
        LanguageRule(.rust, patterns: [
            #"(?m)^\s*(?:pub\s+)?fn\s+\w+\s*(?:<[^>]+>)?\s*\("#,
            #"\blet\s+mut\s+\w+"#,
            #"\bprintln!\s*\("#,
            #"(?m)^\s*use\s+[a-z_][\w:]*\s*;"#
        ], keywords: [
            "fn", "let", "mut", "pub", "impl", "trait", "struct", "enum", "match",
            "Result", "Option", "println", "use", "crate", "mod"
        ]),
        LanguageRule(.php, patterns: [
            #"(?i)<\?php"#,
            #"\b\$[A-Za-z_]\w*\s*="#,
            #"(?m)^\s*<\?=\s*"#,
            #"(?m)^\s*(?:public|private|protected)?\s*function\s+\w+\s*\("#
        ], keywords: [
            "php", "function", "echo", "namespace", "use", "public", "private",
            "protected", "class", "new", "array", "isset", "foreach"
        ]),
        LanguageRule(.ruby, patterns: [
            #"(?m)^\s*def\s+\w+[!?]?\s*(?:\([^)]*\))?\s*$"#,
            #"(?ms)^\s*def\s+\w+[!?]?\s*(?:\([^)]*\))?\s*$.*?^\s*end\s*$"#,
            #"(?m)^\s*(?:puts|require_relative)\s+"#,
            #"(?m)^\s*class\s+[A-Z]\w*\s*(?:<\s*[A-Z]\w*)?\s*$"#
        ], keywords: [
            "def", "end", "puts", "require", "attr_accessor", "do", "then",
            "elsif", "unless", "module", "class"
        ]),
        LanguageRule(.shell, patterns: [
            #"(?m)^#!\s*/(?:usr/)?bin/(?:env\s+)?(?:bash|sh|zsh)\b"#,
            #"(?m)^\s*(?:export\s+[A-Za-z_]\w*=|source\s+(?:~|\.)/|set\s+-[a-z])"#,
            #"(?m)^\s*(?:sudo|chmod|mkdir|rm|cp|mv|curl|wget|docker|kubectl|brew)\s+(?:-[-\w]+|[~/.\w]+/|[^\s]+\.(?:sh|zip|tar|gz|json|yml|yaml|txt)\b)"#,
            #"(?m)^\s*(?:git\s+(?:status|push|pull|commit|checkout|switch|rebase|merge|log|diff|add|clone|fetch|reset|stash)\b|npm\s+(?:install|run|test|ci|publish)\b|pnpm\s+(?:install|run|test|add|build)\b)"#,
            #"(?m)^\s*(?:echo|printf)\s+["'$A-Za-z]"#,
            #"(?m)^\s*if\s+\[\[?[^\n]+\]\]?[^\n]*;\s*then\s*$"#
        ], keywords: [
            "then", "fi", "done", "esac", "echo", "export", "set", "source",
            "sudo", "grep", "awk", "sed", "curl", "git"
        ]),
        LanguageRule(.sql, patterns: [
            #"(?m)^\s*SELECT\b[^\n]*\bFROM\b"#,
            #"(?m)^\s*INSERT\s+INTO\b"#,
            #"(?m)^\s*UPDATE\s+[A-Za-z_][\w.]*\s+SET\b"#,
            #"(?m)^\s*DELETE\s+FROM\b"#,
            #"(?m)^\s*(?:CREATE|ALTER)\s+(?:TABLE|INDEX|VIEW)\b"#
        ], keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "GROUP", "ORDER", "INSERT", "INTO",
            "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "LIMIT", "HAVING"
        ], caseSensitive: true)
    ]

    private static func matches(
        _ pattern: String,
        in text: String,
        caseSensitive: Bool = false
    ) -> Bool {
        var options: String.CompareOptions = [.regularExpression]
        if !caseSensitive { options.insert(.caseInsensitive) }
        return text.range(of: pattern, options: options) != nil
    }

    /// Generic shapes are deliberately strict. A sentence that happens to
    /// contain "if" or parentheses must not become a code explanation.
    private static func hasGenericCodeStructure(_ text: String) -> Bool {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let strongShapes = [
            #"^(?:await\s+)?[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\([^\n]*\)\s*;?$"#,
            #"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\s*=\s*[^=\s].*;?$"#,
            #"(?m)^\s*(?:if|for|while|switch|return|throw|try|catch|else|do)\b[^\n]*[{};]\s*$"#,
            #"(?m)^\s*(?:public|private|protected|static|final|class|struct|enum|interface|func|def|function|fn|package|import|using|namespace)\b[^\n]*(?:[{(]|=|;)\s*$"#,
            #"(?m)^\s*(?:int|long|short|char|float|double|bool|boolean|auto|size_t|unsigned)\s+\w+\s*(?::|=(?!=)|;)"#,
            #"(?m)^\s*(?:let|var|val|const)\s+\w+\s*:\s*[^=\n]+\s*="#,
            #"(?m)^\s*(?:private|public|protected|static|final)\s+(?:let|var|val|const)\s+\w+\s*:"#
        ]
        if strongShapes.contains(where: { matches($0, in: whole) }) {
            return true
        }

        let assignment = #"(?m)^\s*[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\s*(?:=|\+=|-=|\*=|/=|:=)\s*[^=]"#
        let functionCall = #"(?m)^\s*(?:await\s+)?[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\([^\n]*\)\s*;?\s*$"#
        let controlLine = #"(?m)^\s*(?:if|for|while|switch|return|throw|try|catch|else|do|case|break|continue)\b"#
        let declarationLine = #"(?m)^\s*(?:public|private|protected|static|final|class|struct|enum|interface|func|def|function|fn|package|import|using|namespace)\b"#

        let hasAssignment = matches(assignment, in: whole)
        let hasFunctionCall = matches(functionCall, in: whole)
        let hasControl = matches(controlLine, in: whole)
        let hasDeclaration = matches(declarationLine, in: whole)
        guard hasAssignment || hasFunctionCall || hasControl || hasDeclaration else {
            return false
        }

        var score = 0
        if whole.contains("{"), whole.contains("}") { score += 2 }
        if whole.contains(";") { score += 2 }
        if hasAssignment { score += 2 }
        if matches(#"(?m)^\s*(?://|/\*|\*|#\s*[A-Za-z_])"#, in: whole) { score += 2 }
        if hasFunctionCall { score += 2 }
        if hasControl { score += 1 }
        if hasDeclaration { score += 2 }
        if whole.contains("=>") || whole.contains("->") { score += 2 }
        if matches(#"(?m)^\s{2,}\S"#, in: whole) { score += 1 }
        return score >= 4
    }

    private static func languageByKeyword(in text: String) -> CodeSnippetLanguage? {
        let tokens = Set(text.lowercased().split { character in
            !(character.isLetter || character.isNumber || character == "_" || character == "$")
        }.map(String.init))
        var best: (language: CodeSnippetLanguage, score: Int)?
        for rule in rules {
            let score = rule.keywords.reduce(into: 0) { count, keyword in
                if tokens.contains(keyword.lowercased()) { count += 1 }
            }
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (rule.language, score)
            }
        }
        return best?.language
    }
}

/// Long code is split on line boundaries before explanation. The source limit
/// is shared with prose selections so an oversized drag still reports the
/// existing truncation note instead of silently dropping the tail.
public enum CodeTranslationSupport {
    /// The local plain-completion budget is 1024 tokens and the prose fallback
    /// is conservatively limited to 600 source characters for the same reason.
    /// Keep code chunks inside that budget so an explanation cannot be silently
    /// cut off. Chunk boundaries are whole lines whenever possible.
    public static let chunkCharacters = 600

    public static func prepareSource(_ text: String) -> SelectionSourcePlan {
        let originalCharacterCount = text.count
        let limited = SelectionTranslateSupport.limitSelectionSource(text)
        return SelectionSourcePlan(
            chunks: chunkCode(limited.text),
            didTruncate: limited.didTruncate,
            originalCharacterCount: originalCharacterCount,
            usedCharacterCount: limited.text.count
        )
    }

    public static func chunkCode(
        _ text: String,
        targetCharacters: Int = chunkCharacters
    ) -> [String] {
        let target = max(targetCharacters, 1)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > target else { return [trimmed] }

        var chunks: [String] = []
        var currentLines: [String] = []
        var currentCount = 0

        func flush() {
            let piece = currentLines.joined(separator: "\n")
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(piece)
            }
            currentLines = []
            currentCount = 0
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value.count > target {
                flush()
                chunks.append(contentsOf: SelectionTranslateSupport.chunkSource(
                    value,
                    targetCharacters: target
                ))
                continue
            }
            let added = value.count + (currentLines.isEmpty ? 0 : 1)
            if currentCount + added > target {
                flush()
            }
            currentLines.append(value)
            currentCount += value.count + (currentLines.count > 1 ? 1 : 0)
        }
        flush()
        return chunks.isEmpty ? [trimmed] : chunks
    }
}
