import SwiftUI

@main
struct ObsidianBasketApp: App {
    @State private var store = ObsidianBasketStore.shared

    var body: some Scene {
        WindowGroup {
            ObsidianBasketView(store: store)
                #if os(macOS)
                    .frame(minWidth: 340, minHeight: 420)
                #endif
        }
        #if os(macOS)
            .defaultSize(width: 440, height: 620)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button(.refresh) { Task { await store.sync() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!store.canSync)
                }
            }
        #endif

        #if os(macOS)
            Settings {
                SettingsView(store: store)
            }
        #endif
    }
}
