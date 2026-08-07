import Foundation

enum DiffEngine {
    static func diff(before: String, after: String, rules: ParsingRules = ParsingRules()) -> [DiffLine] {
        let beforeRecords = snapshotRecords(before, rules: rules)
        let afterRecords = snapshotRecords(after, rules: rules)
        let protections = valueProtections(
            for: beforeRecords + afterRecords,
            explicitSecrets: DocumentParser.explicitSecretValues(in: before)
                + DocumentParser.explicitSecretValues(in: after)
        )
        let beforeGroups = Dictionary(
            grouping: beforeRecords.map { applying(protections, to: $0) },
            by: \.identity
        )
        let afterGroups = Dictionary(
            grouping: afterRecords.map { applying(protections, to: $0) },
            by: \.identity
        )
        let identities = Set(beforeGroups.keys).union(afterGroups.keys).sorted()

        return identities.flatMap { identity in
            diffGroup(
                before: beforeGroups[identity] ?? [],
                after: afterGroups[identity] ?? []
            )
        }
    }

    static func redactedDocument(_ document: String, rules: ParsingRules = ParsingRules()) -> String {
        let items = SmartDocumentParser.parse(document, rules: rules).flatMap(\.items)
        let itemsByLine = Dictionary(
            grouping: items,
            by: \.sourceLine
        )
        let protections = valueProtections(
            for: snapshotRecords(document, rules: rules),
            explicitSecrets: DocumentParser.explicitSecretValues(in: document)
        )

        return document.components(separatedBy: .newlines).enumerated().map { lineIndex, rawLine in
            let safeLine: String
            guard let items = itemsByLine[lineIndex], !items.isEmpty else {
                safeLine = SmartDocumentParser.redactedURLs(
                    in: DocumentParser.redactedDocument(rawLine, rules: rules)
                )
                return redactingProtectedValues(in: safeLine, protections: protections)
            }

            safeLine = items.map { item in
                let label = safeLabel(item.label, rules: rules)
                return "\(label)：\(safeDisplayValue(for: item))"
            }
            .joined(separator: " | ")
            return redactingProtectedValues(in: safeLine, protections: protections)
        }
        .joined(separator: "\n")
    }

    private static func diffGroup(before: [SnapshotRecord], after: [SnapshotRecord]) -> [DiffLine] {
        var unmatchedAfter = Array(after.enumerated())
        var unmatchedBefore: [(offset: Int, element: SnapshotRecord)] = []

        for old in before.enumerated() {
            if let matchIndex = unmatchedAfter.firstIndex(where: { recordsMatch(old.element, $0.element) }) {
                unmatchedAfter.remove(at: matchIndex)
            } else {
                unmatchedBefore.append(old)
            }
        }

        let totalCount = max(before.count, after.count)
        let pairedCount = min(unmatchedBefore.count, unmatchedAfter.count)
        var result: [DiffLine] = []

        for index in 0..<pairedCount {
            let old = unmatchedBefore[index]
            let new = unmatchedAfter[index]
            result.append(
                makeDiffLine(
                    before: old.element,
                    after: new.element,
                    title: displayTitle(old.element.title, occurrence: old.offset, total: totalCount),
                    change: .changed
                )
            )
        }

        for old in unmatchedBefore.dropFirst(pairedCount) {
            result.append(
                makeDiffLine(
                    before: old.element,
                    after: nil,
                    title: displayTitle(old.element.title, occurrence: old.offset, total: totalCount),
                    change: .removed
                )
            )
        }

        for new in unmatchedAfter.dropFirst(pairedCount) {
            result.append(
                makeDiffLine(
                    before: nil,
                    after: new.element,
                    title: displayTitle(new.element.title, occurrence: new.offset, total: totalCount),
                    change: .added
                )
            )
        }

        return result
    }

