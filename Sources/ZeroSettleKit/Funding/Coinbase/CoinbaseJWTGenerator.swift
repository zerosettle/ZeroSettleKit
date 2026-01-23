import Foundation
import CryptoKit

/// Generates JWT tokens for Coinbase API authentication
struct CoinbaseJWTGenerator {

    /// Generates a JWT token for Coinbase API authentication
    /// - Parameters:
    ///   - requestMethod: HTTP method (e.g., "POST", "GET")
    ///   - requestHost: API host (e.g., "api.cdp.coinbase.com")
    ///   - requestPath: API path (e.g., "/platform/v2/onramp/orders")
    ///   - apiKeyId: Your Coinbase API key ID
    ///   - apiKeySecret: Your Coinbase API key secret (base64-encoded Ed25519 private key)
    ///   - expiresIn: Token expiration time in seconds (default: 120)
    /// - Returns: JWT token string
    static func generateJWT(
        requestMethod: String,
        requestHost: String,
        requestPath: String,
        apiKeyId: String,
        apiKeySecret: String,
        expiresIn: Int = 120
    ) throws -> String {
        // Parse the private key from the API secret (Ed25519)
        guard let privateKey = try? parsePrivateKey(from: apiKeySecret) else {
            throw JWTError.invalidPrivateKey
        }

        // Build JWT header (using EdDSA, not ES256!)
        let header = JWTHeader(
            alg: "EdDSA",
            kid: apiKeyId,
            nonce: generateNonce(),
            typ: "JWT"
        )

        // Build JWT payload
        let now = Date()
        let exp = now.addingTimeInterval(TimeInterval(expiresIn))

        let payload = JWTPayload(
            sub: apiKeyId,
            iss: "cdp",
            aud: nil,
            nbf: Int(now.timeIntervalSince1970),
            exp: Int(exp.timeIntervalSince1970),
            uris: ["\(requestMethod) \(requestHost)\(requestPath)"]
        )

        // Encode header and payload
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // Ensure consistent ordering

        let headerJSON = try encoder.encode(header)
        let payloadJSON = try encoder.encode(payload)

        let headerBase64 = headerJSON.base64URLEncodedString()
        let payloadBase64 = payloadJSON.base64URLEncodedString()

        // Create signing input
        let signingInput = "\(headerBase64).\(payloadBase64)"

        // Sign with EdDSA (Ed25519)
        guard let signingData = signingInput.data(using: .utf8) else {
            throw JWTError.encodingFailed
        }

        let signature = try privateKey.signature(for: signingData)
        let signatureBase64 = Data(signature).base64URLEncodedString()

        // Build final JWT
        let jwt = "\(signingInput).\(signatureBase64)"

        return jwt
    }

    // MARK: - Helper Methods

    /// Parse an Ed25519 private key from base64-encoded string
    private static func parsePrivateKey(from base64String: String) throws -> Curve25519.Signing.PrivateKey {
        // The secret is base64-encoded raw 32-byte Ed25519 private key
        guard let keyData = Data(base64Encoded: base64String) else {
            throw JWTError.invalidPrivateKey
        }

        // Take the first 32 bytes as the private key seed
        let privateKeyData = keyData.prefix(32)

        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        } catch {
            print("Failed to create Ed25519 private key: \(error)")
            throw JWTError.invalidPrivateKey
        }
    }

    /// Generate a random numeric nonce for JWT header
    private static func generateNonce() -> String {
        // Generate a random 16-digit number
        let nonce = Int.random(in: 1000000000000000...9999999999999999)
        return String(nonce)
    }
}

// MARK: - JWT Models

private struct JWTHeader: Codable {
    let alg: String
    let kid: String
    let nonce: String
    let typ: String
}

private struct JWTPayload: Codable {
    let sub: String
    let iss: String
    let aud: String?
    let nbf: Int
    let exp: Int
    let uris: [String]
}

// MARK: - Errors

enum JWTError: Error, LocalizedError {
    case invalidPrivateKey
    case encodingFailed
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "Invalid Coinbase private key"
        case .encodingFailed:
            return "Failed to encode JWT data"
        case .signingFailed:
            return "Failed to sign JWT"
        }
    }
}

// MARK: - Base64 URL Encoding Extension

extension Data {
    /// Base64 URL encoding (RFC 4648) - used by JWT
    func base64URLEncodedString() -> String {
        let base64 = self.base64EncodedString()
        let base64URL = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return base64URL
    }
}
