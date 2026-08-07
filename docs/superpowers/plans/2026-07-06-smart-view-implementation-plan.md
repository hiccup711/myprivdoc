# Smart View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Smart View so PrivDoc can render messy sensitive txt as entries and actionable items without modifying the original document.

**Architecture:** Add a new entry/item parsing layer beside the existing line parser. `VaultPayload.currentDocument` remains the raw source of truth; Smart View parses it into `SmartEntry` and `SmartItem` for view/search/copy only. Existing encryption, history, clipboard cleanup, and raw edit flow stay intact.

**Tech Stack:** Swift 6, SwiftUI, XCTest, existing SwiftPM executable target `PrivDoc`, existing test target `PrivDocTests`.

---

## 用户约束

本仓库用户指令优先于通用计划模板：

- 不自动 commit。
- 不 push、不创建 PR、不发布。
- 只实现完成 Smart View 必需的代码。
- 不读取 secrets、`.env` 或真实私钥。

所以每个任务最后使用 “Checkpoint” 替代 commit。执行者只有在用户明确要求时才可以 commit。

## Scope Check

本计划只覆盖产品方向 spec 的 Phase 1：Smart View。

明确不做：

- Safe Editing 的 entry/item diff。
- Import Assist 的导入确认。
- Fast Access 的全局快捷搜索。
- 自动合并重复条目。
- 自动重写用户原文。
- Keychain 默认保存。

## File Structure

Create:

- `Sources/PrivDoc/SmartModels.swift`
  Smart View 的 view-time 数据模型：`SmartEntry`、`SmartItem`、`SmartItemKind`、`SmartSensitivity`。

- `Sources/PrivDoc/SmartDocumentParser.swift`
  新解析器。负责把原文解析成 Entry / Item；复用 `DocumentParser.parseField` 和 `DocumentParser.inferType`。

- `Tests/PrivDocTests/SmartDocumentParserTests.swift`
  解析器单元测试，覆盖真实敏感 txt 形态：云 Key、裸 secret、SSH、1Panel、URL token 脱敏、搜索排除 secret。

Modify:

- `Sources/PrivDoc/Models.swift`
  扩展 `ParsingRules`，增加条目标题识别规则。

- `Sources/PrivDoc/VaultStore.swift`
  增加 `smartEntries`、`filteredSmartEntries`、`selectedEntryID`、Smart Item 复制/打开/纠错方法。

- `Sources/PrivDoc/ContentView.swift`
  查看态从 `SectionView` 切到 `SmartEntryView`。保留旧 `SectionView` 以降低风险，历史和已有 diff 暂时继续使用旧 parser。

- `README.md`
  增加 Smart View 能力说明。

- `PROGRESS.md`
  记录 Smart View 实现状态和剩余边界。

Test commands:

- `swift test`
- `swift build`
- `git diff --check`

---

## Task 1: Smart View Models

**Files:**
- Create: `Sources/PrivDoc/SmartModels.swift`
- Test: `Tests/PrivDocTests/SmartDocumentParserTests.swift`

- [ ] **Step 1: Write the failing model/parser smoke test**

Create `Tests/PrivDocTests/SmartDocumentParserTests.swift`:

```swift
import XCTest
@testable import PrivDoc

final class SmartDocumentParserTests: XCTestCase {
    func testParsesSingleTitledEntryWithFieldItems() {
        let document = """
        阿里云OSS
        Key: abc123456789012345
        KeySecret: secret12345678901234567890
        """

        let entries = SmartDocumentParser.parse(document)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "阿里云OSS")
        XCTAssertEqual(entries[0].items.map(\.label), ["Key", "KeySecret"])
        XCTAssertTrue(entries[0].items.allSatisfy(\.isHidden))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter SmartDocumentParserTests/testParsesSingleTitledEntryWithFieldItems
```

Expected:

```text
error: cannot find 'SmartDocumentParser' in scope
```

- [ ] **Step 3: Add Smart View model types**

Create `Sources/PrivDoc/SmartModels.swift`:

```swift
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
```

- [ ] **Step 4: Add minimal parser that passes the smoke test**

Create `Sources/PrivDoc/SmartDocumentParser.swift`:

