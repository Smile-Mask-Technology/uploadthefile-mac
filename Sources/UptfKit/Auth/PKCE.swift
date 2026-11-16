import CryptoKit
import Foundation
import Security

/// base64url without padding (RFC 4648 §5), as PKCE requires.
enum Base64URL {
    static func encode(_ data: some Sequence<UInt8>) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SecureRandom {
    static func bytes(count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            throw UptfError.unexpected("Could not generate random bytes (OSStatus \(status)).")
        }
        return buffer
    }
}

/// A PKCE code verifier and its S256 challenge (RFC 7636).
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    /// Wraps an existing verifier (43–128 unreserved characters).
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// A fresh verifier from 32 random bytes (43 characters).
    public static func generate() throws -> PKCE {
        PKCE(verifier: Base64URL.encode(try SecureRandom.bytes(count: 32)))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`.
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256.hash(data: Data(verifier.utf8)))
    }

    /// A random `state` value for CSRF protection.
    public static func generateState() throws -> String {
        Base64URL.encode(try SecureRandom.bytes(count: 24))
    }
}
