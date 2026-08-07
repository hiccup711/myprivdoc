import XCTest
@testable import PrivDoc

final class DocumentParserTests: XCTestCase {
    func testHistoricalPreviewUsesTheSameEarliestSeparatorAsFieldParsing() {
        let document = "Password: abc：def"

        let redacted = DocumentParser.redactedDocument(document)

        XCTAssertEqual(redacted, "Password: [已隐藏]")
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertFalse(redacted.contains("def"))
    }
}