    private static func makeDiffLine(
        before: SnapshotRecord?,
        after: SnapshotRecord?,
        title: String,
        change: ChangeType
    ) -> DiffLine {
        let isSecret = before?.sensitivity == .secret || after?.sensitivity == .secret
        return DiffLine(
            title: title,
            before: before.map { isSecret ? "已隐藏" : $0.displayValue },
            after: after.map { isSecret ? "已隐藏" : $0.displayValue },
            isSecret: isSecret,
            change: change
        )
    }

    private static func recordsMatch(_ lhs: SnapshotRecord, _ rhs: SnapshotRecord) -> Bool {
        lhs.rawValue == rhs.rawValue && lhs.sensitivity == rhs.sensitivity
    }

    private static func valueProtections(
        for records: [SnapshotRecord],
        explicitSecrets: [String]
    ) -> [String: ValueProtection] {
        var protections = records.reduce(into: [String: ValueProtection]()) { protections, record in
            guard record.sensitivity != .plain else { return }
            let candidate = ValueProtection(
                sensitivity: record.sensitivity,
                displayValue: record.displayValue
            )
            guard let existing = protections[record.rawValue] else {
                protections[record.rawValue] = candidate
                return
            }
            if sensitivityRank(candidate.sensitivity) > sensitivityRank(existing.sensitivity) {
                protections[record.rawValue] = candidate
            }
        }

        for secret in explicitSecrets where !secret.isEmpty {
            protections[secret] = ValueProtection(
                sensitivity: .secret,
                displayValue: "已隐藏"
            )
        }

        return protections
    }

    private static func applying(
        _ protections: [String: ValueProtection],
        to record: SnapshotRecord
    ) -> SnapshotRecord {
        let protectedTitle = redactingProtectedValues(in: record.title, protections: protections)
        let protectedDisplayValue = redactingProtectedValues(
            in: record.displayValue,
            protections: protections
        )
        guard let protection = protections[record.rawValue],
              sensitivityRank(protection.sensitivity) > sensitivityRank(record.sensitivity) else {
            guard protectedTitle != record.title || protectedDisplayValue != record.displayValue else {
                return record
            }
            return SnapshotRecord(
                identity: record.identity,
                title: protectedTitle,
                rawValue: record.rawValue,
                displayValue: protectedDisplayValue,
                sensitivity: record.sensitivity,
                sourceOrder: record.sourceOrder
            )
        }

        return SnapshotRecord(
            identity: record.identity,
            title: protectedTitle,
            rawValue: record.rawValue,
            displayValue: protection.sensitivity == .secret ? "已隐藏" : protection.displayValue,
            sensitivity: protection.sensitivity,
            sourceOrder: record.sourceOrder
        )
    }

    private static func redactingProtectedValues(
        in text: String,
        protections: [String: ValueProtection]
    ) -> String {
        protections.keys
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { result, rawValue in
                guard let protection = protections[rawValue] else { return result }
                let replacement = protection.sensitivity == .secret
                    ? "[已隐藏]"
                    : protection.displayValue
                return result.replacingOccurrences(of: rawValue, with: replacement)
            }
    }

    private static func sensitivityRank(_ sensitivity: SmartSensitivity) -> Int {
        switch sensitivity {
        case .plain: return 0
        case .redactedURL: return 1
        case .secret: return 2
        }
    }

    private static func displayTitle(_ title: String, occurrence: Int, total: Int) -> String {
        total > 1 ? "\(title)（第 \(occurrence + 1) 项）" : title
    }

