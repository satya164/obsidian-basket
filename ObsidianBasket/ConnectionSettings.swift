import CryptoKit
import Foundation
import Security

struct ConnectionSettings: Codable, Equatable {
    var server = ""
    var database = ""
    var username = ""
    var notePath = "Basket.md"
    var caseSensitivePaths = false

    var isConfigured: Bool {
        !server.isEmpty && !database.isEmpty && !username.isEmpty
    }

    var credentialKey: String {
        "\(server)/\(database)|\(username)"
    }

    var cacheKey: String {
        SHA256.hash(data: Data("\(credentialKey)|\(notePath)|\(caseSensitivePaths)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    var documentID: String {
        let path = caseSensitivePaths ? notePath : notePath.lowercased()
        return path.hasPrefix("_") ? "/" + path : path
    }

    func validated() throws -> ConnectionSettings {
        var settings = self
        settings.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while settings.server.hasSuffix("/") {
            settings.server.removeLast()
        }
        settings.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.notePath = notePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: settings.server) else {
            throw ObsidianBasketError.message(
                String(localized: .serverAddressRequired))
        }
        guard url.scheme == "https" else {
            throw ObsidianBasketError.message(
                String(localized: .httpsRequired))
        }
        guard let host = url.host, !host.isEmpty, url.url != nil else {
            throw ObsidianBasketError.message(
                String(localized: .serverHostRequired))
        }
        guard url.user == nil, url.password == nil else {
            throw ObsidianBasketError.message(
                String(localized: .serverCredentialsNotAllowed))
        }
        guard url.query == nil else {
            throw ObsidianBasketError.message(String(localized: .serverQueryNotAllowed))
        }
        guard url.fragment == nil else {
            throw ObsidianBasketError.message(String(localized: .serverFragmentNotAllowed))
        }
        guard !settings.database.isEmpty else {
            throw ObsidianBasketError.message(String(localized: .databaseRequired))
        }
        guard let first = settings.database.first, first >= "a", first <= "z" else {
            throw ObsidianBasketError.message(
                String(localized: .databaseInitialLetter))
        }
        guard settings.database.range(of: "^[a-z][a-z0-9_$()+/-]*$", options: .regularExpression) != nil
        else {
            throw ObsidianBasketError.message(
                String(localized: .databaseAllowedCharacters)
            )
        }
        guard !settings.username.isEmpty, !settings.username.contains(":"),
            !settings.username.contains(where: { $0.isNewline })
        else {
            throw ObsidianBasketError.message(String(localized: .usernameRequired))
        }
        guard !settings.notePath.isEmpty else {
            throw ObsidianBasketError.message(
                String(localized: .notePathRequired))
        }
        guard !settings.notePath.contains(where: { $0.isNewline }) else {
            throw ObsidianBasketError.message(String(localized: .notePathLineBreaks))
        }
        guard !settings.notePath.contains("\\") else {
            throw ObsidianBasketError.message(String(localized: .notePathSlashes))
        }
        guard !settings.notePath.contains(":") else {
            throw ObsidianBasketError.message(String(localized: .notePathColons))
        }
        let components = settings.notePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else {
            throw ObsidianBasketError.message(
                String(localized: .notePathEmptySegments)
            )
        }
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ObsidianBasketError.message(String(localized: .notePathRelativeSegments))
        }
        guard settings.notePath.hasSuffix(".md") else {
            throw ObsidianBasketError.message(
                String(localized: .notePathExtension))
        }
        return settings
    }
}

enum ObsidianBasketError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case message(String)
    case http(Int)

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let message):
            return "\(message)"
        case .http(let status):
            let message: String
            switch status {
            case 400:
                message = String(localized: .httpBadRequest)
            case 401:
                message = String(localized: .httpUnauthorized)
            case 403:
                message =
                    String(localized: .httpForbidden)
            case 404:
                message = String(localized: .httpNotFound)
            case 405:
                message =
                    String(localized: .httpMethodNotAllowed)
            case 408, 504:
                message = String(localized: .httpTimeout)
            case 409:
                message = String(localized: .httpConflict)
            case 413:
                message =
                    String(localized: .httpPayloadTooLarge)
            case 415:
                message =
                    String(localized: .httpUnsupportedFormat)
            case 429:
                message = String(localized: .httpTooManyRequests)
            case 500...599:
                message = String(localized: .httpServerError)
            default:
                message =
                    String(localized: .httpRequestFailed)
            }
            return .httpErrorDetails(message, status)
        }
    }
}

enum CredentialStore {
    static func password(for settings: ConnectionSettings) throws -> String {
        var query = query(for: settings)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            throw ObsidianBasketError.message(String(localized: .keychainReadFailed(Int(status))))
        }
        return password
    }

    static func removePassword(for settings: ConnectionSettings) throws {
        let status = SecItemDelete(query(for: settings) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ObsidianBasketError.message(String(localized: .keychainRemoveFailed(Int(status))))
        }
    }

    static func save(password: String, for settings: ConnectionSettings) throws {
        let query = query(for: settings)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ObsidianBasketError.message(
                    String(localized: .keychainSaveFailed(Int(addStatus))))
            }
        } else if status != errSecSuccess {
            throw ObsidianBasketError.message(String(localized: .keychainUpdateFailed(Int(status))))
        }
    }

    private static func query(for settings: ConnectionSettings) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "org.example.obsidian-basket",
            kSecAttrAccount as String: settings.credentialKey,
        ]
    }
}
