import Foundation

struct SmartEntry: Identifiable, Equatable {
    let id: String
    var title: String
    var items: [SmartItem]
    var rawLines: [String]
    var startLine: Int
    var endLine: Int
}

struct SmartItem: Identifiable, Equatable {
    let id: String
    var label: String
    var value: String
    var displayValue: String
    var kind: SmartItemKind
    var sensitivity: SmartSensitivity
    var sourceLine: Int

    var isHidden: Bool {
        sensitivity != .plain
    }

    var canOpen: Bool {
        kind == .url
    }
}

enum SmartItemKind: String, Codable, Equatable {
    case text
    case url
    case email
    case username
    case password
    case apiKey
    case keySecret
    case sshHost
    case sshUser
    case ip
    case port
    case panelUser
    case panelPassword
    case note
}

enum SmartSensitivity: String, Codable, Equatable {
    case plain
    case secret
    case redactedURL
}
