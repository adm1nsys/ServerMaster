//
//  DatabaseCredentialStore.swift
//  ServerMaster
//
//  Database passwords belong in the system credential store, not in a profile,
//  backup index or log file.  This is the macOS counterpart of the Windows
//  Credential Manager store.  A database name is only an opaque Keychain
//  account key; the JSON payload contains the account name and password.
//

import Foundation
import Security

nonisolated enum DatabaseCredentialStore {

    nonisolated struct Credential: Codable, Sendable, Equatable {
        let user: String
        let password: String
    }

    private static let service = "com.adm1nsys.ServerMaster.database"

    private static func query(for database: String, service: String, keychain: SecKeychain?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: database
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    /// Replaces an older value when the same local database is re-created.
    /// The caller decides whether a Keychain failure should be surfaced; a
    /// successfully-created database must never be rolled back only because
    /// the password could not be remembered.
    static func save(database: String, user: String, password: String,
                     service: String = service, keychain: SecKeychain? = nil) throws {
        let credential = Credential(user: user, password: password)
        let data = try JSONEncoder().encode(credential)
        var item = query(for: database, service: service, keychain: keychain)
        item.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain { item[kSecUseKeychain as String] = keychain }
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query(for: database, service: service, keychain: keychain) as CFDictionary,
                                             update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func read(database: String, service: String = service, keychain: SecKeychain? = nil) throws -> Credential? {
        var lookup = query(for: database, service: service, keychain: keychain)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    static func delete(database: String, service: String = service, keychain: SecKeychain? = nil) throws {
        let status = SecItemDelete(query(for: database, service: service, keychain: keychain) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Production uses the system Keychain. Integration tests supply a private
/// keychain (or a failing implementation) without touching login credentials.
struct DatabaseCredentialAccess {
    var save: (String, String, String) throws -> Void
    var read: (String) throws -> DatabaseCredentialStore.Credential?
    var delete: (String) throws -> Void

    static let system = DatabaseCredentialAccess(
        save: { try DatabaseCredentialStore.save(database: $0, user: $1, password: $2) },
        read: { try DatabaseCredentialStore.read(database: $0) },
        delete: { try DatabaseCredentialStore.delete(database: $0) })
}

nonisolated struct KeychainError: LocalizedError, Sendable {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)"
    }
}
