import Foundation

public enum ConfigStoreError: Error, Equatable, Sendable {
    case invalidData
    case encodingFailure
    case writeFailure
}

public actor ConfigStore {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let configuredEncoder = JSONEncoder()
        configuredEncoder.outputFormatting = [.sortedKeys]
        encoder = configuredEncoder
        decoder = JSONDecoder()
    }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfiguration()
        }
        do {
            return try decoder.decode(AppConfiguration.self, from: Data(contentsOf: url))
        } catch {
            throw ConfigStoreError.invalidData
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        let data: Data
        do {
            data = try encoder.encode(configuration)
        } catch {
            throw ConfigStoreError.encodingFailure
        }
        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            throw ConfigStoreError.writeFailure
        }
    }
}
