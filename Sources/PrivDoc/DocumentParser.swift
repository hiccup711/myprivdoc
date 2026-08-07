import Foundation

enum DocumentParser {
    static let implicitSectionTitle = "正文"

    static let builtInSecretKeywords = [
        "密码", "密钥", "秘钥", "token", "secret", "api key", "apikey",
        "private key", "access token", "refresh token", "cookie", "恢复码",
        "key", "pass", "password", "credential", "client_secret", "client secret",
        "ssh key", "授权码"
    ]

    static let builtInPlainTextKeywords = [
        "备注", "说明", "描述", "note", "comment"
    ]

    static func parse(_ document: String, rules: ParsingRules = ParsingRules()) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        var currentTitle = implicitSectionTitle
        var currentLines: [ParsedLine] = []

        func flushCurrentSection() {
            let lines = trimmedEmptyEdges(currentLines)
            currentLines.removeAll()

            guard lines.contains(where: { !isEmptyLine($0) }) else { return }

            sections.append(
                DocumentSection(
                    id: sectionID(index: sections.count, title: currentTitle),
                    title: currentTitle,
                    lines: lines
                )
            )
        }

        for (lineIndex, rawLine) in document.components(separatedBy: .newlines).enumerated() {
            let parsed = parseLine(rawLine, lineIndex: lineIndex, rules: rules)
            if case let .heading(title, level) = parsed.kind {
                if level == 1 {
                    continue
                }

                if level == 2 {
                    flushCurrentSection()
                    currentTitle = title
                    continue
                }

                currentLines.append(parsed)
            } else {
                currentLines.append(parsed)
            }
        }

        flushCurrentSection()

