import AppKit
import Foundation
import SwiftUI

enum VaultSaveResult: Equatable {
    case saved
    case requiresInitialSave
    case failed
}

@MainActor
final class VaultStore: ObservableObject {
    @Published var payload: VaultPayload?
    @Published var documentDraft: String = ""
    @Published private(set) var mode: AppMode = .view
    @Published var searchQuery: String = ""
    @Published var selectedSectionID: String?
    @Published var selectedEntryID: String?
    @Published var toast: ToastMessage?
    @Published var globalParsingRules: ParsingRules
    @Published var isUnlockSheetPresented = false
    @Published var isSaveSheetPresented = false
    @Published var unlockPassword = ""
    @Published var newVaultPassword = ""
    @Published var newVaultPasswordConfirmation = ""
    @Published var saveMode: VaultSaveMode = .password
    @Published var fileURL: URL?
    @Published var lastError: String?
    @Published var isSavingVault = false
    @Published var isUnlockingVault = false
    @Published var clipboardHasPrivDocContent = false
    @Published var isLeaveConfirmationPresented = false
    @Published private(set) var hasUnpersistedChanges = false

    private var clipboardTimer: Timer?
    private var autoLockTimer: Timer?
    private var toastTimer: Timer?
    private var activityMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingOpenURL: URL?
    private var pendingAction: PendingAction?
    private var leaveConfirmationReason: LeaveConfirmationReason?
    private var terminationApproved = false
    private var sessionAuth: SessionAuth?
    private var lastPrivDocPasteboardChangeCount: Int?
    private let rulesDefaults: UserDefaults
    private let rulesDefaultsKey = "local.privdoc.parsingRules.v1"

    init(rulesDefaults: UserDefaults = .standard) {
        self.rulesDefaults = rulesDefaults
        self.globalParsingRules = Self.loadGlobalParsingRules(from: rulesDefaults)
    }

    var isUnlocked: Bool { payload != nil }

    var hasUnsavedDraft: Bool {
        guard let payload else { return false }
        return documentDraft != payload.currentDocument
    }

    var needsInitialFileSave: Bool {
        isUnlocked && fileURL == nil
    }

    var canSaveNewVault: Bool {
        !newVaultPassword.isEmpty && newVaultPassword == newVaultPasswordConfirmation
    }

    var requiresSaveBeforeLeaving: Bool {
        hasUnsavedDraft || needsInitialFileSave || hasUnpersistedChanges
    }

    var leaveConfirmationTitle: String {
        switch leaveConfirmationReason {
        case .unpersistedVault:
            return "密档还没有保存"
        case .unpersistedChanges:
            return "修改还没有写入文件"
        case .unsavedDraft:
            return "有未保存的编辑"
        case .unsavedDraftAndUnpersistedChanges:
            return "有两层修改尚未写入文件"
        case nil:
            return "要离开当前内容吗？"
        }
    }

    var leaveConfirmationMessage: String {
        switch leaveConfirmationReason {
        case .unpersistedVault:
            return "当前密档只存在于内存中。继续离开会永久丢失这些内容。"
        case .unpersistedChanges:
            return "上次写入加密文件没有成功。继续离开会丢失这次修改。"
        case .unsavedDraft:
            return "保存会创建一个新版本；放弃会恢复到编辑前的内容。"
        case .unsavedDraftAndUnpersistedChanges:
            return "既有上次写入失败后保留的修改，也有当前编辑草稿。放弃会同时丢失两部分内容。"
        case nil:
            return ""
        }
    }

    var leaveConfirmationSaveTitle: String {
        leaveConfirmationReason == .unpersistedVault ? "保存加密文件" : "保存修改"
    }

    var leaveConfirmationDiscardTitle: String {
        switch leaveConfirmationReason {
        case .unpersistedVault:
            return "放弃密档"
        case .unsavedDraftAndUnpersistedChanges:
            return "放弃全部修改"
        default:
            return "放弃修改"
        }
    }

    var leaveConfirmationCancelTitle: String {
        switch leaveConfirmationReason {
        case .unsavedDraft, .unsavedDraftAndUnpersistedChanges:
            return "继续编辑"
        default:
            return "取消"
        }
    }

    var sections: [DocumentSection] {
        DocumentParser.parse(payload?.currentDocument ?? "", rules: globalParsingRules)
    }

    var smartEntries: [SmartEntry] {
        SmartDocumentParser.parse(payload?.currentDocument ?? "", rules: globalParsingRules)
    }

