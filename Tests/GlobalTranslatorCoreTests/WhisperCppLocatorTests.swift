import Foundation
import Testing
@testable import GlobalTranslatorCore

struct WhisperCppLocatorTests {
    @Test
    func missingFilesAreUnavailable() {
        let located = WhisperCppLocator.locate(
            environment: [:],
            extraBinaryCandidates: [URL(fileURLWithPath: "/tmp/missing-whisper-cli")],
            extraModelCandidates: [URL(fileURLWithPath: "/tmp/missing-model.bin")],
            fileExists: { _ in false },
            isExecutable: { _ in false }
        )
        #expect(!located.isAvailable)
        #expect(located.binaryURL == nil)
        #expect(located.modelURL == nil)
    }

    @Test
    func environmentOverridesWellKnownPaths() {
        let binary = URL(fileURLWithPath: "/opt/custom/whisper-cli")
        let model = URL(fileURLWithPath: "/opt/custom/ggml-base.en.bin")
        let located = WhisperCppLocator.locate(
            environment: [
                WhisperCppLocator.binaryEnvironmentKey: binary.path,
                WhisperCppLocator.modelEnvironmentKey: model.path
            ],
            fileExists: { $0.path == binary.path || $0.path == model.path },
            isExecutable: { $0.path == binary.path },
            isTrustedPath: { _, _ in true }
        )
        #expect(located.isAvailable)
        #expect(located.binaryURL?.path == binary.path)
        #expect(located.modelURL?.path == model.path)
    }

    @Test
    func rejectsRelativeUntrustedAndWorldWritableBinaryPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-whisper-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let safeBin = dir.appendingPathComponent("whisper-cli")
        let safeModel = dir.appendingPathComponent("ggml-base.en.bin")
        try Data("#!/bin/sh\n".utf8).write(to: safeBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: safeBin.path)
        try Data("model".utf8).write(to: safeModel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: safeModel.path)

        let trusted = WhisperCppLocator.locate(environment: [
            WhisperCppLocator.binaryEnvironmentKey: safeBin.path,
            WhisperCppLocator.modelEnvironmentKey: safeModel.path
        ])
        #expect(trusted.binaryURL?.path == safeBin.standardizedFileURL.path)
        #expect(trusted.modelURL?.path == safeModel.standardizedFileURL.path)

        let relative = WhisperCppLocator.locate(
            environment: [
                WhisperCppLocator.binaryEnvironmentKey: "relative/whisper-cli",
                WhisperCppLocator.modelEnvironmentKey: "../evil.bin"
            ],
            extraBinaryCandidates: [],
            extraModelCandidates: [],
            fileExists: { url in url.path.contains("relative") || url.path.contains("evil") },
            isExecutable: { _ in true },
            isTrustedPath: { _, _ in true }
        )
        #expect(relative.binaryURL == nil)
        #expect(relative.modelURL == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: safeBin.path)
        #expect(!WhisperCppLocator.isTrustedLocalFile(safeBin, requireExecutable: true))
        #expect(!WhisperCppLocator.isTrustedLocalFile(dir, requireExecutable: true))
    }

    @Test
    func supportDirectoryCandidatesIncludeEnglishModels() {
        let dir = URL(fileURLWithPath: "/Users/example/Library/Application Support/GlobalTranslator/whisper")
        let candidates = WhisperCppLocator.candidatesForSupportDirectory(dir)
        #expect(candidates.binaries.contains { $0.lastPathComponent == "whisper-cli" })
        #expect(candidates.models.contains { $0.lastPathComponent == "ggml-base.en.bin" })
        #expect(candidates.models.contains { $0.lastPathComponent == "ggml-tiny.en.bin" })
    }

    @Test
    func locatorFindsTrustedWhisperServerAndRejectsUntrusted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-whisper-srv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let cli = dir.appendingPathComponent("whisper-cli")
        let srv = dir.appendingPathComponent("whisper-server")
        let model = dir.appendingPathComponent("ggml-base.en.bin")
        for exec in [cli, srv] {
            try Data("#!/bin/sh\n".utf8).write(to: exec)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exec.path)
        }
        try Data("model".utf8).write(to: model)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: model.path)

        let located = WhisperCppLocator.locate(environment: [
            WhisperCppLocator.binaryEnvironmentKey: cli.path,
            WhisperCppLocator.modelEnvironmentKey: model.path
        ])
        #expect(located.serverBinaryURL?.path == srv.standardizedFileURL.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: srv.path)
        let untrusted = WhisperCppLocator.locate(environment: [
            WhisperCppLocator.binaryEnvironmentKey: cli.path,
            WhisperCppLocator.modelEnvironmentKey: model.path
        ])
        #expect(untrusted.serverBinaryURL?.path != srv.standardizedFileURL.path)
    }
}
