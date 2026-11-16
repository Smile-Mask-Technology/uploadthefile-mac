public import Foundation
import Security

/// What we keep per site origin after sign-in.
public struct StoredCredentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var clientId: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, clientId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientId = clientId
    }

    /// Never prints token material.
    public var description: String { "StoredCredentials(clientId: \(clientId), expiresAt: \(expiresAt), tokens: <redacted>)" }
    public var debugDescription: String { description }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> StoredCredentials {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredCredentials.self, from: data)
    }
}

/// Persistence for ``StoredCredentials``, keyed by site origin.
public protocol TokenStore: Sendable {
    func load(origin: String) throws -> StoredCredentials?
    /// Must replace any existing value atomically.
    func save(_ credentials: StoredCredentials, origin: String) throws
    func delete(origin: String) throws
}

/// Keeps credentials in the login Keychain as a generic password item
/// (service `com.smilemasktechnology.uploadthefile`, account = site origin).
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "com.smilemasktechnology.uploadthefile"
    public let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    private func query(origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin,
        ]
    }

    public func load(origin: String) throws -> StoredCredentials? {
        var q = query(origin: origin)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.error("read", status)
        }
        do {
            return try StoredCredentials.decode(data)
        } catch {
            throw UptfError.unexpected("The saved sign-in could not be read. Sign in again.")
        }
    }

    public func save(_ credentials: StoredCredentials, origin: String) throws {
        let data = try credentials.encoded()
        let update = SecItemUpdate(
            query(origin: origin) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(origin: origin)
            add[kSecValueData as String] = data
            // Only the data-protection keychain (not used here, it needs a provisioning profile)
            // honours this attribute; the file-based login keychain ignores it. It is kept for a
            // later move to the data-protection keychain, and gives no protection today.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Upload the File (\(origin))"
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Self.error("save", status) }
        default:
            throw Self.error("update", update)
        }
    }

    public func delete(origin: String) throws {
        let status = SecItemDelete(query(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error("delete", status)
        }
    }

    private static func error(_ action: String, _ status: OSStatus) -> UptfError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .unexpected("Keychain \(action) failed: \(text)")
    }
}

/// A store that lives only in memory. For tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: StoredCredentials]

    public init(_ items: [String: StoredCredentials] = [:]) {
        self.items = items
    }

    public func load(origin: String) throws -> StoredCredentials? {
        lock.lock(); defer { lock.unlock() }
        return items[origin]
    }

    public func save(_ credentials: StoredCredentials, origin: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[origin] = credentials
    }

    public func delete(origin: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[origin] = nil
    }
}

/// Remembers the OAuth `client_id` we registered with each site, in a plain JSON file
/// (`oauth-clients.json` in the app's Application Support folder). It is not a secret.
public struct ClientRegistrationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func standard() throws -> ClientRegistrationStore {
        ClientRegistrationStore(fileURL: try AppSupport.directory().appendingPathComponent("oauth-clients.json"))
    }

    private struct File: Codable {
        var clients: [String: String] = [:]
    }

    private func read() -> File {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return File() }
        return file
    }

    public func clientId(origin: String) -> String? {
        read().clients[origin]
    }

    public func save(clientId: String, origin: String) throws {
        var file = read()
        file.clients[origin] = clientId
        try write(file)
    }

    public func forget(origin: String) throws {
        var file = read()
        file.clients[origin] = nil
        try write(file)
    }

    private func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }
}
