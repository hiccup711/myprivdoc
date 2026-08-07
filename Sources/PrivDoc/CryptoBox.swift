import CommonCrypto
import CryptoKit
import Foundation
import Security

enum CryptoError: LocalizedError, Equatable {
    case invalidFormat
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case passwordRequired

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "密档文件格式无效。"
        case .keyDerivationFailed:
            return "无法从密码生成加密密钥。"
        case .encryptionFailed:
            return "无法加密密档。"
        case .decryptionFailed:
            return "无法解锁密档，请检查密码。"
        case .passwordRequired:
            return "请输入文档密码。"
        }
    }
}

struct VaultEnvelope: Codable, Sendable {
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
    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let passwordKDF = "PBKDF2-HMAC-SHA256"
    private static let systemKDF = "Keychain-Random-256"

    static func encrypt(payload: VaultPayload, password: String) throws -> Data {
        guard !password.isEmpty else { throw CryptoError.passwordRequired }

        let salt = randomData(count: saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let envelope = try makeEnvelope(
            payload: payload,
            key: key,
            authMode: .password,
            keyID: nil,
            kdf: passwordKDF,
            iterations: iterations,
            salt: salt
        )

        return try JSONEncoder.privdoc.encode(envelope)
    }

    static func encrypt(payload: VaultPayload, rawKey: Data, keyID: String) throws -> Data {
        guard rawKey.count == keyLength else { throw CryptoError.keyDerivationFailed }
        guard keyID.count == 36, UUID(uuidString: keyID) != nil else {
            throw CryptoError.invalidFormat
        }
        let envelope = try makeEnvelope(
            payload: payload,
            key: SymmetricKey(data: rawKey),
            authMode: .system,
            keyID: keyID,
            kdf: systemKDF,
            iterations: 0,
            salt: Data()
        )

        return try JSONEncoder.privdoc.encode(envelope)
    }

    static func decrypt(data: Data, password: String) throws -> VaultPayload {
        guard !password.isEmpty else { throw CryptoError.passwordRequired }
        let (envelope, mode) = try decodeAndValidate(data)
        guard mode == .password else { throw CryptoError.invalidFormat }

        let key = try deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        return try openEnvelope(envelope, key: key)
    }

    static func decrypt(data: Data, rawKey: Data) throws -> VaultPayload {
        guard rawKey.count == keyLength else { throw CryptoError.keyDerivationFailed }
        let (envelope, mode) = try decodeAndValidate(data)
        guard mode == .system else { throw CryptoError.invalidFormat }

        return try openEnvelope(envelope, key: SymmetricKey(data: rawKey))
    }

    static func inspect(data: Data) throws -> VaultAuthInfo {
        let (envelope, mode) = try decodeAndValidate(data)
        return VaultAuthInfo(mode: mode, keyID: mode == .system ? envelope.keyID : nil)
    }

    static func encryptAsync(payload: VaultPayload, password: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try encrypt(payload: payload, password: password)
        }.value
    }

    static func encryptAsync(payload: VaultPayload, rawKey: Data, keyID: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try encrypt(payload: payload, rawKey: rawKey, keyID: keyID)
        }.value
    }

    static func decryptAsync(data: Data, password: String) async throws -> VaultPayload {
        try await Task.detached(priority: .userInitiated) {
            try decrypt(data: data, password: password)
        }.value
    }

    static func decryptAsync(data: Data, rawKey: Data) async throws -> VaultPayload {
        try await Task.detached(priority: .userInitiated) {
            try decrypt(data: data, rawKey: rawKey)
        }.value
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

    private static func decodeAndValidate(_ data: Data) throws -> (VaultEnvelope, VaultAuthMode) {
        let envelope: VaultEnvelope
        do {
            envelope = try JSONDecoder.privdoc.decode(VaultEnvelope.self, from: data)
        } catch {
            throw CryptoError.invalidFormat
        }

        guard envelope.magic == magic,
              envelope.version == version,
              envelope.nonce.count == nonceLength,
              envelope.ciphertext.count >= tagLength else {
            throw CryptoError.invalidFormat
        }

        let mode: VaultAuthMode
        if let rawMode = envelope.authMode {
            guard let parsedMode = VaultAuthMode(rawValue: rawMode) else {
                throw CryptoError.invalidFormat
            }
            mode = parsedMode
        } else {
            mode = .password
        }

        switch mode {
        case .password:
            guard envelope.kdf == passwordKDF,
                  envelope.iterations == iterations,
                  envelope.salt.count == saltLength,
                  envelope.keyID == nil else {
                throw CryptoError.invalidFormat
            }
        case .system:
            guard envelope.authMode == VaultAuthMode.system.rawValue,
                  envelope.kdf == systemKDF,
                  envelope.iterations == 0,
                  envelope.salt.isEmpty,
                  let keyID = envelope.keyID,
                  keyID.count == 36,
                  UUID(uuidString: keyID) != nil else {
                throw CryptoError.invalidFormat
            }
        }

        return (envelope, mode)
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