```swift
import Foundation

enum SmartDocumentParser {
    static func parse(_ document: String, rules: ParsingRules = ParsingRules()) -> [SmartEntry] {
        var entries: [SmartEntry] = []
        var currentTitle: String?
        var currentLines: [(index: Int, raw: String)] = []

        func flush() {
            guard let title = currentTitle else {
                currentLines.removeAll()
                return
            }

            let items = currentLines.compactMap { parseItem(from: $0.raw, lineIndex: $0.index, rules: rules) }
            guard !items.isEmpty || !currentLines.isEmpty else {
                currentLines.removeAll()
                return
            }

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
            if trimmed.isEmpty {
                flush()
                currentTitle = nil
                continue
            }

            if currentTitle == nil {
                currentTitle = trimmed
                continue
            }

            currentLines.append((lineIndex, rawLine))
        }

        flush()
        return entries
    }

    private static func parseItem(from rawLine: String, lineIndex: Int, rules: ParsingRules) -> SmartItem? {
        guard let field = DocumentParser.parseField(rawLine, rules: rules) else {
            return nil
        }

        let kind = kindForField(name: field.name, fieldType: field.type)
        let sensitivity = sensitivityFor(label: field.name, kind: kind, fieldType: field.type)
        return SmartItem(
            id: "item-\(lineIndex)-\(slug(field.name))",
            label: field.name,
            value: field.value,
            displayValue: sensitivity == .plain ? field.value : "已隐藏，双击复制",
            kind: kind,
            sensitivity: sensitivity,
            sourceLine: lineIndex
        )
    }

    private static func kindForField(name: String, fieldType: FieldType) -> SmartItemKind {
        let lowerName = name.lowercased()
        if lowerName.contains("keysecret") || lowerName.contains("secret") { return .keySecret }
        if lowerName == "key" || lowerName.contains("api key") || lowerName.contains("accesskey") { return .apiKey }
        switch fieldType {
        case .url: return .url
        case .email: return .email
        case .ip: return .ip
        case .port: return .port
        case .secret: return .password
        case .text: return .text
        }
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
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
swift test --filter SmartDocumentParserTests/testParsesSingleTitledEntryWithFieldItems
```

Expected:

```text
Test Suite 'SmartDocumentParserTests' passed
```

- [ ] **Step 6: Checkpoint**

Run:

```bash
git status --short
```

Expected: new model/parser/test files appear. Do not commit.

---

## Task 2: Entry Detection for Messy Text

**Files:**
- Modify: `Sources/PrivDoc/SmartDocumentParser.swift`
- Test: `Tests/PrivDocTests/SmartDocumentParserTests.swift`

- [ ] **Step 1: Write failing tests for blank lines, separators, and standalone titles**

Append to `SmartDocumentParserTests`:

```swift
func testParsesEntriesSeparatedByBlankLinesAndSeparators() {
    let document = """
    Google Developer
    service@example.com
    abcdefghijklmnopqrstuvwxyz

    ————————————————————
    Twilio
    twilio-secret-value-1234567890
    """

    let entries = SmartDocumentParser.parse(document)

    XCTAssertEqual(entries.map(\.title), ["Google Developer", "Twilio"])
}

func testDoesNotRequireMarkdownHeadingsForTitles() {
    let document = """
    正式服务器
    ssh root@192.0.2.106
    root-password-1234567890
    """

    let entries = SmartDocumentParser.parse(document)

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].title, "正式服务器")
}

func testCustomEntryTitleKeywordStartsNewEntry() {
    let rules = ParsingRules(customEntryTitleKeywords: ["内部工具"])
    let document = """
    账号资料
    service@example.com
    abcdefghijklmnopqrstuvwxyz
    内部工具
    tool-secret-1234567890
    """

    let entries = SmartDocumentParser.parse(document, rules: rules)

    XCTAssertEqual(entries.map(\.title), ["账号资料", "内部工具"])
}
```

- [ ] **Step 2: Run tests to verify they fail or expose missing item parsing**

Run:

```bash
swift test --filter SmartDocumentParserTests
```

Expected: at least one new test fails because separators and standalone title handling are still too naive.

- [ ] **Step 3: Implement robust entry boundary helpers**

Update `SmartDocumentParser.parse` to use helper methods:

```swift
static func parse(_ document: String, rules: ParsingRules = ParsingRules()) -> [SmartEntry] {
    var entries: [SmartEntry] = []
    var currentTitle: String?
    var currentLines: [(index: Int, raw: String)] = []

    func flush() {
        guard let title = currentTitle else {
            currentLines.removeAll()
            return
        }
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
        if trimmed.isEmpty || isSeparator(trimmed) {
            flush()
            currentTitle = nil
            continue
        }

        if currentTitle == nil {
            currentTitle = titleFromLine(trimmed)
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

private static func parseItems(
    from lines: [(index: Int, raw: String)],
    title: String,
    rules: ParsingRules
) -> [SmartItem] {
    lines.compactMap { parseItem(from: $0.raw, lineIndex: $0.index, rules: rules) }
}

private static func isSeparator(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 4 else { return false }
    let separatorScalars = CharacterSet(charactersIn: "-—–_=*")
    return compact.unicodeScalars.allSatisfy { separatorScalars.contains($0) }
}

private static func titleFromLine(_ line: String) -> String {
    if line.hasPrefix("#") {
        return line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }
    return line
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
    if rules.customEntryTitleKeywords.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
        return true
    }
    guard trimmed.count <= 48 else { return false }
    if trimmed.contains("://") || trimmed.contains("@") { return false }
    if trimmed.range(of: #"\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil { return false }
    return trimmed.range(of: #"[A-Za-z\u{4e00}-\u{9fff}]"#, options: .regularExpression) != nil
}
```

