//
//  KeychainStore.swift
//  StalkerDeskCore
//
//  Keychain-backed storage for portal passwords and resumable session tokens.
//  Secrets never live in the Core Data store or UserDefaults.
//

import Foundation
import Security

public enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus, String)
    case dataCorrupted

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status, let operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(operation) failed: \(message)"
        case .dataCorrupted:
            return "The item stored in the Keychain could not be decoded."
        }
    }
}

/// Small wrapper around the generic-password Keychain APIs. All calls are
/// synchronous (the Keychain is fast), and safe from any thread.
public enum KeychainStore {
    public static func save(_ data: Data, service: String, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus, "Updating a Keychain item")
        }

        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus, "Adding a Keychain item")
        }
    }

    public static func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, "Reading a Keychain item")
        }
        return result as? Data
    }

    public static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status, "Deleting a Keychain item")
        }
    }
}

// MARK: - Portal passwords

public enum PortalCredentialStore {
    private static let service = "com.stalkerdesk.portal-password"

    public static func savePassword(_ password: String, portalID: UUID) throws {
        if password.isEmpty {
            try deletePassword(portalID: portalID)
            return
        }
        try KeychainStore.save(Data(password.utf8), service: service, account: portalID.uuidString)
    }

    public static func password(for portalID: UUID) -> String? {
        guard let data = try? KeychainStore.read(service: service, account: portalID.uuidString),
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    public static func deletePassword(portalID: UUID) throws {
        try KeychainStore.delete(service: service, account: portalID.uuidString)
    }
}

// MARK: - Session cache

public struct CachedStalkerSession: Codable, Sendable {
    public let endpoint: String
    public let token: String
    public let cookies: [String: String]
    public let issuedAt: Date

    public init(endpoint: String, token: String, cookies: [String: String], issuedAt: Date) {
        self.endpoint = endpoint
        self.token = token
        self.cookies = cookies
        self.issuedAt = issuedAt
    }
}

public protocol StalkerSessionCaching: Sendable {
    func load(portalID: UUID) -> CachedStalkerSession?
    func save(_ session: CachedStalkerSession, portalID: UUID)
    func clear(portalID: UUID)
}

public struct KeychainStalkerSessionCache: StalkerSessionCaching {
    private let service = "com.stalkerdesk.stalker-session"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    public func load(portalID: UUID) -> CachedStalkerSession? {
        guard let data = try? KeychainStore.read(service: service, account: portalID.uuidString) else {
            return nil
        }
        return try? decoder.decode(CachedStalkerSession.self, from: data)
    }

    public func save(_ session: CachedStalkerSession, portalID: UUID) {
        guard let data = try? encoder.encode(session) else { return }
        try? KeychainStore.save(data, service: service, account: portalID.uuidString)
    }

    public func clear(portalID: UUID) {
        try? KeychainStore.delete(service: service, account: portalID.uuidString)
    }
}
