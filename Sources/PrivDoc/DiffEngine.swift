import Foundation

enum DiffEngine {
    static func diff(before: String, after: String, rules: ParsingRules = ParsingRules()) -> [DiffLine] {
        let beforeFields = fieldMap(before, rules: rules)
        let afterFields = fieldMap(after, rules: rules)
        let keys = Set(beforeFields.keys).union(afterFields.keys).sorted()

        return keys.compactMap { key in
            let beforeField = beforeFields[key]
            let afterField = afterFields[key]
            let isSecret = beforeField?.type == .secret || afterField?.type == .secret

            switch (beforeField, afterField) {
            case let (.some(old), .some(new)) where old.value != new.value || old.type != new.type:
                return DiffLine(
                    title: key,
                    before: isSecret ? "已隐藏" : old.value,
                    after: isSecret ? "已隐藏" : new.value,
                    isSecret: isSecret,
                    change: .changed
                )
            case let (.none, .some(new)):
                return DiffLine(
                    title: key,
                    before: nil,
                    after: isSecret ? "已隐藏" : new.value,
                    isSecret: isSecret,
                    change: .added
                )
            case let (.some(old), .none):
                return DiffLine(
                    title: key,
                    before: isSecret ? "已隐藏" : old.value,
                    after: nil,
                    isSecret: isSecret,
                    change: .removed
                )
            default:
                return nil
            }
        }
    }

    private static func fieldMap(_ document: String, rules: ParsingRules) -> [String: Field] {
        var result: [String: Field] = [:]
        for section in DocumentParser.parse(document, rules: rules) {
            var sectionTitle = section.title
            for line in section.lines {
                switch line.kind {
                case let .heading(title, _):
                    sectionTitle = title
                case let .field(field):
                    result["\(sectionTitle) / \(field.name)"] = field
                default:
                    continue
                }
            }
        }
        return result
    }
}
