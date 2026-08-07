import SwiftUI

@MainActor
final class PrivDocApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: VaultStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.consumeTerminationApproval() {
            return .terminateNow
        }
        guard store.requiresSaveBeforeLeaving else { return .terminateNow }

        store.requestApplicationTermination()
        return .terminateCancel
    }
}

@main
struct PrivDocApp: App {
    @StateObject private var store = VaultStore()
    @NSApplicationDelegateAdaptor(PrivDocApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear {
                    appDelegate.store = store
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建密档") {
                    store.requestNewVault()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("打开密档...") {
                    store.requestOpenVaultPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("保存密档") {
                    store.saveCurrentDocument()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!store.isUnlocked)
            }

            CommandGroup(replacing: .appTermination) {
                Button("退出 PrivDoc") {
                    store.requestApplicationTermination()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }
}