- [ ] **Step 4: Extend `ParsingRules` for title hints with backward-compatible decoding**

Modify `Sources/PrivDoc/Models.swift`:

```swift
struct ParsingRules: Codable, Equatable {
    var customSecretKeywords: [String]
    var customPlainTextKeywords: [String]
    var customEntryTitleKeywords: [String]

    enum CodingKeys: String, CodingKey {
        case customSecretKeywords
        case customPlainTextKeywords
        case customEntryTitleKeywords
    }

    init(
        customSecretKeywords: [String] = [],
        customPlainTextKeywords: [String] = [],
        customEntryTitleKeywords: [String] = []
    ) {
        self.customSecretKeywords = customSecretKeywords
        self.customPlainTextKeywords = customPlainTextKeywords
        self.customEntryTitleKeywords = customEntryTitleKeywords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customSecretKeywords = try container.decodeIfPresent([String].self, forKey: .customSecretKeywords) ?? []
        customPlainTextKeywords = try container.decodeIfPresent([String].self, forKey: .customPlainTextKeywords) ?? []
        customEntryTitleKeywords = try container.decodeIfPresent([String].self, forKey: .customEntryTitleKeywords) ?? []
    }
}
```

Do not add a custom `encode(to:)`; the synthesized encoder remains correct because all three properties are stored.

- [ ] **Step 5: Add helper recognizers**

Add to `SmartDocumentParser`:

```swift
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

private static func looksLikeOpaqueSecret(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 12 else { return false }
    if trimmed.contains(" ") { return false }
    if looksLikeEmail(trimmed) || looksLikeURL(trimmed) || looksLikeSSH(trimmed) { return false }
    return true
}
```

- [ ] **Step 6: Run tests**

Run:

```bash
swift test --filter SmartDocumentParserTests
```

Expected: tests pass or fail only because bare secret/SSH items are not implemented yet. If the latter happens, continue to Task 3 and keep the failing evidence.

- [ ] **Step 7: Checkpoint**

Run:

```bash
git status --short
```

Expected: parser/model/test changes only. Do not commit.

---

## Task 3: Item Detection for Email, Bare Secret, Fields, and 1Panel

**Files:**
- Modify: `Sources/PrivDoc/SmartDocumentParser.swift`
- Test: `Tests/PrivDocTests/SmartDocumentParserTests.swift`

- [ ] **Step 1: Write failing tests for account/password and 1Panel logs**

Append:

```swift
func testParsesEmailAndFollowingBareSecrets() {
    let document = """
    Google Developer
    service@example.com
    first-secret-value-1234567890
    second-secret-value-1234567890
    """

    let entry = SmartDocumentParser.parse(document)[0]

    XCTAssertEqual(entry.items.map(\.kind), [.email, .password, .password])
    XCTAssertEqual(entry.items[0].sensitivity, .plain)
    XCTAssertEqual(entry.items[1].sensitivity, .secret)
    XCTAssertEqual(entry.items[2].sensitivity, .secret)
}

func testParsesOnePanelFields() {
    let document = """
    Example Service
    [1Panel 2026-01-01 install Log]: 外部地址： http://203.0.113.10:8443/random-token
    [1Panel 2026-01-01 install Log]: 内部地址： http://10.0.0.2:8443/random-token
    [1Panel 2026-01-01 install Log]: 面板用户： admin-user
    [1Panel 2026-01-01 install Log]: 面板密码： panel-password-123456
    """

    let entry = SmartDocumentParser.parse(document)[0]

    XCTAssertEqual(entry.items.map(\.label), ["外部地址", "内部地址", "面板用户", "面板密码"])
    XCTAssertEqual(entry.items.map(\.kind), [.url, .url, .panelUser, .panelPassword])
    XCTAssertEqual(entry.items.last?.sensitivity, .secret)
}
```

- [ ] **Step 2: Run tests to verify failures**

Run:

```bash
swift test --filter SmartDocumentParserTests/testParsesEmailAndFollowingBareSecrets
swift test --filter SmartDocumentParserTests/testParsesOnePanelFields
```

Expected:

```text
XCTAssertEqual failed
```

because bare lines and 1Panel prefixes are not parsed as Smart Items yet.

- [ ] **Step 3: Track previous line context while parsing items**

Replace `parseItems` with:

```swift
private static func parseItems(
    from lines: [(index: Int, raw: String)],
    title: String,
    rules: ParsingRules
) -> [SmartItem] {
    var items: [SmartItem] = []
    var secretCounter = 1
    var lastVisibleAccountOrCommand = false

    for line in lines {
        if let item = parseItem(from: line.raw, lineIndex: line.index, rules: rules) {
            items.append(item)
            lastVisibleAccountOrCommand = item.kind == .email || item.kind == .sshUser || item.kind == .sshHost
            continue
        }

        let cleaned = stripLogPrefix(line.raw).trimmingCharacters(in: .whitespacesAndNewlines)
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
```

