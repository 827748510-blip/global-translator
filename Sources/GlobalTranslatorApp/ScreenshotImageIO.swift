import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图翻译的落盘 / 剪贴板动作。PNG 写入、目录创建、文件名都在这里，便于测试注入。
public enum ScreenshotImageIO {
    public enum SaveError: Error, Equatable, Sendable {
        case pngEncodingFailed
        case unsafePath
        case writeFailed
    }

    private static let timestampCalendar = Calendar(identifier: .gregorian)

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 后台编码。4K 截图的 PNG 编码在主线程要几十到几百毫秒，期间弹层和快捷键
    /// 一起卡住；编码是纯计算，放到后台只把结果带回主线程。
    public static func pngDataOffMain(_ image: CGImage) async -> Data? {
        let box = SendableImage(image: image)
        return await Task.detached(priority: .userInitiated) {
            pngData(box.image)
        }.value
    }

    /// Writes `image` as a timestamped PNG into `directory`, creating it when
    /// missing. File names are unique to the second, with a short suffix so two
    /// screenshots in the same second never overwrite each other.
    public static func save(
        _ image: CGImage,
        to directory: URL,
        filename: String? = nil
    ) throws -> URL {
        guard let data = pngData(image) else { throw SaveError.pngEncodingFailed }
        return try save(pngData: data, to: directory, filename: filename)
    }

    /// 已编码的 PNG 直接落盘：截图路径只编码一次，保存与复制共用同一份数据。
    public static func save(
        pngData data: Data,
        to directory: URL,
        filename: String? = nil
    ) throws -> URL {
        let name = filename ?? defaultFilename()
        try validateFilename(name)
        var existingDirStat = Darwin.stat()
        let dirExisted = Darwin.lstat(directory.path, &existingDirStat) == 0
        if dirExisted {
            guard (existingDirStat.st_mode & S_IFMT) == S_IFDIR else {
                throw SaveError.unsafePath
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            var createdStat = Darwin.stat()
            guard Darwin.lstat(directory.path, &createdStat) == 0,
                  (createdStat.st_mode & S_IFMT) == S_IFDIR else {
                throw SaveError.unsafePath
            }
            _ = Darwin.chmod(directory.path, 0o700)
        }

        let url = directory.appendingPathComponent(name, isDirectory: false)
        try ensureNoSymlink(at: url.path)

        let tmpName = ".\(name).tmp.\(UUID().uuidString)"
        let tmpPath = directory.appendingPathComponent(tmpName, isDirectory: false).path
        let fd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw SaveError.writeFailed
        }
        var renamed = false
        defer {
            Darwin.close(fd)
            if !renamed {
                _ = Darwin.unlink(tmpPath)
            }
        }
        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw SaveError.writeFailed
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && Darwin.errno == EINTR {
                    continue
                } else {
                    throw SaveError.writeFailed
                }
            }
        }
        try ensureNoSymlink(at: url.path)
        guard Darwin.rename(tmpPath, url.path) == 0 else {
            throw SaveError.writeFailed
        }
        renamed = true
        return url
    }

    private static func validateFilename(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SaveError.unsafePath
        }
    }

    private static func ensureNoSymlink(at path: String) throws {
        var st = Darwin.stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) != S_IFLNK else {
                throw SaveError.unsafePath
            }
        }
    }

    public static func copyToClipboard(_ image: CGImage) {
        guard let data = pngData(image) else { return }
        copyToClipboard(pngData: data)
    }

    public static func copyToClipboard(pngData data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    public static func defaultFilename(now: Date = Date()) -> String {
        let components = timestampCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            year,
            month,
            day,
            hour,
            minute,
            second
        )
        let suffix = UUID().uuidString.prefix(4)
        return "截图翻译-\(stamp)-\(suffix).png"
    }
}

/// `CGImage` 构造后不可变，跨线程只读是安全的；CoreGraphics 没有标注
/// `Sendable`，这里显式封箱，避免把整张图钉在主线程上编码。
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}
