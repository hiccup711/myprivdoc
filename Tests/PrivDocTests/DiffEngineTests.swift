import XCTest
@testable import PrivDoc

final class DiffEngineTests: XCTestCase {
    func testRepeatedFieldChangeDoesNotOverwriteSibling() throws {
        let before = """
        ## Accounts
        账号：alpha
        账号：beta
        """
        let after = """
        ## Accounts
        账号：changed
        账号：beta
        """

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(change.change, .changed)
        XCTAssertEqual(change.before, "alpha")
        XCTAssertEqual(change.after, "changed")
    }

    func testInsertingRepeatedFieldKeepsExistingValuesMatched() throws {
        let before = """
        ## Accounts
        账号：alpha
        账号：beta
        """
        let after = """
        ## Accounts
        账号：new
        账号：alpha
        账号：beta
        """

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(change.change, .added)
        XCTAssertEqual(change.after, "new")
    }

    func testRepeatedSectionsDoNotOverwriteEachOther() throws {
        let before = """
        ## Server
        账号：alpha
        ## Server
        账号：beta
        """
        let after = """
        ## Server
        账号：changed
        ## Server
        账号：beta
        """

        let diff = DiffEngine.diff(before: before, after: after)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.before, "alpha")
        XCTAssertEqual(diff.first?.after, "changed")
    }

    func testPlainParagraphChangeIsReported() throws {
        let before = "## Notes\nold paragraph with spaces"
        let after = "## Notes\nnew paragraph with spaces"

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(change.change, .changed)
        XCTAssertEqual(change.before, "old paragraph with spaces")
        XCTAssertEqual(change.after, "new paragraph with spaces")
    }

    func testBareSecretChangeIsReportedWithoutLeakingValues() throws {
        let before = "Secrets\n{{OLD_SECRET_SENTINEL}}"
        let after = "Secrets\n{{NEW_SECRET_SENTINEL}}"

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)

        XCTAssertEqual(diff.count, 1)
        XCTAssertTrue(change.isSecret)
        XCTAssertEqual(change.before, "已隐藏")
        XCTAssertEqual(change.after, "已隐藏")
        assertDoesNotContainSecrets(render(diff))
    }

    func testInlineSecretChangeIsReportedWithoutLeakingValues() throws {
        let before = "## Notes\n备注：公开 {{OLD_SECRET_SENTINEL}} 结束"
        let after = "## Notes\n备注：公开 {{NEW_SECRET_SENTINEL}} 结束"

        let diff = DiffEngine.diff(before: before, after: after)

        XCTAssertEqual(diff.count, 1)
        XCTAssertTrue(diff[0].isSecret)
        assertDoesNotContainSecrets(render(diff))
    }

    func testEmailAndSSHChangesUseSmartItems() {
        let before = """
        Account
        old@example.com

        Server
        ssh root@192.0.2.10
        stable-password-value
        """
        let after = """
        Account
        new@example.com

        Server
        ssh root@198.51.100.20
        stable-password-value
        """

        let diff = DiffEngine.diff(before: before, after: after)
        let output = render(diff)

        XCTAssertEqual(diff.count, 2)
        XCTAssertTrue(output.contains("old@example.com"))
        XCTAssertTrue(output.contains("new@example.com"))
        XCTAssertTrue(output.contains("192.0.2.10"))
        XCTAssertTrue(output.contains("198.51.100.20"))
        XCTAssertFalse(output.contains("stable-password-value"))
    }

    func testSensitiveURLChangeUsesRedactedDisplayValues() throws {
        let before = "Panel\nhttps://example.com/reset?token=OLD_SECRET_SENTINEL"
        let after = "Panel\nhttps://example.com/reset?token=NEW_SECRET_SENTINEL"

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)
        let output = render(diff)

        XCTAssertEqual(diff.count, 1)
        XCTAssertFalse(change.isSecret)
        XCTAssertTrue(output.contains("example.com"))
        assertDoesNotContainSecrets(output)
    }

    func testMalformedSensitiveURLFailsClosed() throws {
        let before = "Panel\nhttps://demo-user:URL_PASSWORD_SENTINEL@example.com:bad/reset?token=OLD_SECRET_SENTINEL"
        let after = "Panel\nhttps://demo-user:URL_PASSWORD_SENTINEL@example.com:bad/reset?token=NEW_SECRET_SENTINEL"

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)
        let output = render(diff) + DiffEngine.redactedDocument(after)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(change.before, "[已隐藏链接]")
        XCTAssertEqual(change.after, "[已隐藏链接]")
        XCTAssertFalse(output.contains("URL_PASSWORD_SENTINEL"))
        assertDoesNotContainSecrets(output)
    }

    func testSensitiveURLInHeadingIsRedactedFromTitlesAndPreview() throws {
        let heading = "## https://demo-user:URL_PASSWORD_SENTINEL@example.com/private?token=OLD_SECRET_SENTINEL"
        let before = "\(heading)\n账号：old@example.com"
        let after = "\(heading)\n账号：new@example.com"

        let diff = DiffEngine.diff(before: before, after: after)
        let change = try XCTUnwrap(diff.first)
        let output = render(diff) + DiffEngine.redactedDocument(after)

        XCTAssertEqual(diff.count, 1)
        XCTAssertTrue(change.title.contains("example.com"))
        XCTAssertFalse(output.contains("demo-user"))
        XCTAssertFalse(output.contains("URL_PASSWORD_SENTINEL"))
        assertDoesNotContainSecrets(output)

        let ipv6Preview = DiffEngine.redactedDocument(
            "## https://[2001:db8::1]/reset?token=IPV6_SECRET_SENTINEL"
        )
        XCTAssertTrue(ipv6Preview.contains("[2001:db8::1]"))
        XCTAssertFalse(ipv6Preview.contains("IPV6_SECRET_SENTINEL"))
    }

    func testSecretSensitivitySurvivesFieldRename() {
        let before = "Password：CROSS_IDENTITY_SECRET_SENTINEL"
        let after = "Note：CROSS_IDENTITY_SECRET_SENTINEL @text"

        let diff = DiffEngine.diff(before: before, after: after)
        let output = render(diff)

        XCTAssertEqual(diff.count, 2)
        XCTAssertTrue(diff.allSatisfy(\.isSecret))
        XCTAssertFalse(output.contains("CROSS_IDENTITY_SECRET_SENTINEL"))

        let titleBefore = "## TITLE_SECRET_SENTINEL\nPassword：TITLE_SECRET_SENTINEL\n账号：old@example.com"
        let titleAfter = "## TITLE_SECRET_SENTINEL\nPassword：TITLE_SECRET_SENTINEL\n账号：new@example.com"
        let titleOutput = render(DiffEngine.diff(before: titleBefore, after: titleAfter))
            + DiffEngine.redactedDocument(titleAfter)
        XCTAssertFalse(titleOutput.contains("TITLE_SECRET_SENTINEL"))

        let fragmentBefore = "## FRAGMENT_SECRET_SENTINEL\nPassword：prefix {{ FRAGMENT_SECRET_SENTINEL }} suffix\n账号：old@example.com"
        let fragmentAfter = "## FRAGMENT_SECRET_SENTINEL\nPassword：prefix {{ FRAGMENT_SECRET_SENTINEL }} suffix\n账号：new@example.com"
        let fragmentOutput = render(DiffEngine.diff(before: fragmentBefore, after: fragmentAfter))
            + DiffEngine.redactedDocument(fragmentAfter)
        XCTAssertFalse(fragmentOutput.contains("FRAGMENT_SECRET_SENTINEL"))

        let valueBefore = "Token：{{ SHARED_SECRET_SENTINEL }}\nNote：prefix SHARED_SECRET_SENTINEL old @text"
        let valueAfter = "Token：{{ SHARED_SECRET_SENTINEL }}\nNote：prefix SHARED_SECRET_SENTINEL new @text"
        let valueOutput = render(DiffEngine.diff(before: valueBefore, after: valueAfter))
        XCTAssertTrue(valueOutput.contains("prefix [已隐藏]"))
        XCTAssertFalse(valueOutput.contains("SHARED_SECRET_SENTINEL"))
    }

    func testRedactedURLSensitivitySurvivesLabelChange() {
        let url = "https://example.com/private-path-token"
        let before = "Panel\n外部地址：\(url)"
        let after = "Panel\n公开链接：\(url) @text"

        let output = render(DiffEngine.diff(before: before, after: after))

        XCTAssertTrue(output.contains("example.com"))
        XCTAssertFalse(output.contains("private-path-token"))
    }

    func testHistoricalPreviewRedactsSmartSecretsAndSensitiveURLs() {
        let document = """
        Secrets
        {{OLD_SECRET_SENTINEL}}

        OAuth
        https://demo-user:URL_PASSWORD_SENTINEL@example.com/callback#access_token=OLD_SECRET_SENTINEL
        """

        let preview = DiffEngine.redactedDocument(document)

        XCTAssertTrue(preview.contains("example.com"))
        XCTAssertTrue(preview.contains("已隐藏"))
        XCTAssertFalse(preview.contains("demo-user"))
        XCTAssertFalse(preview.contains("URL_PASSWORD_SENTINEL"))
        assertDoesNotContainSecrets(preview)
    }

    func testIdenticalDocumentsHaveNoDiff() {
        let document = "## Notes\n正文内容\nToken：{{OLD_SECRET_SENTINEL}}"

        XCTAssertTrue(DiffEngine.diff(before: document, after: document).isEmpty)
    }

    private func render(_ diff: [DiffLine]) -> String {
        diff.flatMap { [$0.title, $0.before ?? "", $0.after ?? ""] }.joined(separator: "\n")
    }

    private func assertDoesNotContainSecrets(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(text.contains("OLD_SECRET_SENTINEL"), file: file, line: line)
        XCTAssertFalse(text.contains("NEW_SECRET_SENTINEL"), file: file, line: line)
    }
}
