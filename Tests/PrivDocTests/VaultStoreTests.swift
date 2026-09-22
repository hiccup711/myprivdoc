import AppKit
import XCTest
@testable import PrivDoc

@MainActor
final class VaultStoreTests: XCTestCase {
    func testNewVaultDefaultsToDocumentPasswordSaveMode() {
        let store = makeStore()

        XCTAssertEqual(store.saveMode.rawValue, VaultSaveMode.password.rawValue)
    }

    func testSavingNewVaultCommitsDraftAndRequestsEncryptedFile() {
        let store = makeStore()
        store.newVault()
        store.documentDraft = "# 新密档\n\n账号：demo-user"

        let result = store.saveCurrentDocument()

        XCTAssertEqual(result, .requiresInitialSave)
        XCTAssertEqual(store.payload?.currentDocument, "# 新密档\n\n账号：demo-user")
        XCTAssertTrue(store.isSaveSheetPresented)
        XCTAssertTrue(store.hasUnpersistedChanges)
        XCTAssertNotEqual(store.toast?.text, "已保存为新版本")
    }

    func testSaveEncryptedFileFromEditorCommitsLatestDraftFirst() {
        let store = makeStore()
        store.newVault()
        store.documentDraft = "# 最新正文\n\n密码：{{demo-secret}}"

        store.requestSaveVaultFile()

        XCTAssertEqual(store.payload?.currentDocument, store.documentDraft)
        XCTAssertTrue(store.isSaveSheetPresented)
        XCTAssertEqual(store.payload?.versions.first?.document, store.documentDraft)
    }

    func testModeChangeDoesNotDiscardUnsavedDraftWithoutDecision() {
        let store = makeStore()
        store.newVault()
        store.fileURL = placeholderFileURL()
        store.requestModeChange(.edit)
        store.documentDraft += "\n未保存修改"

        store.requestModeChange(.history)

        XCTAssertEqual(store.mode, .edit)
        XCTAssertTrue(store.isLeaveConfirmationPresented)
        XCTAssertTrue(store.hasUnsavedDraft)

        store.cancelPendingAction()

        XCTAssertEqual(store.mode, .edit)
        XCTAssertTrue(store.hasUnsavedDraft)
    }

    func testDiscardingDraftContinuesRequestedModeChange() {
        let store = makeStore()
        store.newVault()
        let originalDocument = store.payload?.currentDocument
        store.fileURL = placeholderFileURL()
        store.requestModeChange(.edit)
        store.documentDraft += "\n未保存修改"
        store.requestModeChange(.history)

        store.discardAndContinuePendingAction()

        XCTAssertEqual(store.mode, .history)
        XCTAssertEqual(store.documentDraft, originalDocument)
        XCTAssertEqual(store.payload?.currentDocument, originalDocument)
    }

    func testLockRequiresDecisionWhenVaultHasNeverBeenSaved() {
        let store = makeStore()
        store.newVault()

        store.requestLock()

        XCTAssertTrue(store.isUnlocked)
        XCTAssertTrue(store.isLeaveConfirmationPresented)
        XCTAssertEqual(store.leaveConfirmationTitle, "密档还没有保存")

        store.discardAndContinuePendingAction()

        XCTAssertFalse(store.isUnlocked)
    }

    func testNewVaultMustBeEncryptedBeforeEnteringEditMode() {
        let store = makeStore()
        store.newVault()

        store.requestModeChange(.edit)

        XCTAssertEqual(store.mode, .view)
        XCTAssertTrue(store.isSaveSheetPresented)
        XCTAssertTrue(store.needsInitialFileSave)
    }

    func testClosingActionExplainsBothUnpersistedVersionAndDraft() {
        let store = makeStore()
        store.newVault()
        store.fileURL = placeholderFileURL()
        store.requestModeChange(.edit)
        store.documentDraft += "\n新的编辑草稿"

        store.requestLock()

        XCTAssertTrue(store.isLeaveConfirmationPresented)
        XCTAssertEqual(store.leaveConfirmationTitle, "有两层修改尚未写入文件")
        XCTAssertEqual(store.leaveConfirmationDiscardTitle, "放弃全部修改")
        XCTAssertTrue(store.leaveConfirmationMessage.contains("同时丢失"))
        store.cancelPendingAction()
    }

    func testApplicationTerminationRequiresDecisionForUnsavedVault() {
        let store = makeStore()
        store.newVault()

        store.requestApplicationTermination()

        XCTAssertTrue(store.isLeaveConfirmationPresented)
        XCTAssertEqual(store.leaveConfirmationTitle, "密档还没有保存")
        store.cancelPendingAction()
    }

