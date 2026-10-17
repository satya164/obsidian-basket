import AppIntents

struct AddBasketItemsIntent: AppIntent {
    // App Intents metadata extraction requires explicit resource initializers.
    static let title = LocalizedStringResource("addToBasket")
    static var supportedModes: IntentModes { .background }

    @Parameter(
        title: LocalizedStringResource("itemsParameter"),
        requestValueDialog: IntentDialog(LocalizedStringResource("requestBasketItems")))
    var item: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to the basket")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let titles = item.split(separator: /(?i)\s*,\s*(?:and\s+)?|\s+and\s+/)
            .map { MarkdownList.normalizedTitle(String($0)) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else {
            throw $item.needsValueError(IntentDialog(.requestBasketItems))
        }
        let store = ObsidianBasketStore.shared
        guard store.settings.isConfigured else {
            throw ObsidianBasketError.message(
                String(localized: .intentSetupRequired))
        }
        guard store.conflict == nil else {
            throw ObsidianBasketError.message(
                String(localized: .intentConflictResolutionRequired))
        }
        for title in titles {
            guard store.add(title) != nil else {
                throw ObsidianBasketError.message(
                    store.errorMessage ?? String(localized: .intentAddFailed(title)))
            }
        }
        await store.sync()
        if store.conflict != nil {
            return .result(
                dialog:
                    IntentDialog(.intentSavedWithConflict(titles.formatted()))
            )
        }
        if store.note.hasChanges {
            if store.errorMessage != nil {
                return .result(
                    dialog:
                        IntentDialog(.intentSavedWithSyncError(titles.formatted()))
                )
            }
            return .result(
                dialog:
                    IntentDialog(.intentSavedPendingSync(titles.formatted())))
        }
        return .result(dialog: IntentDialog(.intentItemsAdded(titles.formatted())))
    }
}

struct ObsidianBasketShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddBasketItemsIntent(),
            phrases: ["Add to \(.applicationName)"],
            shortTitle: LocalizedStringResource("addToBasket"),
            systemImageName: "cart.badge.plus"
        )
    }
}
