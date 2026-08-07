import Foundation

enum SmartDocumentParser {
    private static let unnamedEntryTitle = "未命名条目"

    static func parse(_ document: String, rules: ParsingRules = ParsingRules()) -> [SmartEntry] {
        var entries: [SmartEntry] = []
        var currentTitle: String?
        var currentLines: [(index: Int, raw: String)] = []

        func flush() {
            guard let title = currentTitle else {
                currentLines.removeAll()
                return
            }
            guard !currentLines.isEmpty else { return }

            let items = parseItems(from: currentLines, title: title, rules: rules)
            let startLine = currentLines.first?.index ?? entries.count
            let endLine = currentLines.last?.index ?? startLine
            entries.append(
                SmartEntry(
                    id: entryID(index: entries.count, title: title),
                    title: title,
                    items: items,
                    rawLines: currentLines.map(\.raw),
                    startLine: startLine,
                    endLine: endLine
                )
            )
            currentLines.removeAll()
        }

        for (lineIndex, rawLine) in document.components(separatedBy: .newlines).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = markdownHeading(from: trimmed), heading.level <= 2 {
                flush()
                currentTitle = heading.level == 1 ? nil : heading.title
                continue
            }

            if trimmed.isEmpty {
                if currentTitle != nil, currentLines.isEmpty {
                    continue
                }
                flush()
                currentTitle = nil
                continue
            }

            if isSeparator(trimmed) {
                flush()
                currentTitle = nil
                continue
            }

            if currentTitle == nil {
                if looksLikeItemInsteadOfTitle(trimmed, rules: rules) {
                    currentTitle = unnamedEntryTitle
                    currentLines.append((lineIndex, rawLine))
                } else {
                    currentTitle = titleFromLine(trimmed)
                }
                continue
            }

            if shouldStartNewEntry(trimmed, currentLines: currentLines, rules: rules) {
                flush()
                currentTitle = titleFromLine(trimmed)
                continue
            }

            currentLines.append((lineIndex, rawLine))
        }

