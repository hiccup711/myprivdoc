import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if store.isUnlocked {
                unlockedView
            } else {
                LockedView()
            }

            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.background)
        .animation(.easeOut(duration: 0.18), value: store.toast?.id)
        .sheet(isPresented: $store.isUnlockSheetPresented) {
            UnlockSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isSaveSheetPresented) {
            SaveVaultSheet()
                .environmentObject(store)
        }
    }

    private var unlockedView: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.line)

            switch store.mode {
            case .view:
                ViewMode()
            case .edit:
                EditMode()
            case .history:
                HistoryMode()
            case .rules:
                RulesMode()
            case .settings:
                SettingsMode()
            }
        }
    }
}

struct LockedView: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text("PrivDoc")
                    .font(.system(size: 46, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.text)
                Text("本地加密的可操作隐私文档。")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 12) {
                Button {
                    store.newVault()
                } label: {
                    Label("新建密档", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    store.openVaultPanel()
                } label: {
                    Label("打开 .privdoc", systemImage: "lock.open")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 12) {
                CapabilityRow(icon: "eye.slash", title: "密钥默认不可见", text: "双击复制，不在查看态摊开明文。")
                CapabilityRow(icon: "doc.text.magnifyingglass", title: "文档自动拆字段", text: "字段名和值分离，长字符串不用手动选。")
                CapabilityRow(icon: "clock.arrow.circlepath", title: "每次保存都有版本", text: "修改不会覆盖过去，可以回滚。")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapabilityRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        HStack(spacing: 16) {
            Picker("", selection: $store.mode) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .onChange(of: store.mode) { _, mode in
                if mode == .edit {
                    store.beginEditing()
                }
            }

            if store.mode == .view {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.faint)
                    TextField("搜索标题、字段名、非密钥值", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: 420)
                .frame(height: 34)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }

            Spacer()

            if store.clipboardHasPrivDocContent {
                Button {
                    store.clearClipboardIfOwned()
                } label: {
                    Label("清除剪贴板", systemImage: "clipboard.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if store.fileURL == nil {
                Button {
                    store.isSaveSheetPresented = true
                } label: {
                    Label("保存加密文件", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button {
                store.lock()
            } label: {
                Label("锁定", systemImage: "lock")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.topbar)
    }
}

struct ViewMode: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Divider().overlay(Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.selectedSectionID == nil {
                        Text(store.documentTitle)
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.text)
                            .padding(.bottom, 4)
                    }

                    let sectionsToShow = store.selectedSectionID == nil ? store.filteredSections : store.selectedSection.map { [$0] } ?? []
                    if sectionsToShow.isEmpty {
                        ContentUnavailableView("没有可显示的内容", systemImage: "doc.text", description: Text("编辑文档后会在这里看到内容。"))
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ForEach(sectionsToShow) { section in
                            SectionView(section: section, showTitle: section.title != DocumentParser.implicitSectionTitle || store.selectedSectionID != nil)
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("目录")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        store.selectedSectionID = nil
                    } label: {
                        SidebarItem(title: "全文", isSelected: store.selectedSectionID == nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(store.filteredSections) { section in
                        Button {
                            store.selectedSectionID = section.id
                        } label: {
                            SidebarItem(title: section.title, isSelected: store.selectedSectionID == section.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 230)
        .background(Theme.sidebar)
    }
}

struct SidebarItem: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Theme.text : Theme.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionView: View {
    let section: DocumentSection
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showTitle {
                Text(section.title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.text)
            }

            VStack(spacing: 2) {
                ForEach(section.lines) { line in
                    ParsedLineView(line: line)
                }
            }
        }
    }
}

struct ParsedLineView: View {
    let line: ParsedLine

    var body: some View {
        switch line.kind {
        case let .heading(title, level):
            if level > 2 {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 16)
            }
        case let .field(field):
            FieldRow(field: field)
        case let .secret(value):
            SecretBlock(value: value)
        case let .richParagraph(segments):
            RichParagraphView(segments: segments)
        case let .paragraph(text):
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .padding(.vertical, 4)
        case .empty:
            Spacer().frame(height: 8)
        }
    }
}

struct RichParagraphView: View {
    let segments: [TextSegment]

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 5) {
            ForEach(segments) { segment in
                if segment.isSecret {
                    InlineSecretChip(value: segment.text)
                } else if !segment.text.isEmpty {
                    Text(segment.text)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct InlineSecretChip: View {
    @EnvironmentObject private var store: VaultStore
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .semibold))
            Text("已隐藏")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.secret)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Theme.secretBackground)
        .clipShape(Capsule())
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.copySecretValue(value)
        }
        .contextMenu {
            Button("复制隐藏内容") { store.copySecretValue(value) }
        }
    }
}

struct SecretBlock: View {
    @EnvironmentObject private var store: VaultStore
    let value: String
    @State private var revealSecret = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: revealSecret ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                Text(revealSecret ? value : "已隐藏，双击复制")
                    .font(.system(size: 13, weight: .medium, design: revealSecret ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.secret)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.secretBackground)
            .clipShape(Capsule())

            Spacer()

            FieldBadge(type: .secret)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Theme.row)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.copySecretValue(value)
        }
        .contextMenu {
            Button("复制密钥") { store.copySecretValue(value) }
            Button("临时显示 10 秒") {
                revealSecret = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    revealSecret = false
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }

            measuredWidth = max(measuredWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? measuredWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        var row: [(LayoutSubviews.Element, CGSize)] = []

        func placeRow() {
            for (subview, size) in row {
                subview.place(
                    at: CGPoint(x: x, y: y + max(0, rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            row.removeAll()
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                placeRow()
                y += rowHeight + lineSpacing
                rowHeight = 0
            }

            row.append((subview, size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        x = bounds.minX
        placeRow()
    }
}

struct FieldRow: View {
    @EnvironmentObject private var store: VaultStore
    let field: Field
    @State private var revealSecret = false

    var body: some View {
        HStack(spacing: 14) {
            Text(field.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 170, alignment: .leading)
                .lineLimit(1)

            valueView

            Spacer(minLength: 16)

            FieldBadge(type: field.type)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Theme.row)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if field.type == .url {
                store.copyFieldValue(field)
            } else {
                store.copyFieldValue(field)
            }
        }
        .contextMenu {
            Button("复制值") { store.copyFieldValue(field) }
            Button("复制脱敏整行") { store.copyLine(field, revealSecret: false) }
            Button("把“\(field.name)”识别为密钥") { store.addSecretKeyword(field.name) }
            Button("把“\(field.name)”识别为普通字段") { store.addPlainTextKeyword(field.name) }
            if field.type == .secret {
                Button("临时显示 10 秒") {
                    revealSecret = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        revealSecret = false
                    }
                }
                Button("复制完整整行") { store.copyLine(field, revealSecret: true) }
            }
            if field.type == .url {
                Button("打开链接") { store.openURLField(field) }
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if field.type == .secret && !revealSecret {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                Text("已隐藏，双击复制")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Theme.secret)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.secretBackground)
            .clipShape(Capsule())
        } else {
            Text(field.value)
                .font(.system(size: 13, design: field.type == .text ? .default : .monospaced))
                .foregroundStyle(field.type == .url ? Theme.link : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct FieldBadge: View {
    let type: FieldType

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
        switch type {
        case .secret: return "SECRET"
        case .url: return "URL"
        case .ip: return "IP"
        case .port: return "PORT"
        case .email: return "EMAIL"
        case .text: return "TEXT"
        }
    }

    private var color: Color {
        switch type {
        case .secret: return Theme.secret
        case .url: return Theme.link
        case .ip, .port: return Theme.accent
        case .email: return .teal
        case .text: return Theme.faint
        }
    }
}

struct EditMode: View {
    @EnvironmentObject private var store: VaultStore
    @State private var summary = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("版本备注，例如：修改 prod-01 登录密码", text: $summary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))

                Button("取消") {
                    store.cancelEditing()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("保存为新版本") {
                    store.saveCurrentDocument(summary: summary)
                    summary = ""
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)

            Divider().overlay(Theme.line)

            HStack(spacing: 0) {
                TextEditor(text: $store.documentDraft)
                    .font(.system(size: 14, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Theme.editor)
                    .foregroundStyle(Theme.text)
                    .padding(16)

                Divider().overlay(Theme.line)

                ParsePreview(document: store.documentDraft)
                    .frame(width: 300)
            }
        }
    }
}

struct ParsePreview: View {
    @EnvironmentObject private var store: VaultStore
    let document: String

    var body: some View {
        let sections = DocumentParser.parse(document, rules: store.globalParsingRules)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("解析预览")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .textCase(.uppercase)

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        ForEach(section.lines) { line in
                            if case let .field(field) = line.kind {
                                HStack {
                                    Text(field.name)
                                        .lineLimit(1)
                                    Spacer()
                                    FieldBadge(type: field.type)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                            } else if case .secret = line.kind {
                                HStack {
                                    Text("显式密钥段落")
                                        .lineLimit(1)
                                    Spacer()
                                    FieldBadge(type: .secret)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                            } else if case .richParagraph = line.kind {
                                HStack {
                                    Text("包含隐藏片段")
                                        .lineLimit(1)
                                    Spacer()
                                    FieldBadge(type: .secret)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.sidebar)
    }
}

struct HistoryMode: View {
    @EnvironmentObject private var store: VaultStore
    @State private var selectedVersionID: UUID?

    var selectedVersion: DocumentVersion? {
        guard let selectedVersionID else {
            return store.payload?.versions.first
        }
        return store.payload?.versions.first(where: { $0.id == selectedVersionID }) ?? store.payload?.versions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.payload?.versions ?? []) { version in
                        Button {
                            selectedVersionID = version.id
                        } label: {
                            VersionRow(version: version, isSelected: selectedVersion?.id == version.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .frame(width: 300)
            .background(Theme.sidebar)

            Divider().overlay(Theme.line)

            if let version = selectedVersion {
                VersionDetail(version: version)
            } else {
                ContentUnavailableView("没有历史版本", systemImage: "clock.arrow.circlepath", description: Text("保存文档后会在这里看到版本记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct RulesMode: View {
    @EnvironmentObject private var store: VaultStore
    @State private var newSecretKeyword = ""
    @State private var newPlainTextKeyword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("识别规则")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text)
                    Text("规则是全局配置。你教过一次，之后所有密档都会按这个习惯识别。")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }

                ExplicitSyntaxPanel()

                HStack(alignment: .top, spacing: 18) {
                    RulePanel(
                        title: "自定义密钥词",
                        subtitle: "字段名包含这些词时，值会默认隐藏。",
                        placeholder: "例如：授权码、私钥、云厂商 AK",
                        text: $newSecretKeyword,
                        keywords: store.globalParsingRules.customSecretKeywords,
                        builtInKeywords: DocumentParser.builtInSecretKeywords,
                        addAction: {
                            store.addSecretKeyword(newSecretKeyword)
                            newSecretKeyword = ""
                        },
                        removeAction: store.removeSecretKeyword
                    )

                    RulePanel(
                        title: "强制普通字段",
                        subtitle: "字段名包含这些词时，不会被识别为密钥。",
                        placeholder: "例如：备注、说明、公开 Key 名称",
                        text: $newPlainTextKeyword,
                        keywords: store.globalParsingRules.customPlainTextKeywords,
                        builtInKeywords: DocumentParser.builtInPlainTextKeywords,
                        addAction: {
                            store.addPlainTextKeyword(newPlainTextKeyword)
                            newPlainTextKeyword = ""
                        },
                        removeAction: store.removePlainTextKeyword
                    )
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}

struct ExplicitSyntaxPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("显式标记")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("用双大括号包起来的内容会在查看态隐藏；不需要解释它为什么私密。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 8) {
                SyntaxExample(title: "字段内隐藏", code: "服务器密码：{{abc123}}")
                SyntaxExample(title: "整行隐藏", code: "{{一整段不想展示的内容}}")
                SyntaxExample(title: "正文中隐藏", code: "备注：公开部分 {{私密部分}} 公开部分")
                SyntaxExample(title: "快速：行尾标记", code: "临时 Token：xxxx @secret")
                SyntaxExample(title: "反向：强制普通字段", code: "Public Key：ssh-rsa AAAA... @text")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct SyntaxExample: View {
    let title: String
    let code: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.faint)
                .frame(width: 120, alignment: .leading)
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Theme.row)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsMode: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text)
                    Text("这些设置跟随当前密档保存。默认保护更强，但你可以按自己的工作流调整。")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }

                ClipboardSettingsPanel()
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}

struct ClipboardSettingsPanel: View {
    @EnvironmentObject private var store: VaultStore

    private var selectedDelay: ClipboardClearDelay {
        store.payload?.settings.clipboardClearDelay ?? .seconds15
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("剪贴板清理")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("复制字段后，PrivDoc 只会清除自己写入的那次剪贴板，不会误删你之后复制的新内容。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(ClipboardClearDelay.allCases) { delay in
                    Button {
                        store.updateClipboardClearDelay(delay)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedDelay == delay ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedDelay == delay ? Theme.accent : Theme.faint)
                            Text(delay.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                        .background(selectedDelay == delay ? Theme.selection : Theme.row)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedDelay == delay ? Theme.accent.opacity(0.24) : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedDelay == .manual {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.secret)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("手动清除意味着密钥会一直留在剪贴板，直到你点击清除或复制其他内容。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                        if store.clipboardHasPrivDocContent {
                            Button("立即清除剪贴板") {
                                store.clearClipboardIfOwned()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.secretBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.secret.opacity(0.18)))
            }
        }
        .padding(18)
        .frame(maxWidth: 720, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct RulePanel: View {
    let title: String
    let subtitle: String
    let placeholder: String
    @Binding var text: String
    let keywords: [String]
    let builtInKeywords: [String]
    let addAction: () -> Void
    let removeAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    .onSubmit(addAction)

                Button("添加") {
                    addAction()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("你的规则")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .textCase(.uppercase)

                if keywords.isEmpty {
                    Text("还没有自定义规则。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                } else {
                    KeywordCloud(keywords: keywords, removable: true, removeAction: removeAction)
                }
            }

            Divider().overlay(Theme.line)

            VStack(alignment: .leading, spacing: 10) {
                Text("内置规则")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.faint)
                    .textCase(.uppercase)
                KeywordCloud(keywords: builtInKeywords, removable: false, removeAction: { _ in })
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

struct KeywordCloud: View {
    let keywords: [String]
    let removable: Bool
    let removeAction: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(keywords, id: \.self) { keyword in
                HStack(spacing: 6) {
                    Text(keyword)
                        .lineLimit(1)
                    if removable {
                        Button {
                            removeAction(keyword)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Theme.row)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
        }
    }
}

struct VersionRow: View {
    let version: DocumentVersion
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(version.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct VersionDetail: View {
    @EnvironmentObject private var store: VaultStore
    let version: DocumentVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(version.summary)
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(version.createdAt.formatted(date: .complete, time: .shortened))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("恢复这个版本") {
                    store.restore(version: version)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(Theme.background)

            Divider().overlay(Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let diff = store.diffFromPrevious(version: version)
                    if diff.isEmpty {
                        Text("这是第一个版本，或者没有可显示的字段变化。")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(diff) { line in
                                DiffRow(line: line)
                            }
                        }
                    }

                    Divider().overlay(Theme.line)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("版本原文预览")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.faint)
                            .textCase(.uppercase)
                        Text(DocumentParser.redactedDocument(version.document, rules: store.globalParsingRules))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(26)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 10) {
            Text(line.change.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 66, alignment: .leading)
            Text(line.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            Text(valueText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(line.isSecret ? Theme.secret : Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .background(Theme.row)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch line.change {
        case .added: return .green
        case .removed: return .red
        case .changed: return Theme.accent
        }
    }

    private var valueText: String {
        if line.isSecret { return "已隐藏" }
        switch line.change {
        case .added:
            return line.after ?? ""
        case .removed:
            return line.before ?? ""
        case .changed:
            return "\(line.before ?? "") -> \(line.after ?? "")"
        }
    }
}

struct UnlockSheet: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("解锁密档")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            SecureField("主密码", text: $store.unlockPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    store.unlockPendingVault()
                }
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") {
                    store.isUnlockSheetPresented = false
                }
                Button("解锁") {
                    store.unlockPendingVault()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

struct SaveVaultSheet: View {
    @EnvironmentObject private var store: VaultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存加密密档")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text("默认使用 macOS 系统授权保存；需要跨设备迁移时可改用文档密码。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)

            Picker("", selection: $store.saveMode) {
                ForEach(VaultSaveMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if store.saveMode == .system {
                Label("使用 Touch ID 或 Mac 登录密码授权。文件绑定当前 Mac 的钥匙串。", systemImage: "touchid")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("这个密码只用于当前 .privdoc 文件。之后打开它时需要输入同一个密码。", systemImage: "key")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    SecureField("文档密码", text: $store.newVaultPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("取消") {
                    store.isSaveSheetPresented = false
                }
                .disabled(store.isSavingVault)
                Spacer()
                Button(store.isSavingVault ? "保存中..." : "保存") {
                    Task {
                        await store.saveAsPanel(mode: store.saveMode, password: store.newVaultPassword)
                    }
                }
                .disabled(store.isSavingVault || (store.saveMode == .password && store.newVaultPassword.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
            Text(toast.text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    private var icon: String {
        switch toast.kind {
        case .copied: return "doc.on.clipboard"
        case .saved: return "checkmark.circle"
        case .locked: return "lock"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var foreground: Color {
        switch toast.kind {
        case .error: return Theme.error
        case .locked: return Theme.text
        case .copied, .saved: return Theme.accent
        }
    }

    private var background: Color {
        switch toast.kind {
        case .error: return Theme.errorBackground
        case .locked: return Theme.panel
        case .copied, .saved: return Theme.toastBackground
        }
    }

    private var border: Color {
        switch toast.kind {
        case .error: return Theme.error.opacity(0.24)
        case .locked: return Theme.line
        case .copied, .saved: return Theme.accent.opacity(0.20)
        }
    }
}

enum Theme {
    static let background = Color(red: 0.965, green: 0.958, blue: 0.94)
    static let topbar = Color(red: 0.94, green: 0.93, blue: 0.905)
    static let sidebar = Color(red: 0.925, green: 0.915, blue: 0.885)
    static let panel = Color(red: 0.985, green: 0.98, blue: 0.965)
    static let editor = Color(red: 0.985, green: 0.98, blue: 0.965)
    static let row = Color(red: 0.99, green: 0.985, blue: 0.97)
    static let selection = Color(red: 0.80, green: 0.84, blue: 0.77)
    static let toastBackground = Color(red: 0.91, green: 0.95, blue: 0.90)
    static let text = Color(red: 0.12, green: 0.13, blue: 0.115)
    static let muted = Color(red: 0.38, green: 0.39, blue: 0.35)
    static let faint = Color(red: 0.58, green: 0.58, blue: 0.52)
    static let accent = Color(red: 0.24, green: 0.43, blue: 0.35)
    static let secret = Color(red: 0.62, green: 0.20, blue: 0.16)
    static let secretBackground = Color(red: 0.96, green: 0.88, blue: 0.84)
    static let link = Color(red: 0.14, green: 0.30, blue: 0.58)
    static let error = Color(red: 0.72, green: 0.12, blue: 0.10)
    static let errorBackground = Color(red: 0.98, green: 0.90, blue: 0.88)
    static let line = Color.black.opacity(0.09)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.accent.opacity(0.82) : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(configuration.isPressed ? Theme.line : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}