- [ ] **Step 4: Normalize log-prefixed field lines**

Update `parseItem`:

```swift
private static func parseItem(from rawLine: String, lineIndex: Int, rules: ParsingRules) -> SmartItem? {
    let normalizedLine = stripLogPrefix(rawLine)
    guard let field = DocumentParser.parseField(normalizedLine, rules: rules) else {
        if looksLikeURL(normalizedLine.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let value = normalizedLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return urlItem(label: "链接", value: value, lineIndex: lineIndex)
        }
        return nil
    }

    let kind = kindForField(name: field.name, fieldType: field.type)
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

private static func stripLogPrefix(_ rawLine: String) -> String {
    let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let close = trimmed.firstIndex(of: "]") else { return trimmed }
    let afterClose = trimmed.index(after: close)
    guard afterClose < trimmed.endIndex else { return trimmed }
    var remainder = trimmed[afterClose...].trimmingCharacters(in: .whitespacesAndNewlines)
    if remainder.hasPrefix(":") || remainder.hasPrefix("：") {
        remainder.removeFirst()
    }
    return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
}

private static func displayValueFor(value: String, sensitivity: SmartSensitivity) -> String {
    switch sensitivity {
    case .plain:
        return value
    case .secret:
        return "已隐藏，双击复制"
    case .redactedURL:
        return redactedURLDisplay(value)
    }
}
```

- [ ] **Step 5: Improve field kind mapping**

Update `kindForField`:

```swift
private static func kindForField(name: String, fieldType: FieldType) -> SmartItemKind {
    let lowerName = name.lowercased()
    if lowerName.contains("面板密码") { return .panelPassword }
    if lowerName.contains("面板用户") { return .panelUser }
    if lowerName.contains("keysecret") || lowerName.contains("secret") { return .keySecret }
    if lowerName == "key" || lowerName.contains("api key") || lowerName.contains("accesskey") { return .apiKey }
    if lowerName.contains("密码") || lowerName.contains("password") { return .password }
    if lowerName.contains("账号") || lowerName.contains("用户") || lowerName.contains("user") { return .username }
    switch fieldType {
    case .url: return .url
    case .email: return .email
    case .ip: return .ip
    case .port: return .port
    case .secret: return .password
    case .text: return .text
    }
}
```

- [ ] **Step 6: Run parser tests**

Run:

```bash
swift test --filter SmartDocumentParserTests
```

Expected: all parser tests written so far pass, except URL redaction if not implemented yet.

- [ ] **Step 7: Checkpoint**

Run:

```bash
git status --short
```

Expected: parser and parser test changes only. Do not commit.

---

## Task 4: SSH Parsing and Panel URL Redaction

**Files:**
- Modify: `Sources/PrivDoc/SmartDocumentParser.swift`
- Test: `Tests/PrivDocTests/SmartDocumentParserTests.swift`

- [ ] **Step 1: Write failing tests for SSH and redacted panel URL**

Append:

```swift
func testParsesSSHCommandAndFollowingPassword() {
    let document = """
    测试服务器
    ssh root@192.0.2.106
    root-password-1234567890
    """

    let entry = SmartDocumentParser.parse(document)[0]

    XCTAssertEqual(entry.items.map(\.label), ["SSH 用户", "SSH 主机", "密钥"])
    XCTAssertEqual(entry.items[0].value, "root")
    XCTAssertEqual(entry.items[1].value, "192.0.2.106")
    XCTAssertEqual(entry.items[2].sensitivity, .secret)
}

func testRedactsPanelURLPathButKeepsFullCopyValue() {
    let document = """
    1Panel
    外部地址: http://198.51.100.42:9443/random-token
    """

    let item = SmartDocumentParser.parse(document)[0].items[0]

    XCTAssertEqual(item.value, "http://198.51.100.42:9443/random-token")
    XCTAssertEqual(item.displayValue, "http://198.51.100.42:9443/[已隐藏路径]")
    XCTAssertEqual(item.sensitivity, .redactedURL)
}
```

- [ ] **Step 2: Run tests to verify failures**

Run:

```bash
swift test --filter SmartDocumentParserTests/testParsesSSHCommandAndFollowingPassword
swift test --filter SmartDocumentParserTests/testRedactsPanelURLPathButKeepsFullCopyValue
```

Expected: tests fail because SSH splitting and URL redaction are missing.

- [ ] **Step 3: Add SSH parsing in `parseItems` before generic item parsing**

Inside the `for line in lines` loop in `parseItems`, move the existing `cleaned` assignment to the top of the loop, then add SSH parsing before `parseItem`. The top of the loop should look like this:

