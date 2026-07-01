import CommonCrypto
import CryptoKit
import Foundation
import Security

enum CryptoError: LocalizedError {
    case invalidFormat
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The vault file format is invalid."
        case .keyDerivationFailed:
            return "Could not derive an encryption key from the password."
        case .encryptionFailed:
            return "Could not encrypt the vault."
        case .decryptionFailed:
            return "Could not unlock the vault. Check the password."
        case .passwordRequired:
            return "A master password is required."
        }
    }
}

struct VaultEnvelope: Codable {
    var magic: String
    var version: Int
    var authMode: String?
    var keyID: String?
    var kdf: String
    var iterations: UInt32
    var salt: Data
    var nonce: Data
    var ciphertext: Data
}

enum CryptoBox {
    private static let magic = "PRIVDOC"
    private static let version = 1
    private static let iterations: UInt32 = 310_000
    private static let keyLength = 32

    static func encrypt(payload: VaultPayload, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.passwordRequired }

        let salt = randomData(count: 16)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let envelope = try makeEnvelope(
            payload: payload,
            key: key,
            authMode: .password,
            keyID: nil,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt
        )

        return try JSONEncoder.privdoc.encode(envelope)
    }

    static func encrypt(payload: VaultPayload, rawKey: Data, keyID: String) throws -> Data {
        guard rawKey.count == keyLength else { throw CryptoError.keyDerivationFailed }
        let envelope = try makeEnvelope(
            payload: payload,
            key: SymmetricKey(data: rawKey),
            authMode: .system,
            keyID: keyID,
            kdf: "Keychain-Random-256",
            iterations: 0,
            salt: Data()
        )

        return try JSONEncoder.privdoc.encode(envelope)
    }

    static func decrypt(data: Data, password: String) throws -> VaultPayload {
        guard !password.isEmpty else { throw CryptoError.passwordRequired }
        let envelope = try JSONDecoder.privdoc.decode(VaultEnvelope.self, from: data)
        guard envelope.magic == magic, envelope.version == version else {
            throw CryptoError.invalidFormat
        }

        let mode = VaultAuthMode(rawValue: envelope.authMode ?? VaultAuthMode.password.rawValue) ?? .password
        guard mode == .password else { throw CryptoError.invalidFormat }

        let key = try deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        return try openEnvelope(envelope, key: key)
    }

    static func decrypt(data: Data, rawKey: Data) throws -> VaultPayload {
        guard rawKey.count == keyLength else { throw CryptoError.keyDerivationFailed }
        let envelope = try JSONDecoder.privdoc.decode(VaultEnvelope.self, from: data)
        guard envelope.magic == magic, envelope.version == version else {
            throw CryptoError.invalidFormat
        }
        let mode = VaultAuthMode(rawValue: envelope.authMode ?? VaultAuthMode.password.rawValue) ?? .password
        guard mode == .system else { throw CryptoError.invalidFormat }

        return try openEnvelope(envelope, key: SymmetricKey(data: rawKey))
    }

    static func inspect(data: Data) throws -> VaultAuthInfo {
        let envelope = try JSONDecoder.privdoc.decode(VaultEnvelope.self, from: data)
        guard envelope.magic == magic, envelope.version == version else {
            throw CryptoError.invalidFormat
        }

        let mode = VaultAuthMode(rawValue: envelope.authMode ?? VaultAuthMode.password.rawValue) ?? .password
        return VaultAuthInfo(mode: mode, keyID: envelope.keyID)
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw CryptoError.keyDerivationFailed
        }

        var derived = Data(repeating: 0, count: keyLength)
        let result = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }

        return SymmetricKey(data: derived)
    }

    private static func makeEnvelope(
        payload: VaultPayload,
        key: SymmetricKey,
        authMode: VaultAuthMode,
        keyID: String?,
        kdf: String,
        iterations: UInt32,
        salt: Data
    ) throws -> VaultEnvelope {
        let plaintext = try JSONEncoder.privdoc.encode(payload)
        let sealed = try AES.GCM.seal(plaintext, using: key)

        guard let nonceData = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?,
              let combined = sealed.combined,
              combined.count > nonceData.count else {
            throw CryptoError.encryptionFailed
        }

        return VaultEnvelope(
            magic: magic,
            version: version,
            authMode: authMode.rawValue,
            keyID: keyID,
            kdf: kdf,
            iterations: iterations,
            salt: salt,
            nonce: nonceData,
            ciphertext: Data(combined.dropFirst(nonceData.count))
        )
    }

    private static func openEnvelope(_ envelope: VaultEnvelope, key: SymmetricKey) throws -> VaultPayload {
        let combined = envelope.nonce + envelope.ciphertext

        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder.privdoc.decode(VaultPayload.self, from: plaintext)
        } catch {
            throw CryptoError.decryptionFailed
        }
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }
}

private extension JSONEncoder {
    static var privdoc: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var privdoc: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func +(lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
