import Foundation
import LocalAuthentication
import Security

enum KeychainVaultKeyError: LocalizedError {
    case accessControlFailed
    case randomFailed
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .accessControlFailed:
            return "无法创建 macOS 钥匙串访问控制。"
        case .randomFailed:
            return "无法生成随机密档密钥。"
        case let .saveFailed(status):
            if status == -34018 {
                return "无法写入钥匙串：当前 App 缺少 Keychain 权限。请改用“文档密码”，或用 Xcode/正式签名版本运行。"
            }
            return "无法把密档密钥保存到钥匙串。状态码：\(status)"
        case let .loadFailed(status):
            if status == -34018 {
                return "无法读取钥匙串：当前 App 缺少 Keychain 权限。"
            }
            return "无法从钥匙串读取密档密钥。状态码：\(status)"
        case .missingKey:
            return "这个密档使用系统授权保存，但当前 Mac 找不到对应的钥匙串密钥。"
        }
    }
}

enum KeychainVaultKeyStore {
    private static let service = "local.privdoc.vault-key"

    static func authorize(reason: String) async throws {
        let context = LAContext()
        context.localizedReason = reason
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error {
                throw error
            }
            throw KeychainVaultKeyError.accessControlFailed
        }

        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    static func generateKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainVaultKeyError.randomFailed }
        return Data(bytes)
    }

    static func saveKey(_ key: Data, keyID: String) throws {
        deleteKey(keyID: keyID)

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            throw KeychainVaultKeyError.accessControlFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
            kSecValueData as String: key,
            kSecAttrAccessControl as String: accessControl
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainVaultKeyError.saveFailed(status) }
    }

    static func loadKey(keyID: String, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainVaultKeyError.missingKey
            }
            throw KeychainVaultKeyError.loadFailed(status)
        }

        guard let data = item as? Data else { throw KeychainVaultKeyError.missingKey }
        return data
    }

    static func deleteKey(keyID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID
        ]
        SecItemDelete(query as CFDictionary)
    }
}
