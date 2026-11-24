import Darwin
import Foundation

public struct RuntimeLogReader: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func lastLines(limit: Int = 200) throws -> [String] {
        guard limit > 0 else {
            return []
        }
        guard isRegularFile(url.path), let data = FileManager.default.contents(atPath: url.path) else {
            return []
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        return lines.suffix(limit).map { RuntimeRedactor.redact(String($0)) }
    }

    public func readAll() throws -> String {
        guard isRegularFile(url.path), let data = FileManager.default.contents(atPath: url.path) else {
            return ""
        }
        return RuntimeRedactor.redact(String(decoding: data, as: UTF8.self))
    }

    private func isRegularFile(_ path: String) -> Bool {
        var information = stat()
        guard Darwin.lstat(path, &information) == 0 else {
            return false
        }
        return (information.st_mode & S_IFMT) == S_IFREG
    }
}
