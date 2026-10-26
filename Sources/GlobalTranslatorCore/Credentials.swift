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

/// DeepSeek keys are opaque ASCII tokens. Normalizing here prevents accidental
/// leading/trailing whitespace and rejects header-breaking control characters
/// before the value can reach a Keychain item or an Authorization header.
public enum DeepSeekAPIKeyValidator {
    public static let maximumLength = 4_096

    public static func normalized(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maximumLength,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw CredentialStoreError.invalidValue
        }
        return value
    }
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
        let normalized = try DeepSeekAPIKeyValidator.normalized(apiKey)
        guard let data = normalized.data(using: .utf8) else {
            throw CredentialStoreError.invalidValue
        }
        let query = baseQuery(useDataProtection: true)
        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            // Enforce device-bound, unlocked-only access even when replacing an
            // item created by a previous build with a weaker accessibility.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, valueAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychainFailure(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychainFailure(status: updateStatus)
        }
    }

    public func read() throws -> String? {
        if let value = try copyMatching(useDataProtection: true) {
            return value
        }
        // Older builds stored the secret in the file-based login keychain.
        // That path can still show an ACL prompt once; migrate so later
        // reads stay on the data-protection keychain (no SecAccess API).
        guard let legacy = try copyMatching(useDataProtection: false) else {
            return nil
        }
        migrateLegacyItemToDataProtection(legacy)
        return legacy
    }

    public func delete() throws {
        let dataProtectionStatus = SecItemDelete(baseQuery(useDataProtection: true) as CFDictionary)
        let legacyStatus = SecItemDelete(baseQuery(useDataProtection: false) as CFDictionary)
        let dataProtectionOK = dataProtectionStatus == errSecSuccess || dataProtectionStatus == errSecItemNotFound
        let legacyOK = legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound
        guard dataProtectionOK && legacyOK else {
            let status = dataProtectionOK ? legacyStatus : dataProtectionStatus
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    /// Data-protection keychain is the supported replacement for file-based
    /// `SecAccess` ACLs: same app can `read()` without a login-keychain prompt.
    /// Ad-hoc re-signing may still make the old item invisible; the user then
    /// saves the key again.
    private func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func copyMatching(useDataProtection: Bool) throws -> String? {
        var query = baseQuery(useDataProtection: useDataProtection)
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

    private func migrateLegacyItemToDataProtection(_ apiKey: String) {
        do {
            try save(apiKey: apiKey)
            _ = SecItemDelete(baseQuery(useDataProtection: false) as CFDictionary)
        } catch {
            // Leave the legacy item in place; the caller still has the secret.
        }
    }
}
