import SwiftUI

@main
struct PrivDocApp: App {
    @StateObject private var store = VaultStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建密档") {
                    store.newVault()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("打开密档...") {
                    store.openVaultPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("保存密档") {
                    store.saveCurrentDocument()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!store.isUnlocked)
            }
        }
    }
}