        return sections
    }

    static func documentTitle(_ document: String) -> String? {
        for rawLine in document.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }

            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            guard hashes == 1 else { continue }

            let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return title
            }
        }

        return nil
    }

    static func parseLine(_ rawLine: String, lineIndex: Int = 0, rules: ParsingRules = ParsingRules()) -> ParsedLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .empty)
        }

        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .heading(title, level: hashes))
            }
        }

        if let field = parseField(rawLine, rules: rules) {
            return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .field(field))
        }

        if let secret = unwrapPrivateWrapper(trimmed), privateWrapperRanges(in: trimmed).count == 1 {
            return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .secret(secret))
        }

        let segments = parseTextSegments(rawLine, lineIndex: lineIndex)
        if segments.contains(where: \.isSecret) {
            return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .richParagraph(segments))
        }

        return ParsedLine(id: "line-\(lineIndex)", raw: rawLine, kind: .paragraph(rawLine))
    }

    static func parseField(_ rawLine: String, rules: ParsingRules = ParsingRules()) -> Field? {
        guard let separator = firstFieldSeparator(in: rawLine) else { return nil }

        let key = rawLine[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let rawValue = String(rawLine[separator.upperBound...].trimmingCharacters(in: .whitespaces))
        let valueAnnotation = parseValueAnnotation(rawValue)

        guard !key.isEmpty, !valueAnnotation.value.isEmpty, key.count <= 80 else { return nil }

        return Field(
            name: key,
            value: valueAnnotation.value,
            type: inferType(
                name: String(key),
                value: valueAnnotation.value,
                rules: rules,
                explicitType: valueAnnotation.explicitType
            )
        )
    }

    static func inferType(
        name: String,
        value: String,
        rules: ParsingRules = ParsingRules(),
        explicitType: FieldType? = nil
    ) -> FieldType {
        if let explicitType {
            return explicitType
        }

        let lowerName = name.lowercased()
        let lowerValue = value.lowercased()

        if matchesAny(lowerName, keywords: rules.customPlainTextKeywords + builtInPlainTextKeywords) {
            return .text
        }

        if matchesAny(lowerName, keywords: rules.customSecretKeywords + builtInSecretKeywords) {
            return .secret
        }

        if lowerValue.hasPrefix("http://") || lowerValue.hasPrefix("https://") {
            return .url
        }

        if value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return .ip
        }

        if value.range(of: #"^\d{2,5}$"#, options: .regularExpression) != nil, lowerName.contains("端口") || lowerName.contains("port") {
            return .port
        }

        if value.range(of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .email
        }

        if looksLikeSecretValue(value), lowerName.contains("key") || lowerName.contains("token") {
            return .secret
        }

        return .text
    }

    private static func looksLikeSecretValue(_ value: String) -> Bool {
        if value.count < 24 { return false }
        let compact = value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        let allowed = CharacterSet.alphanumerics
        return compact.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseValueAnnotation(_ rawValue: String) -> (value: String, explicitType: FieldType?) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        let tagParsed = parseTrailingTag(trimmed)
        let unwrapped = unwrapPrivateWrapper(tagParsed.value)

        if let secret = unwrapped {
            return (secret, .secret)
        }

        let segments = parseTextSegments(tagParsed.value, lineIndex: 0)
        if segments.contains(where: \.isSecret) {
            return (segments.map(\.text).joined(), .secret)
        }

        return (tagParsed.value, tagParsed.explicitType)
    }

    private static func parseTrailingTag(_ value: String) -> (value: String, explicitType: FieldType?) {
        let markers: [(String, FieldType)] = [
            (" @secret", .secret),
            (" #secret", .secret),
            (" @text", .text),
            (" #text", .text)
        ]

        for (marker, type) in markers {
            if value.lowercased().hasSuffix(marker) {
                let end = value.index(value.endIndex, offsetBy: -marker.count)
                return (String(value[..<end]).trimmingCharacters(in: .whitespaces), type)
            }
        }

        return (value, nil)
    }

    private static func unwrapPrivateWrapper(_ value: String) -> String? {
        let prefix = "{{"
        let suffix = "}}"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else {
            return nil
        }

        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(value[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTextSegments(_ text: String, lineIndex: Int) -> [TextSegment] {
        var segments: [TextSegment] = []
        var cursor = text.startIndex
        var segmentIndex = 0

        for range in privateWrapperRanges(in: text) {
            if cursor < range.lowerBound {
                segments.append(
                    TextSegment(
                        id: "line-\(lineIndex)-segment-\(segmentIndex)",
                        text: String(text[cursor..<range.lowerBound]),
                        isSecret: false
                    )
                )
                segmentIndex += 1
            }

            let contentStart = text.index(range.lowerBound, offsetBy: 2)
            let contentEnd = text.index(range.upperBound, offsetBy: -2)
            segments.append(
                TextSegment(
                    id: "line-\(lineIndex)-segment-\(segmentIndex)",
                    text: String(text[contentStart..<contentEnd]),
                    isSecret: true
                )
            )
            segmentIndex += 1
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            segments.append(
                TextSegment(
                    id: "line-\(lineIndex)-segment-\(segmentIndex)",
                    text: String(text[cursor..<text.endIndex]),
                    isSecret: false
                )
            )
        }

        return segments.isEmpty ? [TextSegment(id: "line-\(lineIndex)-segment-0", text: text, isSecret: false)] : segments
    }

    private static func privateWrapperRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let start = text[cursor...].range(of: "{{"),
              let end = text[start.upperBound...].range(of: "}}") {
            let content = text[start.upperBound..<end.lowerBound]
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranges.append(start.lowerBound..<end.upperBound)
            }
            cursor = end.upperBound
        }

        return ranges
    }

    private static func matchesAny(_ text: String, keywords: [String]) -> Bool {
        keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .contains { text.contains($0) }
    }

    private static func isEmptyLine(_ line: ParsedLine) -> Bool {
        if case .empty = line.kind {
            return true
        }
        return false
    }

    private static func trimmedEmptyEdges(_ lines: [ParsedLine]) -> [ParsedLine] {
        var start = lines.startIndex
        var end = lines.endIndex

        while start < end, isEmptyLine(lines[start]) {
            start = lines.index(after: start)
        }

        while start < end, isEmptyLine(lines[lines.index(before: end)]) {
            end = lines.index(before: end)
        }

        return Array(lines[start..<end])
    }

    private static func sectionID(index: Int, title: String) -> String {
        let normalized = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\u{4e00}-\u{9fff}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "section-\(index)-\(normalized)"
    }

    static func searchableText(for sections: [DocumentSection], includeSecrets: Bool = false) -> String {
        sections.flatMap(\.lines).compactMap { line in
            switch line.kind {
            case let .heading(title, _):
                return title
            case let .field(field):
                return includeSecrets || field.type != .secret ? "\(field.name) \(field.value)" : field.name
            case .secret:
                return nil
            case let .richParagraph(segments):
                return segments.filter { !$0.isSecret }.map(\.text).joined()
            case let .paragraph(text):
                return text
            case .empty:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    static func redactedDocument(_ document: String, rules: ParsingRules = ParsingRules()) -> String {
        document.components(separatedBy: .newlines).map { rawLine in
            if unwrapPrivateWrapper(rawLine.trimmingCharacters(in: .whitespaces)) != nil {
                return "[已隐藏]"
            }

            let segments = parseTextSegments(rawLine, lineIndex: 0)
            if segments.contains(where: \.isSecret) {
                return segments.map { $0.isSecret ? "[已隐藏]" : $0.text }.joined()
            }

            guard let field = parseField(rawLine, rules: rules), field.type == .secret else {
                return rawLine
            }

            let separator = firstFieldSeparator(in: rawLine)
            guard let separator else {
                return "\(field.name)：[已隐藏]"
            }

            return "\(rawLine[..<separator.upperBound]) [已隐藏]"
        }
        .joined(separator: "\n")
    }

    static func explicitSecretValues(in document: String) -> [String] {
        document.components(separatedBy: .newlines).flatMap { rawLine in
            parseTextSegments(rawLine, lineIndex: 0)
                .filter(\.isSecret)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private static func firstFieldSeparator(in line: String) -> Range<String.Index>? {
        ["：", ":", "="]
            .compactMap { line.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }
}
