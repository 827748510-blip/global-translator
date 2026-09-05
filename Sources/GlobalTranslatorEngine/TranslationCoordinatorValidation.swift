import Foundation
import GlobalTranslatorCore

func validateTranslationResult(
    _ result: TranslationResult,
    expectedRequest: TranslationRequest
) throws {
    guard result.windowRevision == expectedRequest.windowRevision else {
        throw TranslationError.invalidResponse("translation revision does not match request")
    }
    let expectedIDs = Set(expectedRequest.items.map(\.id))
    let actualIDs = result.translations.map(\.segmentId)
    guard actualIDs.count == expectedIDs.count,
          Set(actualIDs).count == actualIDs.count,
          Set(actualIDs) == expectedIDs else {
        throw TranslationError.invalidResponse("translation IDs do not match request")
    }
    guard result.translations.allSatisfy({
        let text = $0.simplifiedChineseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 4_000
    }) else {
        throw TranslationError.invalidResponse("translation text is empty or too long")
    }
}

func engineFailureStatus(for error: TranslationError) -> EngineFailureStatus {
    switch error {
    case .missingCredential: return .missingCredential
    case .unauthorized: return .unauthorized
    case .forbidden: return .forbidden
    case .rateLimited: return .rateLimited
    case .serverFailure: return .serverFailure
    case .timeout: return .timeout
    case .networkFailure: return .networkFailure
    case .redirectRejected: return .redirectRejected
    case .modelUnavailable: return .modelUnavailable
    case .invalidConfiguration: return .invalidConfiguration
    case .invalidRequest: return .invalidRequest
    case .invalidResponse: return .invalidResponse
    }
}