    func testNewVaultPasswordMustBeEnteredTwice() {
        let store = makeStore()
        store.newVaultPassword = "correct-horse"
        store.newVaultPasswordConfirmation = "different-value"

        XCTAssertFalse(store.canSaveNewVault)

        store.newVaultPasswordConfirmation = "correct-horse"

        XCTAssertTrue(store.canSaveNewVault)
    }

    func testUneditedNewVaultLocksAfterConfiguredIdleDelay() async throws {
        let store = makeStore()
        store.newVault()

        store.updateAutoLockAfterSeconds(1)
        try await Task.sleep(nanoseconds: 1_250_000_000)

        XCTAssertFalse(store.isUnlocked)
    }

    func testFilteredSmartEntriesExcludeSecretValuesFromSearch() {
        let store = makeStore()
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

    func testAddEntryTitleKeywordStoresUniqueSortedRule() {
        let store = makeStore()

        // Chinese collation differs between the local and CI system locales.
        store.addEntryTitleKeyword("Zulu tools")
        store.addEntryTitleKeyword("zulu TOOLS")
        store.addEntryTitleKeyword("Alpha tools")

        XCTAssertEqual(store.globalParsingRules.customEntryTitleKeywords, ["Alpha tools", "Zulu tools"])
    }

    func testEntryTitleKeywordPersistsToInjectedDefaults() {
        let defaults = makeIsolatedDefaults()
        let store = VaultStore(rulesDefaults: defaults)
        store.addEntryTitleKeyword("内部工具")

        let reloaded = VaultStore(rulesDefaults: defaults)
        XCTAssertEqual(reloaded.globalParsingRules.customEntryTitleKeywords, ["内部工具"])
    }

    func testAddEntryTitleKeywordRejectsUnnamedPlaceholder() {
        let store = makeStore()

        store.addEntryTitleKeyword("未命名条目")

        XCTAssertTrue(store.globalParsingRules.customEntryTitleKeywords.isEmpty)
    }

    func testEntryTitleRuleLifecycleResegmentsEntriesAndPersistsRemoval() {
        let defaults = makeIsolatedDefaults()
        let store = VaultStore(rulesDefaults: defaults)
        store.payload = VaultPayload(
            currentDocument: """
            账号资料
            service@example.com
            first-secret-value-1234567890
            内部工具
            tool-secret-value-1234567890
            """,
            versions: [],
            settings: AppSettings()
        )
        store.selectedEntryID = store.smartEntries.first?.id

        XCTAssertEqual(store.smartEntries.count, 1)

        store.addEntryTitleKeyword("内部工具")

        XCTAssertEqual(store.smartEntries.map(\.title), ["账号资料", "内部工具"])
        XCTAssertNil(store.selectedEntryID)

        store.selectedEntryID = store.smartEntries.last?.id
        store.removeEntryTitleKeyword("内部工具")

        XCTAssertEqual(store.smartEntries.count, 1)
        XCTAssertNil(store.selectedEntryID)
        XCTAssertTrue(VaultStore(rulesDefaults: defaults).globalParsingRules.customEntryTitleKeywords.isEmpty)
    }

    func testAutomaticVersionSummaryNeverContainsSecretValues() {
        let store = makeStore()
        store.payload = VaultPayload(
            currentDocument: "## TITLE_SECRET_SENTINEL\nPassword：prefix {{ TITLE_SECRET_SENTINEL }} suffix\n账号：old@example.com",
            versions: [],
            settings: AppSettings()
        )
        store.documentDraft = "## TITLE_SECRET_SENTINEL\nPassword：prefix {{ TITLE_SECRET_SENTINEL }} suffix\n账号：new@example.com"

        store.saveCurrentDocument()

        let summary = store.payload?.versions.first?.summary ?? ""
        XCTAssertFalse(summary.contains("TITLE_SECRET_SENTINEL"))
    }

    func testUnlockSheetDismissalClearsTransientState() {
        let store = makeStore()
        store.isUnlockSheetPresented = false
        store.unlockPassword = "temporary-password"
        store.lastError = "旧错误"

        store.handleUnlockSheetDismissed()

        XCTAssertTrue(store.unlockPassword.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testCopySmartItemCopiesOriginalValueNotDisplayValue() {
        let store = makeStore()
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

    private func makeStore() -> VaultStore {
        VaultStore(rulesDefaults: makeIsolatedDefaults())
    }

    private func placeholderFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivDocTests-placeholder-\(UUID().uuidString).privdoc")
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "PrivDocTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
