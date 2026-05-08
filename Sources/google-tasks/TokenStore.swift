import Foundation
import Security

struct OAuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

protocol TokenStoring: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func delete() throws
}

struct KeychainTokenStore: TokenStoring {
    private let service = "dev.yuri.google-tasks"
    private let account = "google-oauth"

    func load() throws -> OAuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandled(status)
        }
        return try JSONDecoder.googleTasks.decode(OAuthTokens.self, from: data)
    }

    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder.googleTasks.encode(tokens)
        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError, Equatable {
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unhandled(status):
            "Keychain falhou com status \(status)."
        }
    }
}
