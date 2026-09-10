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
            isExecutable: { $0.path == binary.path }
        )
        #expect(located.isAvailable)
        #expect(located.binaryURL?.path == binary.path)
        #expect(located.modelURL?.path == model.path)
    }

    @Test
    func supportDirectoryCandidatesIncludeEnglishModels() {
        let dir = URL(fileURLWithPath: "/Users/example/Library/Application Support/GlobalTranslator/whisper")
        let candidates = WhisperCppLocator.candidatesForSupportDirectory(dir)
        #expect(candidates.binaries.contains { $0.lastPathComponent == "whisper-cli" })
        #expect(candidates.models.contains { $0.lastPathComponent == "ggml-base.en.bin" })
        #expect(candidates.models.contains { $0.lastPathComponent == "ggml-tiny.en.bin" })
    }
}
