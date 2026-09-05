import Foundation
import GlobalTranslatorCore

@MainActor
public final class ConfigurationPersistence {
    public let store: any ConfigurationStoring

    private struct Pending {
        let revision: UInt64
        let configuration: AppConfiguration
    }

    private var nextRevision: UInt64 = 0
    private var pending: Pending?
    private var writer: Task<Void, Never>?
    private var lastError: Error?

    public init(store: any ConfigurationStoring) {
        self.store = store
    }

    public func load() async throws -> AppConfiguration {
        try await store.load()
    }

    public func enqueue(_ configuration: AppConfiguration) {
        nextRevision &+= 1
        pending = Pending(revision: nextRevision, configuration: configuration)
        guard writer == nil else { return }
        writer = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    public func flush() async throws {
        while let writer {
            await writer.value
            if self.writer == nil { break }
        }
        if let lastError {
            self.lastError = nil
            throw lastError
        }
    }

    public var latestRevision: UInt64 { nextRevision }

    private func drain() async {
        while let item = pending {
            pending = nil
            do {
                try await store.save(item.configuration)
            } catch {
                lastError = error
            }
        }
        writer = nil
    }
}
