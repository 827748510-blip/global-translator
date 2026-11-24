import ApplicationServices
import CoreGraphics
import Foundation
import GlobalTranslatorCore

public enum DoctorLevel: String, Codable, Equatable, Sendable {
    case pass = "PASS"
    case warn = "WARN"
    case fail = "FAIL"
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let name: String
    public let level: DoctorLevel
    public let detail: String

    public init(name: String, level: DoctorLevel, detail: String) {
        self.name = name
        self.level = level
        self.detail = detail
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
    }

    public var hasFailure: Bool {
        checks.contains { $0.level == .fail }
    }

    public func renderChinese() -> String {
        checks.map { "[\($0.level.rawValue)] \($0.name)：\($0.detail)" }.joined(separator: "\n") + "\n"
    }
}

public struct DoctorInputs: Equatable, Sendable {
    public let operatingSystemMajor: Int
    public let architecture: String
    public let physicalMemoryGiB: Int
    public let accessibilityTrusted: Bool
    public let screenCapturePreflight: Bool
    public let binaryAtRecommendedPath: Bool
    public let keychainReadable: Bool
    public let configurationDecodable: Bool
    public let whisperAvailable: Bool

    public init(
        operatingSystemMajor: Int,
        architecture: String,
        physicalMemoryGiB: Int,
        accessibilityTrusted: Bool,
        screenCapturePreflight: Bool,
        binaryAtRecommendedPath: Bool,
        keychainReadable: Bool,
        configurationDecodable: Bool,
        whisperAvailable: Bool = true
    ) {
        self.operatingSystemMajor = operatingSystemMajor
        self.architecture = architecture
        self.physicalMemoryGiB = physicalMemoryGiB
        self.accessibilityTrusted = accessibilityTrusted
        self.screenCapturePreflight = screenCapturePreflight
        self.binaryAtRecommendedPath = binaryAtRecommendedPath
        self.keychainReadable = keychainReadable
        self.configurationDecodable = configurationDecodable
        self.whisperAvailable = whisperAvailable
    }

    public static func current(paths: RuntimePaths) -> DoctorInputs {
        let operatingSystemMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        let physicalMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / (1_073_741_824))
        let accessibilityTrusted = AXIsProcessTrusted()
        let screenCapturePreflight = CGPreflightScreenCaptureAccess()
        let binaryPath = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
        let binaryAtRecommendedPath = binaryPath.path == paths.recommendedBinaryURL.path &&
            FileManager.default.isExecutableFile(atPath: binaryPath.path)
        let keychainReadable: Bool
        do {
            _ = try MacOSKeychainStore().read()
            keychainReadable = true
        } catch {
            keychainReadable = false
        }
        let configurationDecodable: Bool
        if !FileManager.default.fileExists(atPath: paths.configURL.path) {
            configurationDecodable = true
        } else {
            configurationDecodable = (try? JSONDecoder().decode(
                AppConfiguration.self,
                from: Data(contentsOf: paths.configURL)
            )) != nil
        }
        let whisper = WhisperCppLocator.candidatesForSupportDirectory(paths.whisperDirectory)
        let whisperAvailable = WhisperCppLocator.locate(
            extraBinaryCandidates: whisper.binaries,
            extraModelCandidates: whisper.models
        ).isAvailable
        return DoctorInputs(
            operatingSystemMajor: operatingSystemMajor,
            architecture: architecture,
            physicalMemoryGiB: physicalMemoryGiB,
            accessibilityTrusted: accessibilityTrusted,
            screenCapturePreflight: screenCapturePreflight,
            binaryAtRecommendedPath: binaryAtRecommendedPath,
            keychainReadable: keychainReadable,
            configurationDecodable: configurationDecodable,
            whisperAvailable: whisperAvailable
        )
    }
}

public struct Doctor: Sendable {
    private let inputs: DoctorInputs
    private let recommendedBinaryHint: String

    public init(inputs: DoctorInputs) {
        self.inputs = inputs
        self.recommendedBinaryHint = "~/.local/bin/global-translator"
    }

    public init(paths: RuntimePaths = .production()) {
        self.inputs = DoctorInputs.current(paths: paths)
        self.recommendedBinaryHint = paths.usesOverrideRoot
            ? paths.recommendedBinaryURL.path
            : "~/.local/bin/global-translator"
    }

    public func run() -> DoctorReport {
        var checks = [DoctorCheck]()
        checks.append(DoctorCheck(
            name: "macOS 版本",
            level: inputs.operatingSystemMajor >= 27 ? .pass : .fail,
            detail: inputs.operatingSystemMajor >= 27
                ? "版本满足 macOS 27+"
                : "需要 macOS 27 或更高版本"
        ))
        checks.append(DoctorCheck(
            name: "处理器架构",
            level: inputs.architecture == "arm64" ? .pass : .fail,
            detail: inputs.architecture == "arm64" ? "arm64" : "需要 arm64"
        ))
        checks.append(DoctorCheck(
            name: "物理内存",
            level: inputs.physicalMemoryGiB >= 16 ? .pass : .fail,
            detail: inputs.physicalMemoryGiB >= 16
                ? String(inputs.physicalMemoryGiB) + " GiB"
                : "需要至少 16 GiB"
        ))
        checks.append(DoctorCheck(
            name: "辅助功能权限",
            level: inputs.accessibilityTrusted ? .pass : .warn,
            detail: inputs.accessibilityTrusted ? "已授权" : "未授权，后续捕获功能不可用"
        ))
        checks.append(DoctorCheck(
            name: "屏幕录制预检",
            level: inputs.screenCapturePreflight ? .pass : .warn,
            detail: inputs.screenCapturePreflight ? "预检通过" : "未授权，后续屏幕读取可能失败"
        ))
        checks.append(DoctorCheck(
            name: "固定二进制路径",
            level: inputs.binaryAtRecommendedPath ? .pass : .warn,
            detail: inputs.binaryAtRecommendedPath ? "路径可执行" : "建议安装到 \(recommendedBinaryHint)"
        ))
        checks.append(DoctorCheck(
            name: "Keychain 可读性",
            level: inputs.keychainReadable ? .pass : .warn,
            detail: inputs.keychainReadable ? "读取接口可用" : "读取接口不可用或尚未授权"
        ))
        checks.append(DoctorCheck(
            name: "配置文件",
            level: inputs.configurationDecodable ? .pass : .fail,
            detail: inputs.configurationDecodable ? "可解码" : "config.json 无法解码"
        ))
        checks.append(DoctorCheck(
            name: "本地 Whisper.cpp",
            level: inputs.whisperAvailable ? .pass : .warn,
            detail: inputs.whisperAvailable
                ? "已找到本地 CLI 与模型"
                : "未找到，无字幕视频翻译（B2）不可用；字幕路径仍可用"
        ))
        return DoctorReport(checks: checks)
    }
}