```swift
let cleaned = stripLogPrefix(line.raw).trimmingCharacters(in: .whitespacesAndNewlines)
if let sshItems = parseSSHItems(cleaned, lineIndex: line.index) {
    items.append(contentsOf: sshItems)
    lastVisibleAccountOrCommand = true
    continue
}

if let item = parseItem(from: line.raw, lineIndex: line.index, rules: rules) {
    items.append(item)
    lastVisibleAccountOrCommand = item.kind == .email || item.kind == .sshUser || item.kind == .sshHost
    continue
}
```

Remove the later duplicate `let cleaned = ...` line from the same loop.

Add helper:

```swift
private static func parseSSHItems(_ line: String, lineIndex: Int) -> [SmartItem]? {
    let pattern = #"^ssh\s+([^@\s]+)@([^\s]+)$"#
    guard let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
        return nil
    }

    let matched = String(line[range])
    let parts = matched
        .replacingOccurrences(of: #"^ssh\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        .split(separator: "@", maxSplits: 1)
        .map(String.init)
    guard parts.count == 2 else { return nil }

    return [
        SmartItem(
            id: "item-\(lineIndex)-ssh-user",
            label: "SSH 用户",
            value: parts[0],
            displayValue: parts[0],
            kind: .sshUser,
            sensitivity: .plain,
            sourceLine: lineIndex
        ),
        SmartItem(
            id: "item-\(lineIndex)-ssh-host",
            label: "SSH 主机",
            value: parts[1],
            displayValue: parts[1],
            kind: .sshHost,
            sensitivity: .plain,
            sourceLine: lineIndex
        )
    ]
}
```

- [ ] **Step 4: Add panel URL detection and redaction**

Add helpers:

```swift
private static func urlItem(label: String, value: String, lineIndex: Int) -> SmartItem {
    let sensitivity: SmartSensitivity = shouldRedactURL(value) ? .redactedURL : .plain
    return SmartItem(
        id: "item-\(lineIndex)-url",
        label: label,
        value: value,
        displayValue: displayValueFor(value: value, sensitivity: sensitivity),
        kind: .url,
        sensitivity: sensitivity,
        sourceLine: lineIndex
    )
}

private static func shouldRedactURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
          let host = url.host,
          !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
        return false
    }

    let hostIsIP = host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
    let hasPort = url.port != nil
    return hostIsIP && hasPort
}

private static func redactedURLDisplay(_ value: String) -> String {
    guard let url = URL(string: value), let scheme = url.scheme, let host = url.host else {
        return "[已隐藏链接]"
    }

    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)/[已隐藏路径]"
}
```

Update `parseItem` immediately after this line:

```swift
let kind = kindForField(name: field.name, fieldType: field.type)
```

Insert:

```swift
if kind == .url {
    return urlItem(label: field.name, value: field.value, lineIndex: lineIndex)
}
```

Then keep the existing sensitivity/display `SmartItem` return path for non-URL fields.

- [ ] **Step 5: Run tests**

Run:

```bash
swift test --filter SmartDocumentParserTests
```

Expected: all parser tests pass.

- [ ] **Step 6: Checkpoint**

Run:

```bash
git status --short
```

Expected: parser and tests changed. Do not commit.

---

## Task 5: Smart Search Text

**Files:**
- Modify: `Sources/PrivDoc/SmartDocumentParser.swift`
- Test: `Tests/PrivDocTests/SmartDocumentParserTests.swift`

- [ ] **Step 1: Write failing test for searchable text excluding secrets**

Append:

```swift
func testSearchableTextExcludesHiddenValuesButIncludesVisibleMetadata() {
    let document = """
    1Panel
    外部地址: http://198.51.100.42:9443/random-token
    面板用户: admin-user
    面板密码: panel-password-123456
    """

    let entries = SmartDocumentParser.parse(document)
    let searchable = SmartDocumentParser.searchableText(for: entries)

    XCTAssertTrue(searchable.contains("1Panel"))
    XCTAssertTrue(searchable.contains("198.51.100.42"))
    XCTAssertTrue(searchable.contains("admin-user"))
    XCTAssertFalse(searchable.contains("random-token"))
    XCTAssertFalse(searchable.contains("panel-password-123456"))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter SmartDocumentParserTests/testSearchableTextExcludesHiddenValuesButIncludesVisibleMetadata
```

Expected:

```text
error: type 'SmartDocumentParser' has no member 'searchableText'
```

- [ ] **Step 3: Implement searchable text**

Add to `SmartDocumentParser`:

```swift
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
```

- [ ] **Step 4: Run parser tests**

Run:

```bash
swift test --filter SmartDocumentParserTests
```

Expected: all parser tests pass.

- [ ] **Step 5: Checkpoint**

Run:

```bash
git status --short
```

Expected: parser and tests changed. Do not commit.

---

## Task 6: VaultStore Smart View Integration