    var documentTitle: String {
        DocumentParser.documentTitle(payload?.currentDocument ?? "") ?? "未命名密档"
    }

    var filteredSections: [DocumentSection] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }

        return sections.compactMap { section in
            let matchedLines = section.lines.filter { line in
                lineMatches(line, query: query) || section.title.localizedCaseInsensitiveContains(query)
            }
            if matchedLines.isEmpty { return nil }
            return DocumentSection(id: section.id, title: section.title, lines: matchedLines)
        }
    }

    var selectedSection: DocumentSection? {
        guard let selectedSectionID else { return nil }
        return filteredSections.first(where: { $0.id == selectedSectionID })
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

    func newVault() {
        payload = .empty
        documentDraft = VaultPayload.empty.currentDocument
        fileURL = nil
        sessionAuth = nil
        saveMode = .password
        newVaultPassword = ""
        newVaultPasswordConfirmation = ""
        hasUnpersistedChanges = true
        mode = .view
        selectedSectionID = nil
        selectedEntryID = nil
        clearPendingAction()
        startAutoLockProtection()
        showToast("已新建密档，记得保存为加密文件", kind: .saved)
    }

    func requestNewVault() {
        request(.newVault)
    }

    func requestOpenVaultPanel() {
        request(.openVault)
    }

    func requestModeChange(_ nextMode: AppMode) {
        guard nextMode != mode else { return }

        if needsInitialFileSave, nextMode != .view {
            pendingAction = .mode(nextMode)
            if hasUnsavedDraft {
                _ = saveCurrentDocument()
            } else {
                presentSaveVaultSheet()
            }
            return
        }

        request(.mode(nextMode))
    }

    func requestLock() {
        request(.lock)
    }

    func requestApplicationTermination() {
        guard !isSaveSheetPresented, !isUnlockSheetPresented else {
            showToast("请先完成或取消当前操作", kind: .error)
            return
        }
        request(.terminate)
    }

    func consumeTerminationApproval() -> Bool {
        guard terminationApproved else { return false }
        terminationApproved = false
        return true
    }

    func requestSaveVaultFile() {
        if hasUnsavedDraft {
            _ = saveCurrentDocument()
        } else {
            presentSaveVaultSheet()
        }
    }

    func saveAndContinuePendingAction() {
        isLeaveConfirmationPresented = false

        if hasUnsavedDraft {
            switch saveCurrentDocument() {
            case .saved:
                continuePendingAction()
            case .requiresInitialSave, .failed:
                break
            }
            return
        }

        if needsInitialFileSave {
            presentSaveVaultSheet()
            return
        }

        if hasUnpersistedChanges {
            if persistIfPossible() {
                continuePendingAction()
            }
            return
        }

        continuePendingAction()
    }

    func discardAndContinuePendingAction() {
        isLeaveConfirmationPresented = false
        if hasUnsavedDraft {
            documentDraft = payload?.currentDocument ?? ""
        }
        continuePendingAction()
    }

    func cancelPendingAction() {
        clearPendingAction()
    }

    func cancelSaveVaultSheet() {
        isSaveSheetPresented = false
        newVaultPassword = ""
        newVaultPasswordConfirmation = ""
        clearPendingAction()
    }

    func handleSaveSheetDismissed() {
        guard !isSaveSheetPresented else { return }
        newVaultPassword = ""
        newVaultPasswordConfirmation = ""
        clearPendingAction()
    }

    func openVaultPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "privdoc")!]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            pendingOpenURL = url
            unlockPassword = ""
            lastError = nil
            Task {
                await unlockSelectedVault(url)
            }
        }
    }

    func unlockPendingVault() {
        guard let url = pendingOpenURL, !isUnlockingVault else { return }
        let password = unlockPassword
        guard !password.isEmpty else { return }
        lastError = nil
        isUnlockingVault = true

        Task {
            await unlockPendingVault(url: url, password: password)
        }
    }

    func cancelUnlockSheet() {
        guard !isUnlockingVault else { return }
        isUnlockSheetPresented = false
        clearUnlockRequest()
    }

    func handleUnlockSheetDismissed() {
        guard !isUnlockSheetPresented, !isUnlockingVault else { return }
        clearUnlockRequest()
    }

    private func clearUnlockRequest() {
        pendingOpenURL = nil
        unlockPassword = ""
        lastError = nil
    }

    private func unlockPendingVault(url: URL, password: String) async {
        defer { isUnlockingVault = false }

        do {
            let data = try Data(contentsOf: url)
            let payload = try await CryptoBox.decryptAsync(data: data, password: password)
            self.payload = payload
            self.documentDraft = payload.currentDocument
            self.fileURL = url
            self.sessionAuth = .password(password)
            self.hasUnpersistedChanges = false
            self.mode = .view
            self.selectedSectionID = nil
            self.selectedEntryID = nil
            self.pendingOpenURL = nil
            self.unlockPassword = ""
            self.isUnlockSheetPresented = false
            startAutoLockProtection()
            showToast("密档已解锁", kind: .saved)
        } catch {
            lastError = error.localizedDescription
            showToast(error.localizedDescription, kind: .error)
        }
    }

    func lock() {
        clearClipboardIfOwned(showFeedback: false)
        payload = nil
        documentDraft = ""
        sessionAuth = nil
        hasUnpersistedChanges = false
        isUnlockingVault = false
        stopAutoLockProtection()
        mode = .view
        searchQuery = ""
        selectedSectionID = nil
        selectedEntryID = nil
        isSaveSheetPresented = false
        newVaultPassword = ""
        newVaultPasswordConfirmation = ""
        clearPendingAction()
        showToast("密档已锁定", kind: .locked)
    }

    private func beginEditing() {
        guard let payload else { return }
        documentDraft = payload.currentDocument
        mode = .edit
    }

    func cancelEditing() {
        documentDraft = payload?.currentDocument ?? ""
        mode = .view
    }

    @discardableResult
    func saveCurrentDocument(summary: String? = nil) -> VaultSaveResult {
        guard var payload else { return .failed }
        let nextDocument = documentDraft
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionSummary = trimmedSummary?.isEmpty == false ? trimmedSummary! : automaticSummary(before: payload.currentDocument, after: nextDocument)

        let didChange = payload.currentDocument != nextDocument
        if didChange {
            payload.currentDocument = nextDocument
            payload.versions.insert(
                DocumentVersion(id: UUID(), createdAt: Date(), summary: versionSummary, document: nextDocument),
                at: 0
            )
            self.payload = payload
            hasUnpersistedChanges = true
        }

        mode = .view
        guard fileURL != nil else {
            presentSaveVaultSheet()
            return .requiresInitialSave
        }

        guard persistIfPossible() else {
            return .failed
        }

        showToast(didChange ? "已保存为新版本" : "没有内容变更", kind: .saved)
        return .saved
    }

    func saveAsPanel(mode: VaultSaveMode, password: String) async {
        guard let payload else { return }
        if mode == .password {
            guard !password.isEmpty else {
                showToast("请输入文档密码", kind: .error)
                return
            }
            guard password == newVaultPasswordConfirmation else {
                showToast("两次输入的密码不一致", kind: .error)
                return
            }
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "privdoc")!]
        panel.nameFieldStringValue = "MySecrets.privdoc"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isSavingVault = true
        defer { isSavingVault = false }

        do {
            let encrypted: Data
            let nextSessionAuth: SessionAuth
            switch mode {
            case .system:
                try await KeychainVaultKeyStore.authorize(reason: "创建 PrivDoc 系统授权密钥")
                let keyID = UUID().uuidString
                let key = try KeychainVaultKeyStore.generateKey()
                do {
                    try KeychainVaultKeyStore.saveKey(key, keyID: keyID)
                } catch {
                    saveMode = .password
                    throw error
                }
                encrypted = try await CryptoBox.encryptAsync(payload: payload, rawKey: key, keyID: keyID)
                nextSessionAuth = .system(keyID: keyID, key: key)
            case .password:
                encrypted = try await CryptoBox.encryptAsync(payload: payload, password: password)
                nextSessionAuth = .password(password)
            }
            try encrypted.write(to: url, options: .atomic)
            sessionAuth = nextSessionAuth
            fileURL = url
            hasUnpersistedChanges = false
            newVaultPassword = ""
            newVaultPasswordConfirmation = ""
            isSaveSheetPresented = false
            showToast("加密文件已保存", kind: .saved)
            continuePendingAction()
        } catch {
            showToast(error.localizedDescription, kind: .error)
        }
    }

    @discardableResult
    func persistIfPossible() -> Bool {
        guard let payload, let fileURL else { return false }
        guard let sessionAuth else {
            showToast("当前密档缺少加密凭据，无法保存", kind: .error)
            return false
        }

        do {
            let encrypted: Data
            switch sessionAuth {
            case let .password(password):
                encrypted = try CryptoBox.encrypt(payload: payload, password: password)
            case let .system(keyID, key):
                encrypted = try CryptoBox.encrypt(payload: payload, rawKey: key, keyID: keyID)
            }
            try encrypted.write(to: fileURL, options: .atomic)
            hasUnpersistedChanges = false
            return true
        } catch {
            showToast(error.localizedDescription, kind: .error)
            return false
        }
    }

    func copyFieldValue(_ field: Field) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(field.value, forType: .string)
        lastPrivDocPasteboardChangeCount = NSPasteboard.general.changeCount
        clipboardHasPrivDocContent = true
        scheduleClipboardClear()
        showToast(payload?.settings.clipboardClearDelay.copyFeedbackText ?? ClipboardClearDelay.seconds15.copyFeedbackText, kind: .copied)
    }

    func copyLine(_ field: Field, revealSecret: Bool = false) {
        let value = field.type == .secret && !revealSecret ? "已隐藏" : field.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(field.name): \(value)", forType: .string)
        lastPrivDocPasteboardChangeCount = NSPasteboard.general.changeCount
        clipboardHasPrivDocContent = true
        scheduleClipboardClear()
        showToast("整行已复制", kind: .copied)
    }

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

    func copySecretValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        lastPrivDocPasteboardChangeCount = NSPasteboard.general.changeCount
        clipboardHasPrivDocContent = true
        scheduleClipboardClear()
        showToast(payload?.settings.clipboardClearDelay.copyFeedbackText ?? ClipboardClearDelay.seconds15.copyFeedbackText, kind: .copied)
    }

    func clearClipboardIfOwned(showFeedback: Bool = true) {
        guard clipboardHasPrivDocContent,
              let lastPrivDocPasteboardChangeCount,
              NSPasteboard.general.changeCount == lastPrivDocPasteboardChangeCount else {
            clipboardHasPrivDocContent = false
            self.lastPrivDocPasteboardChangeCount = nil
            clipboardTimer?.invalidate()
            return
        }

        NSPasteboard.general.clearContents()
        clipboardHasPrivDocContent = false
        self.lastPrivDocPasteboardChangeCount = nil
        clipboardTimer?.invalidate()

        if showFeedback {
            showToast("剪贴板已清除", kind: .locked)
        }
    }

    func updateClipboardClearDelay(_ delay: ClipboardClearDelay) {
        guard var payload else { return }
        let previousDelay = payload.settings.clipboardClearDelay
        payload.settings.clipboardClearDelay = delay
        self.payload = payload
        hasUnpersistedChanges = true
        let shouldPersist = fileURL != nil
        if shouldPersist, !persistIfPossible() {
            return
        }

        if delay == .manual, previousDelay != .manual {
            showToast("已改为手动清除剪贴板", kind: .locked)
        } else {
            showToast("剪贴板清理时间已更新", kind: .saved)
        }

        if clipboardHasPrivDocContent {
            scheduleClipboardClear()
        }
    }

    func updateAutoLockAfterSeconds(_ seconds: Int) {
        guard var payload else { return }
        let normalizedSeconds = max(0, seconds)
        payload.settings.autoLockAfterSeconds = normalizedSeconds
        self.payload = payload
        hasUnpersistedChanges = true
        let shouldPersist = fileURL != nil
        if shouldPersist, !persistIfPossible() {
            scheduleAutoLock()
            return
        }
        scheduleAutoLock()
        showToast("自动锁定时间已更新", kind: .saved)
    }

    func recordActivity() {
        guard isUnlocked else { return }
        scheduleAutoLock()
    }

    func openURLField(_ field: Field) {
        guard let url = URL(string: field.value) else { return }
        NSWorkspace.shared.open(url)
    }

    func openSmartItemURL(_ item: SmartItem) {
        guard item.kind == .url, let url = URL(string: item.value) else { return }
        NSWorkspace.shared.open(url)
    }

    func restore(version: DocumentVersion) {
        documentDraft = version.document
        saveCurrentDocument(summary: "恢复版本 \(version.createdAt.formatted(date: .numeric, time: .shortened))")
    }

    func diffFromPrevious(version: DocumentVersion) -> [DiffLine] {
        guard let payload,
              let index = payload.versions.firstIndex(where: { $0.id == version.id }),
              payload.versions.indices.contains(index + 1) else {
            return []
        }
        return DiffEngine.diff(
            before: payload.versions[index + 1].document,
            after: version.document,
            rules: globalParsingRules
        )
    }

    func addSecretKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .secret, shouldAdd: true)
    }

    func addPlainTextKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .plainText, shouldAdd: true)
    }

    func addEntryTitleKeyword(_ keyword: String) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != "未命名条目" else { return }
        updateKeywords(normalized, target: .entryTitle, shouldAdd: true)
    }

    func removeSecretKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .secret, shouldAdd: false)
    }

    func removePlainTextKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .plainText, shouldAdd: false)
    }

    func removeEntryTitleKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .entryTitle, shouldAdd: false)
    }

    func showToast(_ text: String, kind: ToastKind) {
        toast = ToastMessage(text: text, kind: kind)
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.toast = nil }
        }
    }

    private func scheduleClipboardClear() {
        clipboardTimer?.invalidate()
        guard let seconds = payload?.settings.clipboardClearDelay.seconds ?? ClipboardClearDelay.seconds15.seconds else {
            return
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { _ in
            Task { @MainActor in
                self.clearClipboardIfOwned(showFeedback: false)
            }
        }
    }

    private func lineMatches(_ line: ParsedLine, query: String) -> Bool {
        switch line.kind {
        case let .heading(title, _):
            return title.localizedCaseInsensitiveContains(query)
        case let .field(field):
            if field.name.localizedCaseInsensitiveContains(query) { return true }
            if field.type != .secret && field.value.localizedCaseInsensitiveContains(query) { return true }
            return false
        case .secret:
            return false
        case let .richParagraph(segments):
            return segments
                .filter { !$0.isSecret }
                .map(\.text)
                .joined()
                .localizedCaseInsensitiveContains(query)
        case let .paragraph(text):
            return text.localizedCaseInsensitiveContains(query)
        case .empty:
            return false
        }
    }

    private func automaticSummary(before: String, after: String) -> String {
        let changes = DiffEngine.diff(before: before, after: after, rules: globalParsingRules)
        if changes.isEmpty { return "保存文档" }
        if let first = changes.first {
            return "\(first.change.rawValue) \(first.title)"
        }
        return "更新文档"
    }

    private enum KeywordTarget {
        case secret
        case plainText
        case entryTitle
    }

    private func updateKeywords(_ keyword: String, target: KeywordTarget, shouldAdd: Bool) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let currentKeywords: [String]
        switch target {
        case .secret:
            currentKeywords = globalParsingRules.customSecretKeywords
        case .plainText:
            currentKeywords = globalParsingRules.customPlainTextKeywords
        case .entryTitle:
            currentKeywords = globalParsingRules.customEntryTitleKeywords
        }

        let nextKeywords = updatedKeywords(currentKeywords, keyword: normalized, shouldAdd: shouldAdd)
        guard nextKeywords != currentKeywords else { return }

        switch target {
        case .secret:
            globalParsingRules.customSecretKeywords = nextKeywords
        case .plainText:
            globalParsingRules.customPlainTextKeywords = nextKeywords
        case .entryTitle:
            globalParsingRules.customEntryTitleKeywords = nextKeywords
            selectedEntryID = nil
        }

        saveGlobalParsingRules()
        showToast(shouldAdd ? "规则已添加" : "规则已移除", kind: .saved)
    }

    private func updatedKeywords(_ keywords: [String], keyword: String, shouldAdd: Bool) -> [String] {
        if shouldAdd {
            guard !keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else {
                return keywords
            }
            return (keywords + [keyword]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        return keywords.filter { $0.caseInsensitiveCompare(keyword) != .orderedSame }
    }

    private static func loadGlobalParsingRules(from defaults: UserDefaults) -> ParsingRules {
        guard let data = defaults.data(forKey: "local.privdoc.parsingRules.v1"),
              let rules = try? JSONDecoder().decode(ParsingRules.self, from: data) else {
            return ParsingRules()
        }
        return rules
    }

    private func saveGlobalParsingRules() {
        if let data = try? JSONEncoder().encode(globalParsingRules) {
            rulesDefaults.set(data, forKey: rulesDefaultsKey)
        }
    }

    private func unlockSelectedVault(_ url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let info = try CryptoBox.inspect(data: data)
            switch info.mode {
            case .system:
                guard let keyID = info.keyID else { throw CryptoError.invalidFormat }
                try await KeychainVaultKeyStore.authorize(reason: "解锁 PrivDoc 密档")
                let key = try KeychainVaultKeyStore.loadKey(keyID: keyID, reason: "解锁 PrivDoc 密档")
                let payload = try await CryptoBox.decryptAsync(data: data, rawKey: key)
                self.payload = payload
                self.documentDraft = payload.currentDocument
                self.fileURL = url
                self.sessionAuth = .system(keyID: keyID, key: key)
                self.hasUnpersistedChanges = false
                self.mode = .view
                self.selectedSectionID = nil
                self.selectedEntryID = nil
                self.pendingOpenURL = nil
                startAutoLockProtection()
                showToast("已通过 macOS 授权解锁", kind: .saved)
            case .password:
                pendingOpenURL = url
                isUnlockSheetPresented = true
            }
        } catch {
            lastError = error.localizedDescription
            showToast(error.localizedDescription, kind: .error)
        }
    }

    private enum SessionAuth {
        case password(String)
        case system(keyID: String, key: Data)
    }

    private enum PendingAction {
        case mode(AppMode)
        case lock
        case newVault
        case openVault
        case terminate
    }

    private enum LeaveConfirmationReason {
        case unsavedDraft
        case unsavedDraftAndUnpersistedChanges
        case unpersistedVault
        case unpersistedChanges
    }

    private func request(_ action: PendingAction) {
        if let reason = confirmationReason(for: action) {
            pendingAction = action
            leaveConfirmationReason = reason
            isLeaveConfirmationPresented = true
            return
        }

        perform(action)
    }

    private func confirmationReason(for action: PendingAction) -> LeaveConfirmationReason? {
        switch action {
        case .mode:
            return hasUnsavedDraft ? .unsavedDraft : nil
        case .lock, .newVault, .openVault, .terminate:
            if needsInitialFileSave {
                return .unpersistedVault
            }
            if hasUnsavedDraft, hasUnpersistedChanges {
                return .unsavedDraftAndUnpersistedChanges
            }
            if hasUnsavedDraft {
                return .unsavedDraft
            }
            return hasUnpersistedChanges ? .unpersistedChanges : nil
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case let .mode(nextMode):
            if nextMode == .edit {
                beginEditing()
            } else {
                mode = nextMode
            }
        case .lock:
            lock()
        case .newVault:
            newVault()
        case .openVault:
            openVaultPanel()
        case .terminate:
            terminationApproved = true
            NSApplication.shared.terminate(nil)
        }
    }

    private func continuePendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        leaveConfirmationReason = nil
        isLeaveConfirmationPresented = false
        perform(action)
    }

    private func clearPendingAction() {
        pendingAction = nil
        leaveConfirmationReason = nil
        isLeaveConfirmationPresented = false
    }

    private func presentSaveVaultSheet() {
        newVaultPassword = ""
        newVaultPasswordConfirmation = ""
        isSaveSheetPresented = true
    }

    private func startAutoLockProtection() {
        startActivityMonitor()
        startWorkspaceObservers()
        scheduleAutoLock()
    }

    private func stopAutoLockProtection() {
        autoLockTimer?.invalidate()
        autoLockTimer = nil
        stopActivityMonitor()
        stopWorkspaceObservers()
    }

    private func scheduleAutoLock() {
        autoLockTimer?.invalidate()
        autoLockTimer = nil

        guard let seconds = payload?.settings.autoLockAfterSeconds, seconds > 0 else {
            return
        }

        autoLockTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard self?.isUnlocked == true else { return }
                self?.lockForSecurityEvent()
            }
        }
    }

    private func startActivityMonitor() {
        guard activityMonitor == nil else { return }

        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor in
                self?.recordActivity()
            }
            return event
        }
    }

    private func stopActivityMonitor() {
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
    }

    private func startWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        let notifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification
        ]

        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if self?.isUnlocked == true {
                        self?.lockForSecurityEvent()
                    }
                }
            }
        }
    }

    private func stopWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func lockForSecurityEvent() {
        if fileURL != nil {
            if hasUnsavedDraft {
                _ = saveCurrentDocument(summary: "自动锁定前保存")
            } else if hasUnpersistedChanges {
                _ = persistIfPossible()
            }
        }

        let discardedChanges = needsInitialFileSave || hasUnsavedDraft || hasUnpersistedChanges
        lock()
        if discardedChanges {
            showToast("已锁定；未写入文件的内容已清除", kind: .error)
        }
    }
}
