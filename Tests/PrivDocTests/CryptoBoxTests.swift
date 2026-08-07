import Foundation
import XCTest
@testable import PrivDoc

final class CryptoBoxTests: XCTestCase {
    private let password = "test-password"
    private let keyID = "123E4567-E89B-12D3-A456-426614174000"

    func testPasswordRoundTrip() throws {
        let payload = makePayload()

        let encrypted = try CryptoBox.encrypt(payload: payload, password: password)
        let decrypted = try CryptoBox.decrypt(data: encrypted, password: password)

        XCTAssertEqual(decrypted, payload)
        XCTAssertEqual(try CryptoBox.inspect(data: encrypted), VaultAuthInfo(mode: .password, keyID: nil))
    }

    func testSystemRoundTrip() throws {
        let payload = makePayload()
        let key = Data((0..<32).map(UInt8.init))

        let encrypted = try CryptoBox.encrypt(payload: payload, rawKey: key, keyID: keyID)
        let decrypted = try CryptoBox.decrypt(data: encrypted, rawKey: key)

        XCTAssertEqual(decrypted, payload)
        XCTAssertEqual(try CryptoBox.inspect(data: encrypted), VaultAuthInfo(mode: .system, keyID: keyID))
    }

    func testLegacyPasswordEnvelopeWithoutAuthModeStillDecrypts() throws {
        var envelope = try makePasswordEnvelope()
        envelope.authMode = nil
        let data = try encode(envelope)

        XCTAssertEqual(try CryptoBox.inspect(data: data).mode, .password)
        XCTAssertEqual(try CryptoBox.decrypt(data: data, password: password), makePayload())
    }

    func testUnknownAuthModeIsRejected() throws {
        var envelope = try makePasswordEnvelope()
        envelope.authMode = "future-mode"

        assertCryptoError(.invalidFormat) {
            _ = try CryptoBox.inspect(data: encode(envelope))
        }
    }

    func testPasswordEnvelopeRejectsInvalidKDFParametersBeforeDerivation() throws {
        let original = try makePasswordEnvelope()
        var envelopes: [VaultEnvelope] = []

        var wrongKDF = original
        wrongKDF.kdf = "PBKDF2-HMAC-SHA1"
        envelopes.append(wrongKDF)

        var wrongIterations = original
        wrongIterations.iterations = 310_001
        envelopes.append(wrongIterations)

        var excessiveIterations = original
        excessiveIterations.iterations = UInt32.max
        envelopes.append(excessiveIterations)

        var wrongSalt = original
        wrongSalt.salt = Data(repeating: 0, count: 15)
        envelopes.append(wrongSalt)

        var unexpectedKeyID = original
        unexpectedKeyID.keyID = keyID
        envelopes.append(unexpectedKeyID)

        for envelope in envelopes {
            assertCryptoError(.invalidFormat) {
                _ = try CryptoBox.inspect(data: encode(envelope))
            }
        }
    }

    func testSystemEnvelopeRejectsInvalidMetadata() throws {
        let original = try makeSystemEnvelope()
        var envelopes: [VaultEnvelope] = []

        var wrongKDF = original
        wrongKDF.kdf = "PBKDF2-HMAC-SHA256"
        envelopes.append(wrongKDF)

        var wrongIterations = original
        wrongIterations.iterations = 1
        envelopes.append(wrongIterations)

        var unexpectedSalt = original
        unexpectedSalt.salt = Data([1])
        envelopes.append(unexpectedSalt)

        var missingKeyID = original
        missingKeyID.keyID = nil
        envelopes.append(missingKeyID)

        var invalidKeyID = original
        invalidKeyID.keyID = "not-a-uuid"
        envelopes.append(invalidKeyID)

        for envelope in envelopes {
            assertCryptoError(.invalidFormat) {
                _ = try CryptoBox.inspect(data: encode(envelope))
            }
        }
    }