**Files:**
- Modify: `Sources/PrivDoc/VaultStore.swift`
- Test: `Tests/PrivDocTests/VaultStoreTests.swift`

- [ ] **Step 1: Write failing tests for smart entry filtering and full-value copy**

Append to `VaultStoreTests`:

```swift
func testFilteredSmartEntriesExcludeSecretValuesFromSearch() {
    let store = VaultStore()
    store.payload = VaultPayload(
        currentDocument: """
        1Panel
        外部地址: http://198.51.100.42:9443/random-token
        面板密码: panel-password-123456
        """,
        versions: [],
        settings: AppSettings()
    )

    store.searchQuery = "panel-password-123456"
    XCTAssertTrue(store.filteredSmartEntries.isEmpty)

    store.searchQuery = "198.51.100.42"
    XCTAssertEqual(store.filteredSmartEntries.first?.title, "1Panel")
}

func testCopySmartItemCopiesOriginalValueNotDisplayValue() {
    let store = VaultStore()
    store.payload = VaultPayload(
        currentDocument: """
        1Panel
        外部地址: http://198.51.100.42:9443/random-token
        """,
        versions: [],
        settings: AppSettings()
    )

    let item = store.smartEntries[0].items[0]
    store.copySmartItemValue(item)

    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "http://198.51.100.42:9443/random-token")
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter VaultStoreTests/testFilteredSmartEntriesExcludeSecretValuesFromSearch
swift test --filter VaultStoreTests/testCopySmartItemCopiesOriginalValueNotDisplayValue
```

Expected:

```text
value of type 'VaultStore' has no member 'filteredSmartEntries'
value of type 'VaultStore' has no member 'copySmartItemValue'
```

- [ ] **Step 3: Add Smart View state and computed entries**

In `VaultStore`, add:

```swift
@Published var selectedEntryID: String?
```

Add computed properties:

```swift
var smartEntries: [SmartEntry] {
    SmartDocumentParser.parse(payload?.currentDocument ?? "", rules: globalParsingRules)
}

var filteredSmartEntries: [SmartEntry] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return smartEntries }

    return smartEntries.filter { entry in
        SmartDocumentParser
            .searchableText(for: [entry])
            .localizedCaseInsensitiveContains(query)
    }
}

var selectedSmartEntry: SmartEntry? {
    guard let selectedEntryID else { return nil }
    return filteredSmartEntries.first(where: { $0.id == selectedEntryID })
}
```

- [ ] **Step 4: Reset selected entry on new/open/lock**

In `newVault`, `unlockPendingVault`, system unlock inside `unlockSelectedVault`, and `lock`, set:

```swift
selectedEntryID = nil
```

Keep existing `selectedSectionID = nil` until old section UI is fully removed.

- [ ] **Step 5: Add Smart Item copy/open methods**

Add to `VaultStore`:

```swift
func copySmartItemValue(_ item: SmartItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.value, forType: .string)
    lastPrivDocPasteboardChangeCount = NSPasteboard.general.changeCount
    clipboardHasPrivDocContent = true
    scheduleClipboardClear()
    showToast(payload?.settings.clipboardClearDelay.copyFeedbackText ?? ClipboardClearDelay.seconds15.copyFeedbackText, kind: .copied)
}

func copySmartItemLine(_ item: SmartItem, revealSecret: Bool = false) {
    let value = item.isHidden && !revealSecret ? "已隐藏" : item.value
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("\(item.label): \(value)", forType: .string)
    lastPrivDocPasteboardChangeCount = NSPasteboard.general.changeCount
    clipboardHasPrivDocContent = true
    scheduleClipboardClear()
    showToast("整行已复制", kind: .copied)
}

func openSmartItemURL(_ item: SmartItem) {
    guard item.kind == .url, let url = URL(string: item.value) else { return }
    NSWorkspace.shared.open(url)
}
```

- [ ] **Step 6: Run store tests**

Run:

```bash
swift test --filter VaultStoreTests
```

Expected: all VaultStore tests pass.

- [ ] **Step 7: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Checkpoint**

Run:

```bash
git status --short
```

Expected: store and tests changed. Do not commit.

---

## Task 7: Smart View UI Rendering

**Files:**
- Modify: `Sources/PrivDoc/ContentView.swift`
- Test: compile with `swift build`

- [ ] **Step 1: Replace ViewMode data source with smart entries**

Modify `ViewMode` body:

```swift
let entriesToShow = store.selectedEntryID == nil ? store.filteredSmartEntries : store.selectedSmartEntry.map { [$0] } ?? []
if entriesToShow.isEmpty {
    ContentUnavailableView("没有可显示的内容", systemImage: "doc.text", description: Text("编辑文档后会在这里看到内容。"))
        .frame(maxWidth: .infinity, minHeight: 320)
} else {
    ForEach(entriesToShow) { entry in
        SmartEntryView(entry: entry)
    }
}
```

