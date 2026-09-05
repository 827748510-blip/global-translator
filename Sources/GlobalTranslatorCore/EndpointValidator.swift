import Foundation

public enum EndpointValidationError: Error, Equatable, Sendable {
    case invalidScheme
    case credentialsNotAllowed
    case queryNotAllowed
    case fragmentNotAllowed
    case hostNotLoopback
}

public enum EndpointValidator {
    public static func validateLocalBaseURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("http") == .orderedSame else {
            throw EndpointValidationError.invalidScheme
        }
        guard url.user == nil, url.password == nil else {
            throw EndpointValidationError.credentialsNotAllowed
        }
        guard url.query == nil else {
            throw EndpointValidationError.queryNotAllowed
        }
        guard url.fragment == nil else {
            throw EndpointValidationError.fragmentNotAllowed
        }
        guard let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw EndpointValidationError.hostNotLoopback
        }
        return url
    }
}
