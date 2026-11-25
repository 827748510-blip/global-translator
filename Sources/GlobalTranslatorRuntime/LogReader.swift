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
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return []
        }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            return []
        }
        let fileSize = Int(info.st_size)
        guard fileSize > 0 else {
            return []
        }

        let smallThreshold = 32_768
        if fileSize <= smallThreshold {
            var data = Data(count: fileSize)
            let readBytes = data.withUnsafeMutableBytes { ptr in
                readAll(fd: fd, into: ptr.baseAddress, length: fileSize)
            }
            guard readBytes > 0 else { return [] }
            let text = String(decoding: data.prefix(readBytes), as: UTF8.self)
            let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            return lines.suffix(limit).map { RuntimeRedactor.redact(String($0)) }
        }

        let chunkSize = 8_192
        var offset = fileSize
        var trailingChunks: [Data] = []
        var newlineCount = 0
        var sawNonNewline = false

        while offset > 0 && newlineCount <= limit {
            let start = max(0, offset - chunkSize)
            let length = offset - start
            guard Darwin.lseek(fd, off_t(start), SEEK_SET) == off_t(start) else {
                break
            }
            var chunk = Data(count: length)
            let readBytes = chunk.withUnsafeMutableBytes { ptr in
                readAll(fd: fd, into: ptr.baseAddress, length: length)
            }
            guard readBytes > 0 else { break }
            let slice = chunk.prefix(readBytes)
            trailingChunks.append(slice)
            for byte in slice.reversed() {
                if byte == 0x0A || byte == 0x0D {
                    if sawNonNewline {
                        newlineCount += 1
                    }
                } else {
                    sawNonNewline = true
                }
            }
            offset = start
        }

        let totalCount = trailingChunks.reduce(0) { $0 + $1.count }
        var combined = Data()
        combined.reserveCapacity(totalCount)
        for chunk in trailingChunks.reversed() {
            combined.append(chunk)
        }
        // If we stopped mid-file, drop the potentially partial first line before decoding UTF-8.
        let sliceToDecode: Data
        if offset > 0, let firstNewline = combined.firstIndex(of: 0x0A) {
            sliceToDecode = combined.suffix(from: combined.index(after: firstNewline))
        } else {
            sliceToDecode = combined
        }
        let text = String(decoding: sliceToDecode, as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        return lines.suffix(limit).map { RuntimeRedactor.redact(String($0)) }
    }

    private func readAll(fd: Int32, into base: UnsafeMutableRawPointer?, length: Int) -> Int {
        guard let base, length > 0 else { return 0 }
        var total = 0
        while total < length {
            let n = Darwin.read(fd, base.advanced(by: total), length - total)
            if n > 0 {
                total += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return total
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