Keep the document title logic unchanged.

- [ ] **Step 2: Update Sidebar to use smart entries**

Modify `Sidebar`:

```swift
Button {
    store.selectedEntryID = nil
} label: {
    SidebarItem(title: "全文", isSelected: store.selectedEntryID == nil)
}
.buttonStyle(.plain)

ForEach(store.filteredSmartEntries) { entry in
    Button {
        store.selectedEntryID = entry.id
    } label: {
        SidebarItem(title: entry.title, isSelected: store.selectedEntryID == entry.id)
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 3: Add `SmartEntryView`**

Add near `SectionView`:

```swift
struct SmartEntryView: View {
    let entry: SmartEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.text)

            if entry.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entry.rawLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(entry.items) { item in
                        SmartItemRow(item: item)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: Add `SmartItemRow`**

Add near `FieldRow`:

```swift
struct SmartItemRow: View {
    @EnvironmentObject private var store: VaultStore
    let item: SmartItem
    @State private var revealSecret = false

    var body: some View {
        HStack(spacing: 14) {
            Text(item.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)

            valueView

            Spacer(minLength: 16)

            SmartItemBadge(item: item)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Theme.row)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.copySmartItemValue(item)
        }
        .contextMenu {
            Button("复制值") { store.copySmartItemValue(item) }
            Button("复制脱敏整行") { store.copySmartItemLine(item, revealSecret: false) }
            if item.isHidden {
                Button("临时显示 10 秒") {
                    revealSecret = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        revealSecret = false
                    }
                }
                Button("复制完整整行") { store.copySmartItemLine(item, revealSecret: true) }
            }
            if item.canOpen {
                Button("打开链接") { store.openSmartItemURL(item) }
            }
            Button("把“\(item.label)”识别为密钥") { store.addSecretKeyword(item.label) }
            Button("把“\(item.label)”识别为普通字段") { store.addPlainTextKeyword(item.label) }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if item.isHidden && !revealSecret {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                Text(item.displayValue)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.secret)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.secretBackground)
            .clipShape(Capsule())
        } else {
            Text(revealSecret ? item.value : item.displayValue)
                .font(.system(size: 13, design: item.kind == .text ? .default : .monospaced))
                .foregroundStyle(item.kind == .url ? Theme.link : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 5: Add `SmartItemBadge`**

Add near `FieldBadge`:

```swift
struct SmartItemBadge: View {
    let item: SmartItem

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch item.kind {
        case .url: return "URL"
        case .email: return "EMAIL"
        case .username, .sshUser, .panelUser: return "USER"
        case .password, .panelPassword, .apiKey, .keySecret: return "SECRET"
        case .sshHost: return "SSH"
        case .ip: return "IP"
        case .port: return "PORT"
        case .note: return "NOTE"
        case .text: return "TEXT"
        }
    }

    private var color: Color {
        if item.isHidden { return Theme.secret }
        switch item.kind {
        case .url: return Theme.link
        case .email: return .teal
        case .ip, .port, .sshHost: return Theme.accent
        default: return Theme.faint
        }
    }
}
```

- [ ] **Step 6: Build to verify UI compiles**

Run:

```bash
swift build
```

Expected:

```text
Build complete!
```

- [ ] **Step 7: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 8: Checkpoint**

Run:

```bash
git status --short
```

Expected: `ContentView.swift` changed. Do not commit.

---

## Task 8: Smart Parse Preview

**Files:**
- Modify: `Sources/PrivDoc/ContentView.swift`
- Test: compile with `swift build`

- [ ] **Step 1: Change `ParsePreview` to use SmartDocumentParser**

Replace:

```swift
let sections = DocumentParser.parse(document, rules: store.globalParsingRules)
```

with:

```swift
let entries = SmartDocumentParser.parse(document, rules: store.globalParsingRules)
```

- [ ] **Step 2: Replace preview body loop**

Inside the preview VStack, replace `ForEach(sections)` block with:

```swift
ForEach(entries) { entry in
    VStack(alignment: .leading, spacing: 6) {
        Text(entry.title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
        ForEach(entry.items) { item in
            HStack {
                Text(item.label)
                    .lineLimit(1)
                Spacer()
                SmartItemBadge(item: item)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run:

```bash
swift build
```

Expected:

```text
Build complete!
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 5: Checkpoint**

Run:

```bash
git status --short
```

Expected: `ContentView.swift` changed. Do not commit.

---

## Task 9: Title Correction Rule

**Files:**
- Modify: `Sources/PrivDoc/VaultStore.swift`
- Modify: `Sources/PrivDoc/ContentView.swift`
- Test: `Tests/PrivDocTests/VaultStoreTests.swift`

- [ ] **Step 1: Write failing store test for saving title keyword rules**

Append to `VaultStoreTests`:

```swift
func testAddEntryTitleKeywordStoresUniqueSortedRule() {
    let store = VaultStore()

    store.addEntryTitleKeyword("内部工具")
    store.addEntryTitleKeyword("内部工具")
    store.addEntryTitleKeyword("阿里云")

    XCTAssertEqual(store.globalParsingRules.customEntryTitleKeywords, ["阿里云", "内部工具"])
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
swift test --filter VaultStoreTests/testAddEntryTitleKeywordStoresUniqueSortedRule
```

Expected:

```text
value of type 'VaultStore' has no member 'addEntryTitleKeyword'
```

- [ ] **Step 3: Add store method to save title keyword**

In `VaultStore`, add public method:

```swift
func addEntryTitleKeyword(_ keyword: String) {
    let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    guard !globalParsingRules.customEntryTitleKeywords.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
        return
    }
    globalParsingRules.customEntryTitleKeywords = (globalParsingRules.customEntryTitleKeywords + [normalized])
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    saveGlobalParsingRules()
    showToast("标题规则已添加", kind: .saved)
}
```

- [ ] **Step 4: Add context menu action on entry title**

In `SmartEntryView`, change title `Text(entry.title)` to:

```swift
Text(entry.title)
    .font(.system(size: 26, weight: .semibold, design: .serif))
    .foregroundStyle(Theme.text)
    .contextMenu {
        Button("以后把“\(entry.title)”识别为条目标题") {
            // SmartEntryView needs @EnvironmentObject store before adding this.
            store.addEntryTitleKeyword(entry.title)
        }
    }
```

Also add:

```swift
@EnvironmentObject private var store: VaultStore
```

inside `SmartEntryView`.

- [ ] **Step 5: Run tests and build**

Run:

```bash
swift test
swift build
```

Expected: all tests pass and build completes.

- [ ] **Step 6: Checkpoint**

Run:

```bash
git status --short
```

Expected: model/store/UI/test changes. Do not commit.

---

## Task 10: Documentation and Verification

**Files:**
- Modify: `README.md`
- Modify: `PROGRESS.md`

- [ ] **Step 1: Update README capability list**

Add bullets under “现在能体验什么”:

```markdown
- Smart View 会把混乱原文解析成条目和可操作项，不要求先整理格式
- 支持识别裸邮箱、裸密钥、SSH 命令、1Panel 日志和面板 URL
- 面板 URL 会隐藏随机路径 token，但复制时复制完整 URL
```

- [ ] **Step 2: Update PROGRESS**

Add a section:

```markdown
## 2026-07-06 Smart View

已实现：

- 查看态从 section-first 升级为 entry-first。
- 原文不改，查看态解析 Entry / Item。
- 支持字段、邮箱、裸密钥、SSH、1Panel 日志、面板 URL。
- 面板 URL 视觉隐藏随机路径 token，复制保留完整值。
- 搜索排除隐藏值。
- 右键可把字段识别为密钥/普通字段，也可添加条目标题规则。

边界：

- 暂不自动合并重复条目。
- 暂不重写原文。
- Safe Editing 的 entry/item diff 留到下一阶段。
```

- [ ] **Step 3: Run full verification**

Run:

```bash
swift test
swift build
git diff --check
```

Expected:

```text
swift test: all tests pass
swift build: Build complete!
git diff --check: no output
```

- [ ] **Step 4: Search for forbidden product drift**

Run:

```bash
rg -n '自动填充|云同步|团队共享|自动合并|自动重写|默认使用 Keychain' README.md PROGRESS.md docs/superpowers/specs docs/superpowers/plans || true
```

Expected: matches only appear in “非目标” or “不做” context.

- [ ] **Step 5: Final checkpoint**

Run:

```bash
git status --short
```

Expected: implementation files, tests, README, PROGRESS, and plan/spec are modified or untracked. Do not commit unless user explicitly asks.

---

## Self-Review Checklist

Spec coverage:

- Entry-first parsing: Tasks 1-4.
- Original text unchanged: Tasks 1-8 keep `VaultPayload.currentDocument` as source.
- Secret hiding: Tasks 3-5.
- Precise copy: Task 6.
- Panel URL redaction with full-copy behavior: Tasks 4 and 6.
- Search excluding secrets: Tasks 5 and 6.
- Right-click correction: Tasks 7 and 9.
- Parse preview alignment: Task 8.
- Docs and verification: Task 10.

Type consistency:

- `SmartEntry`, `SmartItem`, `SmartItemKind`, `SmartSensitivity` are introduced in Task 1 and used consistently afterward.
- `SmartDocumentParser.parse` and `SmartDocumentParser.searchableText` are introduced before `VaultStore` uses them.
- `customEntryTitleKeywords` is added to `ParsingRules` before UI calls `addEntryTitleKeyword`.

Execution rule:

- Each production behavior has a failing test first, except SwiftUI rendering, which is verified by `swift build` and backed by parser/store tests.
- No task includes a commit step because the user explicitly has not requested commits.
