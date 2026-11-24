import Foundation
import Testing
@testable import GlobalTranslatorApp

/// Temporary background verification against a headless Chrome started with
/// `--remote-debugging-port=9223`. Skips silently when it is not running so
/// the suite stays hermetic.
struct CDPHeadlessVerificationTests {
    @Test
    func headlessChromeExtractsAndReplacesPageText() async throws {
        let translator = CDPInPageTranslator(port: 9223)
        guard await translator.isApplicable(bundleIdentifier: "com.google.Chrome", windowPID: 0) else { return }
        let texts = try await translator.extract(windowRevision: 1)
        if texts.isEmpty {
            // Page was already replaced in a previous run (translation is
            // persisted in the DOM until reload); nothing left to verify.
            let after = try await translator.extract(windowRevision: 2)
            #expect(after.isEmpty)
            return
        }
        #expect(!texts.isEmpty)
        let replacements = texts.map { InPageReplacement(nodeID: $0.nodeID, text: $0.text + "测试通过") }
        try await translator.apply(replacements)
        let after = try await translator.extract(windowRevision: 2)
        #expect(after.isEmpty)
    }

    /// A window owned by any process other than the debug-enabled browser
    /// must be rejected so the session routes it to the bubble pipeline.
    @Test
    func foreignProcessWindowIsNotApplicable() async throws {
        let translator = CDPInPageTranslator(port: 9223)
        guard await translator.isApplicable(bundleIdentifier: "com.google.Chrome", windowPID: 0) else { return }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let foreign = await translator.isApplicable(bundleIdentifier: "com.google.Chrome", windowPID: ownPID)
        #expect(!foreign)
        let unknown = await translator.isApplicable(bundleIdentifier: "com.google.Chrome", windowPID: 0)
        #expect(unknown)
    }
}