    func testInvalidNonceAndCiphertextLengthsAreRejectedAsFormatErrors() throws {
        let original = try makePasswordEnvelope()
        var envelopes: [VaultEnvelope] = []

        var shortNonce = original
        shortNonce.nonce = Data(repeating: 0, count: 11)
        envelopes.append(shortNonce)

        var longNonce = original
        longNonce.nonce = Data(repeating: 0, count: 13)
        envelopes.append(longNonce)

        var shortCiphertext = original
        shortCiphertext.ciphertext = Data(repeating: 0, count: 15)
        envelopes.append(shortCiphertext)

        for envelope in envelopes {
            assertCryptoError(.invalidFormat) {
                _ = try CryptoBox.inspect(data: encode(envelope))
            }
        }
    }

    func testMalformedJSONIsReportedAsInvalidFormat() {
        assertCryptoError(.invalidFormat) {
            _ = try CryptoBox.inspect(data: Data("not-json".utf8))
        }
    }

    func testWrongPasswordAndTamperedCiphertextFailAuthentication() throws {
        let encrypted = try CryptoBox.encrypt(payload: makePayload(), password: password)

        assertCryptoError(.decryptionFailed) {
            _ = try CryptoBox.decrypt(data: encrypted, password: "wrong-password")
        }

        var envelope = try decode(encrypted)
        envelope.ciphertext[envelope.ciphertext.startIndex] ^= 0x01
        assertCryptoError(.decryptionFailed) {
            _ = try CryptoBox.decrypt(data: encode(envelope), password: password)
        }
    }

    func testDecryptAPIsRejectTheOtherAuthMode() throws {
        let passwordData = try CryptoBox.encrypt(payload: makePayload(), password: password)
        let rawKey = Data(repeating: 7, count: 32)
        let systemData = try CryptoBox.encrypt(payload: makePayload(), rawKey: rawKey, keyID: keyID)

        assertCryptoError(.invalidFormat) {
            _ = try CryptoBox.decrypt(data: passwordData, rawKey: rawKey)
        }
        assertCryptoError(.invalidFormat) {
            _ = try CryptoBox.decrypt(data: systemData, password: password)
        }
    }

    func testSystemWriterRejectsNonUUIDKeyID() {
        assertCryptoError(.invalidFormat) {
            _ = try CryptoBox.encrypt(
                payload: makePayload(),
                rawKey: Data(repeating: 1, count: 32),
                keyID: "not-a-uuid"
            )
        }
    }

    private func makePayload() -> VaultPayload {
        VaultPayload(
            currentDocument: "# Test\n\nPassword: {{secret}}",
            versions: [
                DocumentVersion(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    summary: "Initial",
                    document: "# Test\n\nPassword: {{secret}}"
                )
            ],
            settings: AppSettings()
        )
    }

    private func makePasswordEnvelope() throws -> VaultEnvelope {
        try decode(CryptoBox.encrypt(payload: makePayload(), password: password))
    }

    private func makeSystemEnvelope() throws -> VaultEnvelope {
        try decode(
            CryptoBox.encrypt(
                payload: makePayload(),
                rawKey: Data(repeating: 7, count: 32),
                keyID: keyID
            )
        )
    }

    private func encode(_ envelope: VaultEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    private func decode(_ data: Data) throws -> VaultEnvelope {
        try JSONDecoder().decode(VaultEnvelope.self, from: data)
    }

    private func assertCryptoError(
        _ expected: CryptoError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let actual = error as? CryptoError else {
                return XCTFail("Expected CryptoError, got \(error)", file: file, line: line)
            }

            switch (expected, actual) {
            case (.invalidFormat, .invalidFormat),
                 (.keyDerivationFailed, .keyDerivationFailed),
                 (.encryptionFailed, .encryptionFailed),
                 (.decryptionFailed, .decryptionFailed),
                 (.passwordRequired, .passwordRequired):
                break
            default:
                XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
            }
        }
    }
}