    private static func snapshotRecords(_ document: String, rules: ParsingRules) -> [SnapshotRecord] {
        let entries = SmartDocumentParser.parse(document, rules: rules)
        let coveredLines = Set(entries.flatMap(\.items).map(\.sourceLine))
        var records: [SnapshotRecord] = []

        for entry in entries {
            for (itemIndex, item) in entry.items.enumerated() {
                let entryTitle = safeLabel(entry.title, rules: rules)
                let itemLabel = safeLabel(item.label, rules: rules)
                records.append(
                    SnapshotRecord(
                        identity: "item\u{1F}\(entry.title)\u{1F}\(item.label)",
                        title: "\(entryTitle) / \(itemLabel)",
                        rawValue: item.value,
                        displayValue: safeDisplayValue(for: item),
                        sensitivity: item.sensitivity,
                        sourceOrder: item.sourceLine * 1_000 + itemIndex
                    )
                )
            }
        }

        var sectionTitle = DocumentParser.implicitSectionTitle
        for (lineIndex, rawLine) in document.components(separatedBy: .newlines).enumerated() {
            let parsed = DocumentParser.parseLine(rawLine, lineIndex: lineIndex, rules: rules)

            if case let .heading(title, level) = parsed.kind {
                if level == 2 {
                    sectionTitle = title
                }
                records.append(
                    SnapshotRecord(
                        identity: "heading\u{1F}\(level)",
                        title: level == 1 ? "文档标题" : "目录标题",
                        rawValue: title,
                        displayValue: safeLabel(title, rules: rules),
                        sensitivity: .plain,
                        sourceOrder: lineIndex * 1_000 + 900
                    )
                )
                continue
            }

            guard !coveredLines.contains(lineIndex) else { continue }

            let safeSection = safeLabel(sectionTitle, rules: rules)
            let sourceOrder = lineIndex * 1_000 + 900
            switch parsed.kind {
            case let .field(field):
                let sensitivity: SmartSensitivity = field.type == .secret ? .secret : .plain
                records.append(
                    SnapshotRecord(
                        identity: "fallback-field\u{1F}\(sectionTitle)\u{1F}\(field.name)",
                        title: "\(safeSection) / \(safeLabel(field.name, rules: rules))",
                        rawValue: field.value,
                        displayValue: sensitivity == .secret ? "已隐藏" : field.value,
                        sensitivity: sensitivity,
                        sourceOrder: sourceOrder
                    )
                )
            case let .secret(value):
                records.append(
                    SnapshotRecord(
                        identity: "raw-secret\u{1F}\(sectionTitle)",
                        title: "\(safeSection) / 隐藏内容",
                        rawValue: value,
                        displayValue: "已隐藏",
                        sensitivity: .secret,
                        sourceOrder: sourceOrder
                    )
                )
            case let .richParagraph(segments):
                records.append(
                    SnapshotRecord(
                        identity: "paragraph\u{1F}\(sectionTitle)",
                        title: "\(safeSection) / 正文",
                        rawValue: segments.map(\.text).joined(),
                        displayValue: segments.map { $0.isSecret ? "[已隐藏]" : $0.text }.joined(),
                        sensitivity: segments.contains(where: \.isSecret) ? .secret : .plain,
                        sourceOrder: sourceOrder
                    )
                )
            case let .paragraph(text):
                records.append(
                    SnapshotRecord(
                        identity: "paragraph\u{1F}\(sectionTitle)",
                        title: "\(safeSection) / 正文",
                        rawValue: text,
                        displayValue: text,
                        sensitivity: .plain,
                        sourceOrder: sourceOrder
                    )
                )
            case .empty, .heading:
                continue
            }
        }

        return records.sorted { $0.sourceOrder < $1.sourceOrder }
    }

    private static func safeDisplayValue(for item: SmartItem) -> String {
        switch item.sensitivity {
        case .plain:
            return item.displayValue
        case .secret:
            return "已隐藏"
        case .redactedURL:
            return item.displayValue
        }
    }

    private static func safeLabel(_ value: String, rules: ParsingRules) -> String {
        let redacted = SmartDocumentParser.redactedURLs(
            in: DocumentParser.redactedDocument(value, rules: rules)
        )
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? "未命名内容" : redacted
    }

    private struct SnapshotRecord {
        let identity: String
        let title: String
        let rawValue: String
        let displayValue: String
        let sensitivity: SmartSensitivity
        let sourceOrder: Int
    }

    private struct ValueProtection {
        let sensitivity: SmartSensitivity
        let displayValue: String
    }
}
