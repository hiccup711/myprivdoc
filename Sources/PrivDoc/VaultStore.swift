import AppKit
import Foundation
import SwiftUI

@MainActor
final class VaultStore: ObservableObject {
    @Published var payload: VaultPayload?
    @Published var documentDraft: String = ""
    @Published var mode: AppMode = .view
    @Published var searchQuery: String = ""
    @Published var selectedSectionID: String?
    @Published var toast: ToastMessage?
    @Published var globalParsingRules: ParsingRules
    @Published var isUnlockSheetPresented = false
    @Published var isSaveSheetPresented = false
    @Published var unlockPassword = ""
    @Published var newVaultPassword = ""
    @Published var fileURL: URL?
    @Published var lastError: String?
    @Published var isSavingVault = false
    @Published var clipboardHasPrivDocContent = false

    private var clipboardTimer: Timer?
    private var toastTimer: Timer?
    private var pendingOpenURL: URL?
    private var sessionAuth: SessionAuth?
    private var lastPrivDocPasteboardChangeCount: Int?
    private let rulesDefaultsKey = "local.privdoc.parsingRules.v1"

    init() {
        self.globalParsingRules = Self.loadGlobalParsingRules()
    }

    var isUnlocked: Bool { payload != nil }

    var sections: [DocumentSection] {
        DocumentParser.parse(payload?.currentDocument ?? "", rules: globalParsingRules)
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

    func newVault() {
        payload = .empty
        documentDraft = VaultPayload.empty.currentDocument
        fileURL = nil
        mode = .view
        selectedSectionID = nil
        showToast("已新建密档，记得保存为加密文件", kind: .saved)
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
            Task {
                await unlockSelectedVault(url)
            }
        }
    }

    func unlockPendingVault() {
        guard let url = pendingOpenURL else { return }
        do {
            let data = try Data(contentsOf: url)
            let payload = try CryptoBox.decrypt(data: data, password: unlockPassword)
            self.payload = payload
            self.documentDraft = payload.currentDocument
            self.fileURL = url
            self.sessionAuth = .password(unlockPassword)
            self.mode = .view
            self.selectedSectionID = nil
            self.pendingOpenURL = nil
            self.unlockPassword = ""
            self.isUnlockSheetPresented = false
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
        mode = .view
        searchQuery = ""
        selectedSectionID = nil
        showToast("密档已锁定", kind: .locked)
    }

    func beginEditing() {
        guard let payload else { return }
        documentDraft = payload.currentDocument
        mode = .edit
    }

    func cancelEditing() {
        documentDraft = payload?.currentDocument ?? ""
        mode = .view
    }

    func saveCurrentDocument(summary: String? = nil) {
        guard var payload else { return }
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
        }

        mode = .view
        persistIfPossible()
        showToast(didChange ? "已保存为新版本" : "没有内容变更", kind: .saved)
    }

    func saveAsPanel(password: String) async {
        guard let payload else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "privdoc")!]
        panel.nameFieldStringValue = "MySecrets.privdoc"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isSavingVault = true
        defer { isSavingVault = false }

        do {
            let encrypted = try CryptoBox.encrypt(payload: payload, password: password)
            sessionAuth = .password(password)
            try encrypted.write(to: url, options: .atomic)
            fileURL = url
            newVaultPassword = ""
            isSaveSheetPresented = false
            showToast("加密文件已保存", kind: .saved)
        } catch {
            showToast(error.localizedDescription, kind: .error)
        }
    }

    func persistIfPossible() {
        guard let payload, let fileURL else { return }
        guard let sessionAuth else { return }

        do {
            let encrypted: Data
            switch sessionAuth {
            case let .password(password):
                encrypted = try CryptoBox.encrypt(payload: payload, password: password)
            case let .system(keyID, key):
                encrypted = try CryptoBox.encrypt(payload: payload, rawKey: key, keyID: keyID)
            }
            try encrypted.write(to: fileURL, options: .atomic)
        } catch {
            showToast(error.localizedDescription, kind: .error)
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
        persistIfPossible()

        if delay == .manual, previousDelay != .manual {
            showToast("已改为手动清除剪贴板", kind: .locked)
        } else {
            showToast("剪贴板清理时间已更新", kind: .saved)
        }

        if clipboardHasPrivDocContent {
            scheduleClipboardClear()
        }
    }

    func openURLField(_ field: Field) {
        guard let url = URL(string: field.value) else { return }
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

    func removeSecretKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .secret, shouldAdd: false)
    }

    func removePlainTextKeyword(_ keyword: String) {
        updateKeywords(keyword, target: .plainText, shouldAdd: false)
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
    }

    private func updateKeywords(_ keyword: String, target: KeywordTarget, shouldAdd: Bool) {
        let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        switch target {
        case .secret:
            globalParsingRules.customSecretKeywords = updatedKeywords(
                globalParsingRules.customSecretKeywords,
                keyword: normalized,
                shouldAdd: shouldAdd
            )
        case .plainText:
            globalParsingRules.customPlainTextKeywords = updatedKeywords(
                globalParsingRules.customPlainTextKeywords,
                keyword: normalized,
                shouldAdd: shouldAdd
            )
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

    private static func loadGlobalParsingRules() -> ParsingRules {
        guard let data = UserDefaults.standard.data(forKey: "local.privdoc.parsingRules.v1"),
              let rules = try? JSONDecoder().decode(ParsingRules.self, from: data) else {
            return ParsingRules()
        }
        return rules
    }

    private func saveGlobalParsingRules() {
        if let data = try? JSONEncoder().encode(globalParsingRules) {
            UserDefaults.standard.set(data, forKey: rulesDefaultsKey)
        }
    }

    private func unlockSelectedVault(_ url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let info = try CryptoBox.inspect(data: data)
            switch info.mode {
            case .system:
                guard let keyID = info.keyID else { throw CryptoError.invalidFormat }
                let key = try KeychainVaultKeyStore.loadKey(keyID: keyID, reason: "解锁 PrivDoc 密档")
                let payload = try CryptoBox.decrypt(data: data, rawKey: key)
                self.payload = payload
                self.documentDraft = payload.currentDocument
                self.fileURL = url
                self.sessionAuth = .system(keyID: keyID, key: key)
                self.mode = .view
                self.selectedSectionID = nil
                self.pendingOpenURL = nil
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
}
