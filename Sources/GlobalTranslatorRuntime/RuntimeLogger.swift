import Darwin
import Foundation

public enum RuntimeRedactor {
    private static let bearerPattern = try! NSRegularExpression(
        pattern: "(?i)Bearer\\s+[A-Za-z0-9._~+/=-]+"
    )
    private static let keyPattern = try! NSRegularExpression(
        pattern: "(?i)(x-api-key|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|secret|password)\\s*[:=]\\s*([\\\"']?)[^\\s,;\\\"'}]+"
    )
    private static let keyLikePattern = try! NSRegularExpression(
        pattern: "\\b(?:sk|key|tok)-[A-Za-z0-9_-]{8,}\\b"
    )

    public static func redact(_ value: String) -> String {
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        var result = bearerPattern.stringByReplacingMatches(
            in: value,
            options: [],
            range: fullRange,
            withTemplate: "Bearer [REDACTED]"
        )
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = keyPattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: "$1=[REDACTED]"
        )
        let keyLikeRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = keyLikePattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: keyLikeRange,
            withTemplate: "[REDACTED]"
        )
        return result
    }
}

public final class RuntimeLogger: @unchecked Sendable {
    public let url: URL
    public let maximumBytes: Int
    public let backupCount: Int

    private let lock = NSLock()
    private let timestampFormatter: ISO8601DateFormatter

    public init(url: URL, maximumBytes: Int = 1_048_576, backupCount: Int = 3) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), maximumBytes > 0, backupCount >= 0 else {
            throw RuntimeError.invalidPath
        }
        self.url = url
        self.maximumBytes = maximumBytes
        self.backupCount = min(backupCount, 3)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter

        do {
            let parent = url.deletingLastPathComponent()
            let parentExisted = FileManager.default.fileExists(atPath: parent.path)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if !parentExisted {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: parent.path
                )
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            var information = stat()
            guard Darwin.lstat(url.path, &information) == 0,
                  (information.st_mode & S_IFMT) == S_IFREG else {
                throw RuntimeError.invalidPath
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.ioFailure
        }
    }

    public func write(level: String, event: String, fields: [String: String] = [:]) throws {
        let safeFields = fields.reduce(into: [String: String]()) { result, pair in
            result[String(pair.key.prefix(64))] = RuntimeRedactor.redact(String(pair.value.prefix(2_048)))
        }
        let record = LogRecord(
            timestamp: timestampFormatter.string(from: Date()),
            level: String(level.prefix(32)),
            event: RuntimeRedactor.redact(String(event.prefix(128))),
            fields: safeFields
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: Data
        do {
            encoded = try encoder.encode(record) + Data([0x0A])
        } catch {
            throw RuntimeError.ioFailure
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            let existingBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if existingBytes + encoded.count > maximumBytes {
                try rotateLocked()
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
            try handle.close()
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.ioFailure
        }
    }

    public func log(_ message: String, level: String = "info", event: String = "runtime") {
        try? write(level: level, event: event, fields: ["message": message])
    }

    private func rotateLocked() throws {
        let manager = FileManager.default
        if backupCount > 0 {
            for index in stride(from: backupCount, through: 1, by: -1) {
                let destination = backupURL(index)
                let source = index == 1 ? url : backupURL(index - 1)
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: destination)
                    try manager.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o600)],
                        ofItemAtPath: destination.path
                    )
                }
            }
        }
        manager.createFile(atPath: url.path, contents: Data())
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func backupURL(_ index: Int) -> URL {
        url.deletingPathExtension().appendingPathExtension(url.pathExtension + "." + String(index))
    }
}

private struct LogRecord: Codable, Sendable {
    let timestamp: String
    let level: String
    let event: String
    let fields: [String: String]
}
