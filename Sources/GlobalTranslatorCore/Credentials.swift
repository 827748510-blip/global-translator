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
        do {
            try write(data, useDataProtection: true)
        } catch let error as CredentialStoreError {
            guard case .keychainFailure(let status) = error,
                  isDataProtectionUnavailable(status) else {
                throw error
            }
            // Only fall back to the login keychain when the process lacks the
            // data-protection entitlement (e.g. local ad-hoc builds); surface
            // other keychain failures directly instead of silently downgrading.
            try write(data, useDataProtection: false)
            let deleteStatus = SecItemDelete(baseQuery(useDataProtection: true) as CFDictionary)
            guard deleteStatus == errSecSuccess
                || deleteStatus == errSecItemNotFound
                || isDataProtectionUnavailable(deleteStatus) else {
                throw CredentialStoreError.keychainFailure(status: deleteStatus)
            }
        }
    }

    public func read() throws -> String? {
        var dataProtectionError: Error?
        do {
            if let value = try copyMatching(useDataProtection: true) {
                return value
            }
        } catch let error as CredentialStoreError {
            if case .keychainFailure(let status) = error, isDataProtectionUnavailable(status) {
                // Expected for self-signed builds; fall through to login keychain.
            } else {
                dataProtectionError = error
            }
        } catch {
            dataProtectionError = error
        }
        // Self-signed builds cannot read the data-protection keychain. Older
        // builds stored the secret in the file-based login keychain.
        do {
            guard let legacy = try copyMatching(useDataProtection: false) else {
                if let dataProtectionError { throw dataProtectionError }
                return nil
            }
            migrateLegacyItemToDataProtection(legacy)
            return legacy
        } catch let fallbackError {
            if let dataProtectionError { throw dataProtectionError }
            throw fallbackError
        }
    }

    public func delete() throws {
        let dataProtectionStatus = SecItemDelete(baseQuery(useDataProtection: true) as CFDictionary)
        let legacyStatus = SecItemDelete(baseQuery(useDataProtection: false) as CFDictionary)
        let dataProtectionOK = dataProtectionStatus == errSecSuccess
            || dataProtectionStatus == errSecItemNotFound
            || isDataProtectionUnavailable(dataProtectionStatus)
        let legacyOK = legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound
        guard dataProtectionOK && legacyOK else {
            let status = dataProtectionOK ? legacyStatus : dataProtectionStatus
            throw CredentialStoreError.keychainFailure(status: status)
        }
    }

    private func isDataProtectionUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }

    /// Data-protection keychain is preferred when the app has the required
    /// entitlement. The same app can then read without a login-keychain ACL
    /// prompt. Login-keychain writes remain the compatibility fallback.
    private func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
        }
        return query
    }

    private func write(_ data: Data, useDataProtection: Bool) throws {
        let query = baseQuery(useDataProtection: useDataProtection)
        let valueAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, valueAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            // File-based keychain items can reject an accessibility-attribute
            // update; rotate the secret with a value-only update instead.
            if !useDataProtection {
                let retry = SecItemUpdate(
                    query as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                if retry == errSecSuccess { return }
            }
            throw CredentialStoreError.keychainFailure(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if !useDataProtection {
            addQuery[kSecAttrSynchronizable as String] = false
        }
        var addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, !useDataProtection {
            // The existing login-keychain item may predate the explicit
            // synchronizable attribute; update it by service/account.
            let legacyQuery = baseQuery(useDataProtection: false)
            let retry = SecItemUpdate(
                legacyQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if retry == errSecSuccess { return }
        }
        if addStatus != errSecSuccess, !useDataProtection {
            // Older macOS versions reject accessibility on file-based items.
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: addStatus)
        }
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
        return try DeepSeekAPIKeyValidator.normalized(value)
    }

    private func migrateLegacyItemToDataProtection(_ apiKey: String) {
        guard let data = apiKey.data(using: .utf8) else { return }
        do {
            // Direct DP write: a fallback login-keychain write here would make
            // the subsequent delete remove the only usable copy.
            try write(data, useDataProtection: true)
            _ = SecItemDelete(baseQuery(useDataProtection: false) as CFDictionary)
        } catch {
            // Leave the legacy item in place; the caller still has the secret.
        }
    }
}
