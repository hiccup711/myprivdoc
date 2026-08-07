import XCTest
@testable import PrivDoc

final class SmartDocumentParserTests: XCTestCase {
    func testMarkdownHeadingKeepsItemsAcrossFollowingBlankLine() throws {
        let document = """
        # 我的隐私文档

        ## 服务器 / prod-01

        服务器IP：192.0.2.10
        SSH用户：root
        """

        let entries = SmartDocumentParser.parse(document)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entries.map(\.title), ["服务器 / prod-01"])
        XCTAssertEqual(entry.items.map(\.label), ["服务器IP", "SSH用户"])
    }

    func testPlainTitleKeepsItemsAcrossFollowingBlankLine() throws {
        let document = """
        GitHub

        账号：demo-user
        Token：{{demo-token}}
        """

        let entries = SmartDocumentParser.parse(document)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.title, "GitHub")
        XCTAssertEqual(entry.items.map(\.label), ["账号", "Token"])
    }

    func testExplicitHiddenFirstLineBecomesHiddenItemNotTitle() throws {
        let document = "{{abc123}}"

        let entries = SmartDocumentParser.parse(document)
        let entry = try XCTUnwrap(entries.first)
        let item = try XCTUnwrap(entry.items.first)

        XCTAssertEqual(entry.title, "未命名条目")
        XCTAssertEqual(item.kind, .password)
        XCTAssertEqual(item.value, "abc123")
        XCTAssertEqual(item.sensitivity, .secret)
        XCTAssertFalse(SmartDocumentParser.searchableText(for: entries).contains("abc123"))
    }

    func testSensitiveFieldFirstLineBecomesHiddenItemNotTitle() throws {
        let document = "临时 Token: secret-token-123456 @secret"

        let entries = SmartDocumentParser.parse(document)
        let entry = try XCTUnwrap(entries.first)
        let item = try XCTUnwrap(entry.items.first)

        XCTAssertEqual(entry.title, "未命名条目")
        XCTAssertEqual(entry.items.map(\.label), ["临时 Token"])
        XCTAssertEqual(item.sensitivity, .secret)
        XCTAssertFalse(SmartDocumentParser.searchableText(for: entries).contains("secret-token-123456"))
    }

    func testOpaqueFirstLineBecomesHiddenItemNotTitle() throws {
        let token = "ghp_abcdefghijklmnopqrstuvwxyz"

        let entries = SmartDocumentParser.parse(token)
        let entry = try XCTUnwrap(entries.first)

        XCTAssertEqual(entry.title, "未命名条目")
        XCTAssertEqual(entry.items.map(\.kind), [.password])
        XCTAssertFalse(SmartDocumentParser.searchableText(for: entries).contains(token))
    }

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
        XCTAssertEqual(entries[0].items.map(\.value), ["abc123456789012345", "secret12345678901234567890"])
        XCTAssertEqual(entries[0].items.map(\.kind), [.apiKey, .keySecret])
        XCTAssertEqual(entries[0].items.map(\.sensitivity), [.secret, .secret])
        XCTAssertTrue(entries[0].items.allSatisfy(\.isHidden))
    }

    func testExplicitTextTagKeepsKeyFieldVisible() {
        let document = """
        Public Config
        API Key: public-key-value @text
        """

        let item = SmartDocumentParser.parse(document)[0].items[0]

        XCTAssertEqual(item.label, "API Key")
        XCTAssertEqual(item.value, "public-key-value")
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.sensitivity, .plain)
        XCTAssertFalse(item.isHidden)
    }

    func testAccountAndUserFieldsMapToUsername() {
        let document = """
        Accounts
        账号：demo-user
        用户：admin
        User: root
        """

        let entry = SmartDocumentParser.parse(document)[0]

        XCTAssertEqual(entry.items.map(\.kind), [.username, .username, .username])
        XCTAssertEqual(entry.items.map(\.sensitivity), [.plain, .plain, .plain])
    }

    func testUsernameFieldMakesNextShortBareLineSecret() {
        let document = """
        Accounts
        账号：admin
        pass123
        """

        let entry = SmartDocumentParser.parse(document)[0]

        XCTAssertEqual(entry.items.map(\.kind), [.username, .password])
        XCTAssertEqual(entry.items.map(\.sensitivity), [.plain, .secret])
        XCTAssertEqual(entry.items.map(\.isHidden), [false, true])
    }

    func testPanelUserFieldMakesNextShortBareLineSecret() {
        let document = """
        Panel
        面板用户：admin
        pass123
        """

        let entry = SmartDocumentParser.parse(document)[0]

        XCTAssertEqual(entry.items.map(\.kind), [.panelUser, .password])
        XCTAssertEqual(entry.items.map(\.sensitivity), [.plain, .secret])
        XCTAssertEqual(entry.items.map(\.isHidden), [false, true])
    }

    func testBracketedFieldValueIsNotTreatedAsLogPrefix() {
        let document = """
        Notes
        备注: [prod] rotate later
        """

        let items = SmartDocumentParser.parse(document)[0].items

        XCTAssertEqual(items.map(\.value), ["[prod] rotate later"])
        XCTAssertEqual(items.map(\.kind), [.text])
        XCTAssertEqual(items.map(\.sensitivity), [.plain])
    }

    func testExplicitTextTagKeepsPanelPasswordVisible() {
        let document = """
        Panel
        面板密码：public-note @text
        """

        let item = SmartDocumentParser.parse(document)[0].items[0]

        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.sensitivity, .plain)
        XCTAssertFalse(item.isHidden)
    }

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

    func testRedactsStandalonePanelURLBeforeFieldParsing() {
        let document = """
        1Panel
        http://198.51.100.42:9443/random-token
        """

        let item = SmartDocumentParser.parse(document)[0].items[0]

        XCTAssertEqual(item.label, "链接")
        XCTAssertEqual(item.kind, .url)
        XCTAssertEqual(item.value, "http://198.51.100.42:9443/random-token")
        XCTAssertEqual(item.displayValue, "http://198.51.100.42:9443/[已隐藏路径]")
        XCTAssertEqual(item.sensitivity, .redactedURL)
    }

    func testRedactsPanelURLQueryToken() {
        let document = """
        1Panel
        外部地址: http://198.51.100.42:9443?token=random-token
        """

        let item = SmartDocumentParser.parse(document)[0].items[0]

        XCTAssertEqual(item.value, "http://198.51.100.42:9443?token=random-token")
        XCTAssertEqual(item.displayValue, "http://198.51.100.42:9443/[已隐藏路径]")
        XCTAssertEqual(item.sensitivity, .redactedURL)
    }

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

    func testPlainURLKeepsFullDisplayValue() {
        let document = """
        Apple
        https://developer.apple.com/
        """

        let item = SmartDocumentParser.parse(document)[0].items[0]

        XCTAssertEqual(item.value, "https://developer.apple.com/")
        XCTAssertEqual(item.displayValue, "https://developer.apple.com/")
        XCTAssertEqual(item.sensitivity, .plain)
    }

    func testURLCredentialsAreNeverDisplayedOrSearchable() {
        let value = "https://demo-user:super-secret@example.com/admin"
        let entries = SmartDocumentParser.parse("Admin\n\(value)")
        let item = entries[0].items[0]
        let searchable = SmartDocumentParser.searchableText(for: entries)

        XCTAssertEqual(item.sensitivity, .redactedURL)
        XCTAssertFalse(item.displayValue.contains("demo-user"))
        XCTAssertFalse(item.displayValue.contains("super-secret"))
        XCTAssertFalse(searchable.contains("super-secret"))
    }

    func testSensitiveDomainQueryIsNeverDisplayedOrSearchable() {
        let value = "https://example.com/reset?token=super-secret"
        let entries = SmartDocumentParser.parse("Reset\n\(value)")
        let item = entries[0].items[0]
        let searchable = SmartDocumentParser.searchableText(for: entries)

        XCTAssertEqual(item.sensitivity, .redactedURL)
        XCTAssertFalse(item.displayValue.contains("super-secret"))
        XCTAssertFalse(searchable.contains("super-secret"))
    }

    func testOAuthFragmentTokenIsNeverDisplayedOrSearchable() {
        let value = "https://example.com/callback#access_token=super-secret"
        let entries = SmartDocumentParser.parse("OAuth\n\(value)")
        let item = entries[0].items[0]
        let searchable = SmartDocumentParser.searchableText(for: entries)

        XCTAssertEqual(item.sensitivity, .redactedURL)
        XCTAssertFalse(item.displayValue.contains("super-secret"))
        XCTAssertFalse(searchable.contains("super-secret"))
    }

    func testPanelIPv4URLWithoutPortStillRedactsPath() {
        let value = "http://198.51.100.42/random-token"
        let item = SmartDocumentParser.parse("1Panel\n外部地址：\(value)")[0].items[0]

        XCTAssertEqual(item.sensitivity, .redactedURL)
        XCTAssertEqual(item.displayValue, "http://198.51.100.42/[已隐藏路径]")
    }

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
        XCTAssertEqual(entries[0].items.map(\.kind), [.email, .password])
        XCTAssertEqual(entries[1].items.map(\.kind), [.password])
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

    func testStripsOnePanelLogPrefixBeforeParsingFields() {
        let document = """
        Example Service
        [1Panel 2026-01-01 install Log]: 外部地址： http://203.0.113.10:8443/random-token
        [1Panel 2026-01-01 install Log]: 面板用户： admin-user
        """

        let entry = SmartDocumentParser.parse(document)[0]

        XCTAssertEqual(entry.title, "Example Service")
        XCTAssertEqual(entry.items.map(\.label), ["外部地址", "面板用户"])
        XCTAssertEqual(entry.items.map(\.kind), [.url, .panelUser])
    }

    func testShortNoteLineInsideEntryDoesNotStartNewEntry() {
        let document = """
        正式服务器
        ssh root@192.0.2.106
        备用账号说明
        root-password-1234567890
        """

        let entries = SmartDocumentParser.parse(document)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "正式服务器")
    }

    func testParsingRulesDecodesOlderJSONWithoutEntryTitleKeywords() throws {
        let data = #"{"customSecretKeywords":["密码"],"customPlainTextKeywords":["备注"]}"#.data(using: .utf8)!

        let rules = try JSONDecoder().decode(ParsingRules.self, from: data)

        XCTAssertEqual(rules.customSecretKeywords, ["密码"])
        XCTAssertEqual(rules.customPlainTextKeywords, ["备注"])
        XCTAssertEqual(rules.customEntryTitleKeywords, [])
    }
}
