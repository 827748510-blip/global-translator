import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func save(apiKey: String) throws
    func read() throws -> String?
    func delete() throws
}

public extension CredentialStoring {
    func save(_ apiKey: String) throws {
        try save(apiKey: apiKey)
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychainFailure(status: OSStatus)
    case invalidValue
}

public struct MacOSKeychainStore: CredentialStoring, Sendable {
    public static let defaultService = "com.maodashu.global-translator.deepseek"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String

    public init(
        service: String = MacOSKeychainStore.defaultService,
        account: String = MacOSKeychainStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func save(apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey.count <= 4_096,
              let data = apiKey.data(using: .utf8) else {
            throw CredentialStoreError.invalidValue
        }
        let attributes = itemAttributes(value: data)
        let query = baseQuery()
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (key, value) in attributes {
                addQuery[key] = value
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            // Some macOS versions reject combining ACL + accessibility; keep the secret.
            var fallbackAdd = query
            fallbackAdd[kSecValueData as String] = data
            fallbackAdd[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let fallbackStatus = SecItemAdd(fallbackAdd as CFDictionary, nil)
            guard fallbackStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            // ACL / accessibility updates can fail on older items; still rotate the secret.
            let valueOnly = [kSecValueData as String: data] as CFDictionary
            let retryStatus = SecItemUpdate(query as CFDictionary, valueOnly)
            guard retryStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: updateStatus)
            }
        }
    }

    public func read() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidValue
        }
        return value
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Persist with this app as a trusted caller so the same signed binary
    /// can later `read()` without a login-keychain prompt. Ad-hoc re-signing
    /// changes the designated requirement, so macOS may ask once more.
    private func itemAttributes(value: Data) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let access = makeTrustedAccess() {
            attributes[kSecAttrAccess as String] = access
        }
        return attributes
    }

    private func makeTrustedAccess() -> SecAccess? {
        var access: SecAccess?
        // `nil` trusted list means the creating application is trusted, so the
        // same signed binary can later read without a login-keychain prompt.
        let status = SecAccessCreate(
            "Global Translator DeepSeek API key" as CFString,
            nil,
            &access
        )
        guard status == errSecSuccess else { return nil }
        return access
    }
}
