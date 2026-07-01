import Foundation

struct VaultPayload: Codable, Equatable {
    var currentDocument: String
    var versions: [DocumentVersion]
    var settings: AppSettings

    static let empty = VaultPayload(
        currentDocument: SampleData.document,
        versions: [
            DocumentVersion(
                id: UUID(),
                createdAt: Date(),
                summary: "初始文档",
                document: SampleData.document
            )
        ],
        settings: AppSettings()
    )
}

struct AppSettings: Codable, Equatable {
    var clipboardClearDelay: ClipboardClearDelay
    var autoLockAfterSeconds: Int

    init(
        clipboardClearDelay: ClipboardClearDelay = .seconds15,
        autoLockAfterSeconds: Int = 300
    ) {
        self.clipboardClearDelay = clipboardClearDelay
        self.autoLockAfterSeconds = autoLockAfterSeconds
    }

    enum CodingKeys: String, CodingKey {
        case clearClipboardAfterSeconds
        case clipboardClearDelay
        case autoLockAfterSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let delay = try container.decodeIfPresent(ClipboardClearDelay.self, forKey: .clipboardClearDelay) {
            clipboardClearDelay = delay
        } else {
            let legacySeconds = try container.decodeIfPresent(Int.self, forKey: .clearClipboardAfterSeconds) ?? 15
            clipboardClearDelay = ClipboardClearDelay(seconds: legacySeconds) ?? .seconds15
        }
        autoLockAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .autoLockAfterSeconds) ?? 300
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clipboardClearDelay, forKey: .clipboardClearDelay)
        try container.encode(autoLockAfterSeconds, forKey: .autoLockAfterSeconds)
    }
}

enum ClipboardClearDelay: String, Codable, CaseIterable, Identifiable, Equatable {
    case seconds5
    case seconds15
    case seconds30
    case minute1
    case minutes5
    case manual

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .seconds5: return 5
        case .seconds15: return 15
        case .seconds30: return 30
        case .minute1: return 60
        case .minutes5: return 300
        case .manual: return nil
        }
    }

    var label: String {
        switch self {
        case .seconds5: return "5 秒"
        case .seconds15: return "15 秒"
        case .seconds30: return "30 秒"
        case .minute1: return "1 分钟"
        case .minutes5: return "5 分钟"
        case .manual: return "手动清除"
        }
    }

    var copyFeedbackText: String {
        switch self {
        case .manual:
            return "已复制，剪贴板需手动清除"
        default:
            return "已复制，\(label)后清空剪贴板"
        }
    }

    init?(seconds: Int) {
        switch seconds {
        case 5: self = .seconds5
        case 15: self = .seconds15
        case 30: self = .seconds30
        case 60: self = .minute1
        case 300: self = .minutes5
        default: return nil
        }
    }
}

struct ParsingRules: Codable, Equatable {
    var customSecretKeywords: [String]
    var customPlainTextKeywords: [String]

    init(customSecretKeywords: [String] = [], customPlainTextKeywords: [String] = []) {
        self.customSecretKeywords = customSecretKeywords
        self.customPlainTextKeywords = customPlainTextKeywords
    }
}

struct DocumentVersion: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var summary: String
    var document: String
}

struct DocumentSection: Identifiable, Equatable {
    let id: String
    var title: String
    var lines: [ParsedLine]
}

struct ParsedLine: Identifiable, Equatable {
    let id: String
    var raw: String
    var kind: ParsedLineKind
}

enum ParsedLineKind: Equatable {
    case heading(String, level: Int)
    case field(Field)
    case secret(String)
    case richParagraph([TextSegment])
    case paragraph(String)
    case empty
}

struct TextSegment: Identifiable, Equatable {
    let id: String
    var text: String
    var isSecret: Bool
}

struct Field: Equatable {
    var name: String
    var value: String
    var type: FieldType
}

enum FieldType: String, Codable, Equatable {
    case text
    case secret
    case url
    case ip
    case port
    case email
}

struct DiffLine: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var before: String?
    var after: String?
    var isSecret: Bool
    var change: ChangeType
}

enum ChangeType: String, Equatable {
    case added = "新增"
    case removed = "删除"
    case changed = "变更"
}

enum AppMode: String, CaseIterable, Identifiable {
    case view = "查看"
    case edit = "编辑"
    case history = "历史"
    case rules = "规则"
    case settings = "设置"

    var id: String { rawValue }
}

enum ToastKind {
    case copied
    case saved
    case locked
    case error
}

struct ToastMessage: Identifiable {
    let id = UUID()
    var text: String
    var kind: ToastKind
}

enum VaultAuthMode: String, Codable, Equatable {
    case password
    case system
}

struct VaultAuthInfo: Equatable {
    var mode: VaultAuthMode
    var keyID: String?
}

enum SampleData {
    static let document = """
    # 我的隐私文档

    ## 服务器 / prod-01

    服务器IP：1.2.3.4
    SSH用户：root
    SSH端口：22
    服务器登录密码：{{replace-me-password}}
    OnePanel地址：https://example.com:8443
    OnePanel账号：admin
    OnePanel密码：replace-me-panel-password @secret
    备注：主站生产服务器
    Public Key：ssh-rsa AAAA-example-public-key @text

    ## API Key

    OpenAI API Key：{{sk-replace-me-with-real-key}}
    GitHub Token：ghp_replace_me_with_real_token @secret

    这是一段正文，里面有一小段需要隐藏：{{不想展示的内容}}，其他文字保持原样。

    ## 数据库 / prod

    数据库地址：127.0.0.1
    数据库端口：3306
    数据库用户：app
    数据库密码：replace-me-db-password
    """
}