        flush()
        return entries
    }

    static func searchableText(for entries: [SmartEntry]) -> String {
        entries.flatMap { entry -> [String] in
            var parts = [entry.title]
            for item in entry.items {
                parts.append(item.label)
                switch item.sensitivity {
                case .plain:
                    parts.append(item.value)
                case .redactedURL:
                    parts.append(item.displayValue)
                case .secret:
                    break
                }
            }
            return parts
        }
        .joined(separator: "\n")
    }

    private static func parseItems(
        from lines: [(index: Int, raw: String)],
        title: String,
        rules: ParsingRules
    ) -> [SmartItem] {
        var items: [SmartItem] = []
        var secretCounter = 1
        var lastVisibleAccountOrCommand = false

        for line in lines {
            let cleaned = stripLogPrefix(line.raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let sshItems = parseSSHItems(cleaned, lineIndex: line.index) {
                items.append(contentsOf: sshItems)
                lastVisibleAccountOrCommand = true
                continue
            }

            if let item = parseItem(from: line.raw, lineIndex: line.index, rules: rules) {
                items.append(item)
                lastVisibleAccountOrCommand = isVisibleAccountOrCommand(item.kind)
                continue
            }

            if looksLikeEmail(cleaned) {
                items.append(
                    SmartItem(
                        id: "item-\(line.index)-email",
                        label: "账号",
                        value: cleaned,
                        displayValue: cleaned,
                        kind: .email,
                        sensitivity: .plain,
                        sourceLine: line.index
                    )
                )
                lastVisibleAccountOrCommand = true
                continue
            }

            if looksLikeOpaqueSecret(cleaned) || lastVisibleAccountOrCommand {
                items.append(
                    SmartItem(
                        id: "item-\(line.index)-secret-\(secretCounter)",
                        label: secretCounter == 1 ? "密钥" : "密钥 \(secretCounter)",
                        value: cleaned,
                        displayValue: "已隐藏，双击复制",
                        kind: .password,
                        sensitivity: .secret,
                        sourceLine: line.index
                    )
                )
                secretCounter += 1
                lastVisibleAccountOrCommand = false
            }
        }

        return items
    }

    private static func isSeparator(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 4 else { return false }
        let separatorScalars = CharacterSet(charactersIn: "-—–_=*")
        return compact.unicodeScalars.allSatisfy { separatorScalars.contains($0) }
    }

    private static func titleFromLine(_ line: String) -> String {
        markdownHeading(from: line)?.title ?? line
    }

    private static func markdownHeading(from line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    private static func looksLikeItemInsteadOfTitle(_ line: String, rules: ParsingRules) -> Bool {
        if unwrapPrivateWrapper(line) != nil { return true }
        if DocumentParser.parseField(line, rules: rules) != nil { return true }
        if looksLikeURL(line) || looksLikeEmail(line) || looksLikeSSH(line) { return true }
        return looksLikeOpaqueSecret(line)
    }

    private static func shouldStartNewEntry(
        _ line: String,
        currentLines: [(index: Int, raw: String)],
        rules: ParsingRules
    ) -> Bool {
        guard !currentLines.isEmpty else { return false }
        if DocumentParser.parseField(line, rules: rules) != nil { return false }
        if looksLikeURL(line) || looksLikeEmail(line) || looksLikeSSH(line) { return false }
        if looksLikeOpaqueSecret(line) { return false }
        return looksLikeStandaloneTitle(line, rules: rules)
    }

    private static func looksLikeStandaloneTitle(_ line: String, rules: ParsingRules) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.customEntryTitleKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .contains { trimmed.localizedCaseInsensitiveContains($0) }
    }

    private static func looksLikeURL(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func looksLikeEmail(_ line: String) -> Bool {
        line.range(
            of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func looksLikeSSH(_ line: String) -> Bool {
        line.range(of: #"^ssh\s+\S+@\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func unwrapPrivateWrapper(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "{{"
        let suffix = "}}"
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else {
            return nil
        }

        let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSSHItems(_ line: String, lineIndex: Int) -> [SmartItem]? {
        let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, parts[0].lowercased() == "ssh" else { return nil }

        let target = String(parts[1])
        guard
            !target.contains(where: { $0.isWhitespace }),
            let atIndex = target.firstIndex(of: "@"),
            atIndex > target.startIndex
        else {
            return nil
        }

        let hostStart = target.index(after: atIndex)
        guard hostStart < target.endIndex else { return nil }

        let user = String(target[..<atIndex])
        let host = String(target[hostStart...])

        return [
            SmartItem(
                id: "item-\(lineIndex)-ssh-user",
                label: "SSH 用户",
                value: user,
                displayValue: user,
                kind: .sshUser,
                sensitivity: .plain,
                sourceLine: lineIndex
            ),
            SmartItem(
                id: "item-\(lineIndex)-ssh-host",
                label: "SSH 主机",
                value: host,
                displayValue: host,
                kind: .sshHost,
                sensitivity: .plain,
                sourceLine: lineIndex
            )
        ]
    }

    private static func looksLikeOpaqueSecret(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }
        if trimmed.contains(" ") { return false }
        if looksLikeEmail(trimmed) || looksLikeURL(trimmed) || looksLikeSSH(trimmed) { return false }
        return true
    }

    private static func isVisibleAccountOrCommand(_ kind: SmartItemKind) -> Bool {
        kind == .email || kind == .username || kind == .panelUser || kind == .sshUser || kind == .sshHost
    }

    private static func parseItem(from rawLine: String, lineIndex: Int, rules: ParsingRules) -> SmartItem? {
        let normalizedLine = stripLogPrefix(rawLine)
        let trimmedLine = normalizedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if let secret = unwrapPrivateWrapper(trimmedLine) {
            return SmartItem(
                id: "item-\(lineIndex)-private-wrapper",
                label: "密钥",
                value: secret,
                displayValue: "已隐藏，双击复制",
                kind: .password,
                sensitivity: .secret,
                sourceLine: lineIndex
            )
        }

        if looksLikeURL(trimmedLine) {
            return urlItem(label: "链接", value: trimmedLine, lineIndex: lineIndex)
        }

        let isExplicitText = hasExplicitTextTag(normalizedLine)
        guard let field = DocumentParser.parseField(normalizedLine, rules: rules) else {
            return nil
        }

        let kind = kindForField(name: field.name, fieldType: field.type, isExplicitText: isExplicitText)
        if kind == .url {
            return urlItem(label: field.name, value: field.value, lineIndex: lineIndex)
        }

        let sensitivity = sensitivityFor(label: field.name, kind: kind, fieldType: field.type)
        let displayValue = displayValueFor(value: field.value, sensitivity: sensitivity)
        return SmartItem(
            id: "item-\(lineIndex)-\(slug(field.name))",
            label: field.name,
            value: field.value,
            displayValue: displayValue,
            kind: kind,
            sensitivity: sensitivity,
            sourceLine: lineIndex
        )
    }

    private static func kindForField(name: String, fieldType: FieldType, isExplicitText: Bool = false) -> SmartItemKind {
        if isExplicitText { return .text }

        let lowerName = name.lowercased()
        if lowerName.contains("面板密码") { return .panelPassword }
        if lowerName.contains("面板用户") { return .panelUser }
        if lowerName.contains("keysecret") || lowerName.contains("secret") { return .keySecret }
        if lowerName == "key" || lowerName.contains("api key") || lowerName.contains("accesskey") { return .apiKey }
        if lowerName.contains("密码") || lowerName.contains("password") { return .password }
        if lowerName.contains("账号") || lowerName.contains("用户") || lowerName.contains("user") { return .username }
        if fieldType == .text { return .text }
        switch fieldType {
        case .url: return .url
        case .email: return .email
        case .ip: return .ip
        case .port: return .port
        case .secret: return .password
        case .text: return .text
        }
    }

    private static func hasExplicitTextTag(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasSuffix(" @text") || lower.hasSuffix(" #text")
    }

    private static func stripLogPrefix(_ rawLine: String) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return trimmed }
        let afterClose = trimmed.index(after: close)
        guard afterClose < trimmed.endIndex else { return trimmed }
        var remainder = trimmed[afterClose...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.hasPrefix(":") || remainder.hasPrefix("：") else { return trimmed }
        remainder.removeFirst()
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayValueFor(value: String, sensitivity: SmartSensitivity) -> String {
        switch sensitivity {
        case .plain:
            return value
        case .secret:
            return "已隐藏，双击复制"
        case .redactedURL:
            return safeURLDisplay(value) ?? "[已隐藏链接]"
        }
    }

    static func safeURLDisplay(_ value: String, label: String = "") -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeURL(trimmed) else { return nil }

        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme,
            ["http", "https"].contains(scheme.lowercased()),
            let host = components.host,
            !host.isEmpty
        else {
            return "[已隐藏链接]"
        }

        let renderedHost: String
        if host.hasPrefix("["), host.hasSuffix("]") {
            renderedHost = host
        } else {
            renderedHost = host.contains(":") ? "[\(host)]" : host
        }
        let port = components.port.map { ":\($0)" } ?? ""
        let baseURL = "\(scheme)://\(renderedHost)\(port)"
        let hasCredentials = components.user != nil || components.password != nil
        if hasCredentials {
            return "\(baseURL)/[已隐藏凭据]"
        }

        let hasPathOrQuery = (!components.path.isEmpty && components.path != "/")
            || !(components.query?.isEmpty ?? true)
            || !(components.fragment?.isEmpty ?? true)
        if (isIPv4Host(host) || isPanelURLLabel(label)) && hasPathOrQuery {
            return "\(baseURL)/[已隐藏路径]"
        }

        if containsSensitiveQuery(components) {
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            return "\(baseURL)\(path)?[已隐藏参数]"
        }

        if containsSensitiveFragment(components) {
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            return "\(baseURL)\(path)#[已隐藏片段]"
        }

        return trimmed
    }

    static func redactedURLs(in text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://\S+"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        var result = text
        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            guard let safeDisplay = safeURLDisplay(candidate), safeDisplay != candidate else { continue }
            result.replaceSubrange(range, with: safeDisplay)
        }

        return result
    }

    private static func urlItem(label: String, value: String, lineIndex: Int) -> SmartItem {
        let displayValue = safeURLDisplay(value, label: label) ?? "[已隐藏链接]"
        let sensitivity: SmartSensitivity = displayValue == value ? .plain : .redactedURL

        return SmartItem(
            id: "item-\(lineIndex)-\(slug(label))",
            label: label,
            value: value,
            displayValue: displayValue,
            kind: .url,
            sensitivity: sensitivity,
            sourceLine: lineIndex
        )
    }

    private static func isIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        return parts.allSatisfy { part in
            let rawPart = String(part)
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == rawPart || rawPart == "0"
        }
    }

    private static func isPanelURLLabel(_ label: String) -> Bool {
        let normalized = label.lowercased()
        return ["面板", "外部地址", "内部地址", "panel"].contains { normalized.contains($0) }
    }

    private static func containsSensitiveQuery(_ components: URLComponents) -> Bool {
        components.queryItems?.contains { isSensitiveURLParameterName($0.name) } ?? false
    }

    private static func containsSensitiveFragment(_ components: URLComponents) -> Bool {
        guard let fragment = components.fragment, !fragment.isEmpty else { return false }

        return fragment.split(separator: "&").contains { component in
            let name = component.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return isSensitiveURLParameterName(name)
        }
    }

    private static func isSensitiveURLParameterName(_ rawName: String) -> Bool {
        let sensitiveNames: Set<String> = [
            "token", "access_token", "refresh_token", "key", "api_key", "apikey",
            "accesskey", "access_key", "secret", "client_secret", "password", "pass",
            "auth", "authorization", "credential", "signature", "sig", "code"
        ]
        let sensitiveFragments = ["token", "secret", "password", "credential", "signature", "authorization"]
        let name = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveNames.contains(name) || sensitiveFragments.contains { name.contains($0) }
    }

    private static func sensitivityFor(label: String, kind: SmartItemKind, fieldType: FieldType) -> SmartSensitivity {
        if fieldType == .secret { return .secret }
        switch kind {
        case .apiKey, .keySecret, .password, .panelPassword:
            return .secret
        default:
            return .plain
        }
    }

    private static func entryID(index: Int, title: String) -> String {
        "entry-\(index)-\(slug(title))"
    }

    private static func slug(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fff}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "untitled" : normalized
    }
}
