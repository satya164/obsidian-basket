import Foundation
import Observation

struct CachedNote: Codable {
    var text = ""
    var syncedText: String?
    var modifiedAt: Double?
    // Undo can match the old baseline while an upload still has an unknown outcome.
    var hasUnsyncedEdits: Bool?

    var hasChanges: Bool {
        hasUnsyncedEdits == true || text != (syncedText ?? "")
    }
}

struct SyncConflict: Identifiable {
    let id = UUID()
    var remote: RemoteNote?
}

@MainActor @Observable
final class ObsidianBasketStore {
    static let shared = ObsidianBasketStore()

    enum BasketIssue: Equatable {
        case settings(String)
        case open(String)
        case sync(String)
        case save(String)
        case add(String)
        case rename(String)
        case move(String)
        case resolve(String)

        var title: String {
            switch self {
            case .settings: String(localized: .couldNotLoadSettings)
            case .open: String(localized: .couldNotOpenBasket)
            case .sync: String(localized: .couldNotSyncBasket)
            case .save: String(localized: .couldNotSaveBasket)
            case .add: String(localized: .couldNotAddItem)
            case .rename: String(localized: .couldNotRenameItem)
            case .move: String(localized: .couldNotMoveItem)
            case .resolve: String(localized: .couldNotResolveConflict)
            }
        }

        var message: String {
            switch self {
            case .settings(let message), .open(let message), .sync(let message), .save(let message),
                .add(let message), .rename(let message), .move(let message), .resolve(let message):
                message
            }
        }
    }

    enum LoadState {
        case loading
        case failed
        case loaded
    }

    private(set) var settings: ConnectionSettings
    private(set) var connectionID = UUID()
    private(set) var note = CachedNote()
    private(set) var isSyncing = false
    private(set) var issue: BasketIssue?
    private(set) var connectionError: String?
    private(set) var cacheIsReadable = true
    private(set) var hasLoadedBasket = false
    private(set) var items: [ObsidianBasketItem] = []
    private(set) var nameDrafts: [String: String] = [:]
    @ObservationIgnored private var nameEditTask: Task<Void, Never>?
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private let undoManagers = NSHashTable<UndoManager>.weakObjects()
    var conflict: SyncConflict?

    private struct ListSnapshot {
        let text: String
        let items: [ObsidianBasketItem]
    }

    private var hasPendingNameEdits: Bool {
        items.contains { item in
            guard let draft = nameDrafts[item.id] else { return false }
            return draft.trimmingCharacters(in: .whitespacesAndNewlines) != item.title
        }
    }

    var canSync: Bool { canEdit && !isSyncing && !hasPendingNameEdits }
    var canEdit: Bool { settings.isConfigured && cacheIsReadable && conflict == nil }
    var errorMessage: String? { issue?.message }

    var loadState: LoadState {
        if isSyncing && (!hasLoadedBasket || issue != nil) {
            return .loading
        }
        if !cacheIsReadable || issue != nil {
            return .failed
        }
        return hasLoadedBasket ? .loaded : .loading
    }

    init() {
        do {
            if let data = UserDefaults.standard.data(forKey: "connectionSettings") {
                settings = try JSONDecoder().decode(ConnectionSettings.self, from: data)
            } else {
                settings = ConnectionSettings()
            }
        } catch {
            settings = ConnectionSettings()
            issue = .settings(String(localized: .loadSettingsFailed(error.localizedDescription)))
        }
        do {
            note = try loadCache(for: settings)
            hasLoadedBasket = note.syncedText != nil || note.hasChanges
        } catch {
            cacheIsReadable = false
            issue = .open(String(localized: .openSavedBasketFailed(error.localizedDescription)))
        }
        refreshItems()
    }

    enum AdditionResult {
        case added
        case existing(String, wasCompleted: Bool)
    }

    func add(_ title: String) -> AdditionResult? {
        guard canEdit, saveNameEdits() else { return nil }
        let title = MarkdownList.normalizedTitle(title)
        guard !title.isEmpty else { return nil }
        var markdown = MarkdownList(text: note.text)
        if let item = items.first(where: {
            MarkdownList.normalizedTitle($0.title).caseInsensitiveCompare(title) == .orderedSame
        }) {
            if item.isCompleted {
                markdown.toggle(item)
                guard updateText(markdown.text, preservingLinePositions: true) else { return nil }
            }
            return .existing(item.id, wasCompleted: item.isCompleted)
        }
        do {
            try markdown.add(title)
            return updateText(markdown.text) ? .added : nil
        } catch {
            issue = .add(error.localizedDescription)
            return nil
        }
    }

    func toggle(_ id: String) {
        guard canEdit, saveNameEdits(), let item = items.first(where: { $0.id == id }) else { return }
        var markdown = MarkdownList(text: note.text)
        markdown.toggle(item)
        updateText(markdown.text, preservingLinePositions: true)
    }

    func remove(_ ids: [String], undoManager: UndoManager?) {
        guard canEdit, saveNameEdits() else { return }
        let offsets = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard !offsets.isEmpty, offsets.count == ids.count else { return }
        nameDrafts = [:]
        var markdown = MarkdownList(text: note.text)
        markdown.remove(at: offsets)
        let previous = ListSnapshot(text: note.text, items: items)
        let remaining = items.filter { !ids.contains($0.id) }
        if updateText(markdown.text, matching: remaining, preservingUndo: true) {
            for manager in undoManagers.allObjects where manager !== undoManager {
                manager.removeAllActions(withTarget: self)
            }
            if let undoManager {
                registerUndo(
                    restoring: previous, replacing: markdown.text,
                    actionName: String(localized: .deleteItemsUndo(count: offsets.count)),
                    in: undoManager)
            }
        }
    }

    private func registerUndo(
        restoring snapshot: ListSnapshot, replacing expectedText: String, actionName: String,
        in undoManager: UndoManager
    ) {
        undoManagers.add(undoManager)
        undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
            guard let undoManager else { return }
            guard store.canEdit, store.note.text == expectedText else {
                store.clearDeletionUndo()
                return
            }
            let current = ListSnapshot(text: store.note.text, items: store.items)
            if store.updateText(
                snapshot.text, preservingLinePositions: true, matching: snapshot.items, preservingUndo: true
            ) {
                store.registerUndo(
                    restoring: current, replacing: snapshot.text, actionName: actionName, in: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func clearDeletionUndo() {
        for undoManager in undoManagers.allObjects {
            undoManager.removeAllActions(withTarget: self)
        }
    }

    func editName(_ id: String, to title: String) {
        guard canEdit else { return }
        clearDeletionUndo()
        nameDrafts[id] = title.components(separatedBy: .newlines).joined(separator: " ")
        nameEditTask?.cancel()
        nameEditTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            self?.saveNameEdits()
        }
    }

    @discardableResult
    func saveNameEdits() -> Bool {
        nameEditTask?.cancel()
        nameEditTask = nil
        guard canEdit else { return !hasPendingNameEdits }
        var markdown = MarkdownList(text: note.text)
        do {
            for item in items {
                if let draft = nameDrafts[item.id],
                    draft != item.title,
                    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    try markdown.rename(item, to: draft)
                }
            }
            return updateText(markdown.text, preservingLinePositions: true)
        } catch {
            issue = .rename(error.localizedDescription)
            return false
        }
    }

    func finishNameEditing(_ id: String? = nil) {
        guard saveNameEdits() else { return }
        if let id {
            nameDrafts[id] = nil
        } else {
            nameDrafts = [:]
        }
        Task { await sync() }
    }

    func move(_ ids: [String], before destinationID: String?) {
        guard canEdit, saveNameEdits() else { return }
        let offsets = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard offsets.count == ids.count else { return }
        let destination: Int
        if let destinationID {
            guard let index = items.firstIndex(where: { $0.id == destinationID }) else { return }
            destination = index
        } else {
            destination = items.count
        }
        nameDrafts = [:]
        var markdown = MarkdownList(text: note.text)
        do {
            try markdown.move(from: offsets, to: destination)
            updateText(markdown.text)
        } catch {
            issue = .move(error.localizedDescription)
        }
    }

    func saveSettings(_ proposed: ConnectionSettings, password: String) throws {
        guard !isSyncing else { throw ObsidianBasketError.message(String(localized: .waitForSync)) }
        guard saveNameEdits() else {
            throw ObsidianBasketError.message(
                errorMessage ?? String(localized: .resolveBeforeSettingsChange))
        }
        let validated = try proposed.validated()
        let cached = try loadCache(for: validated)
        try CredentialStore.save(password: password, for: validated)
        UserDefaults.standard.set(try JSONEncoder().encode(validated), forKey: "connectionSettings")
        applySettings(validated, note: cached)
    }

    func resetSettings() throws {
        guard !isSyncing else { throw ObsidianBasketError.message(String(localized: .waitForSync)) }
        guard saveNameEdits() else {
            throw ObsidianBasketError.message(
                errorMessage ?? String(localized: .resolveBeforeSettingsReset))
        }
        try CredentialStore.removePassword(for: settings)
        UserDefaults.standard.removeObject(forKey: "connectionSettings")
        applySettings(ConnectionSettings(), note: CachedNote())
    }

    private func applySettings(_ settings: ConnectionSettings, note: CachedNote) {
        self.settings = settings
        connectionID = UUID()
        self.note = note
        hasLoadedBasket = note.syncedText != nil || note.hasChanges
        nameDrafts = [:]
        items = []
        refreshItems()
        cacheIsReadable = true
        conflict = nil
        issue = nil
        connectionError = nil
        clearDeletionUndo()
    }

    func watchRemoteChanges() async {
        guard settings.isConfigured else { return }
        var sequence = "now"
        var needsSync = true
        var retryDelay = 1

        while !Task.isCancelled {
            do {
                let client = try makeClient()
                if sequence == "now" {
                    // Capture the checkpoint first so edits made during the initial sync aren't missed.
                    sequence = try await client.changes(since: sequence, waitForChanges: false).sequence
                }
                if needsSync {
                    await sync()
                    try Task.checkCancellation()
                    switch issue {
                    case .open(let message), .sync(let message):
                        throw ObsidianBasketError.message(message)
                    default:
                        break
                    }
                }
                let changes = try await client.changes(since: sequence)
                try Task.checkCancellation()
                connectionError = nil
                sequence = changes.sequence
                // A local upload can fail while the feed is waiting without producing a remote change.
                needsSync = changes.hasChanges || note.hasChanges || issue != nil
                retryDelay = 1
            } catch {
                guard !Task.isCancelled else { return }
                connectionError = error.localizedDescription
                if !hasLoadedBasket && issue == nil {
                    issue = .open(error.localizedDescription)
                }
                // Retry the sync as well as the feed. A note's chunks can arrive after its change event.
                needsSync = true
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, 30)
            }
        }
    }

    func sync() async {
        if isSyncing {
            // Keep a remote change received during an upload pending for the next sync.
            syncRequested = true
            return
        }
        if !cacheIsReadable {
            guard settings.isConfigured else { return }
            do {
                note = try loadCache(for: settings)
                refreshItems()
                cacheIsReadable = true
                hasLoadedBasket = note.syncedText != nil || note.hasChanges
                issue = nil
            } catch {
                issue = .open(String(localized: .openSavedBasketFailed(error.localizedDescription)))
                return
            }
        }
        guard canSync else { return }
        isSyncing = true
        let isOpeningBasket = !hasLoadedBasket
        var needsSync = false
        defer {
            isSyncing = false
            if needsSync || syncRequested {
                syncRequested = false
                Task { await sync() }
            }
        }
        do {
            let client = try makeClient()
            let remote = try await client.load()
            guard !Task.isCancelled, !hasPendingNameEdits else { return }
            if note.hasChanges {
                if remote?.text == note.text {
                    try acceptSynced(note.text)
                } else if remote?.text == note.syncedText {
                    let uploadedText = note.text
                    try await client.save(text: uploadedText, replacing: remote)
                    try acceptSynced(uploadedText, preservingLocalChanges: true)
                    needsSync = note.hasChanges
                } else {
                    presentConflict(remote)
                }
            } else if let remote {
                if remote.text == note.syncedText {
                    issue = nil
                } else {
                    try acceptSynced(remote.text)
                }
            } else if note.syncedText != nil {
                throw ObsidianBasketError.message(
                    String(localized: .syncedNoteMissing(settings.notePath))
                )
            } else {
                issue = nil
            }
            hasLoadedBasket = true
        } catch is CancellationError {
            return
        } catch ObsidianBasketError.http(409) {
            do {
                let remote = try await makeClient().load()
                guard !Task.isCancelled, !hasPendingNameEdits else { return }
                if remote?.text == note.text {
                    try acceptSynced(note.text)
                } else if remote?.text == note.syncedText {
                    issue = nil
                    needsSync = true
                } else {
                    presentConflict(remote)
                }
            } catch {
                guard !Task.isCancelled else { return }
                issue =
                    isOpeningBasket ? .open(error.localizedDescription) : .sync(error.localizedDescription)
            }
        } catch {
            guard !Task.isCancelled else { return }
            issue =
                isOpeningBasket ? .open(error.localizedDescription) : .sync(error.localizedDescription)
        }
    }

    enum ConflictResolution {
        case keepLocal
        case merge
    }

    func resolveConflict(_ resolution: ConflictResolution) async {
        guard let conflict, !isSyncing else { return }
        issue = nil
        isSyncing = true
        defer {
            isSyncing = false
            if syncRequested {
                syncRequested = false
                Task { await sync() }
            }
        }
        do {
            let client = try makeClient()
            let remote = try await client.load()
            guard remote?.document._rev == conflict.remote?.document._rev else {
                presentConflict(remote)
                throw ObsidianBasketError.message(
                    String(localized: .serverCopyChanged))
            }
            let text: String
            switch resolution {
            case .keepLocal:
                text = note.text
            case .merge:
                text = try MarkdownList.merged(
                    base: note.syncedText ?? "", local: note.text, remote: remote?.text ?? "",
                    localIsNewer: (note.modifiedAt ?? 0) >= (remote?.document.mtime ?? 0))
            }
            try await client.save(text: text, replacing: remote)
            try acceptSynced(text)
            self.conflict = nil
        } catch ObsidianBasketError.http(409) {
            do {
                presentConflict(try await makeClient().load())
                issue = .resolve(String(localized: .serverCopyChanged))
            } catch {
                issue = .resolve(error.localizedDescription)
            }
        } catch {
            issue = .resolve(error.localizedDescription)
        }
    }

    private func presentConflict(_ remote: RemoteNote?) {
        clearDeletionUndo()
        issue = nil
        conflict = SyncConflict(remote: remote)
    }

    func useRemoteVersion() {
        guard let conflict, !isSyncing else { return }
        do {
            if let remote = conflict.remote {
                try acceptSynced(remote.text)
            } else {
                let empty = CachedNote()
                try persist(empty)
                note = empty
                hasLoadedBasket = true
                refreshItems()
                issue = nil
            }
            self.conflict = nil
            clearDeletionUndo()
            nameDrafts = [:]
            nameEditTask?.cancel()
            nameEditTask = nil
            Task { await sync() }
        } catch {
            issue = .resolve(error.localizedDescription)
        }
    }

    private func makeClient() throws -> CouchDBClient {
        let settings = try settings.validated()
        return CouchDBClient(settings: settings, password: try CredentialStore.password(for: settings))
    }

    @discardableResult
    private func updateText(
        _ text: String, preservingLinePositions: Bool = false,
        matching previousItems: [ObsidianBasketItem]? = nil,
        preservingUndo: Bool = false
    ) -> Bool {
        guard text != note.text else { return true }
        var updated = note
        updated.text = text
        updated.modifiedAt = Date().timeIntervalSince1970 * 1000
        updated.hasUnsyncedEdits = true
        do {
            try persist(updated)
            note = updated
            hasLoadedBasket = true
            refreshItems(matching: previousItems, preservingLinePositions: preservingLinePositions)
            if !preservingUndo {
                clearDeletionUndo()
            }
            issue = nil
            Task { await sync() }
            return true
        } catch {
            issue = .save(String(localized: .saveLocalBasketFailed(error.localizedDescription)))
            return false
        }
    }

    private func acceptSynced(_ text: String, preservingLocalChanges: Bool = false) throws {
        let updated = CachedNote(
            text: preservingLocalChanges ? note.text : text, syncedText: text,
            modifiedAt: preservingLocalChanges && note.text != text ? note.modifiedAt : nil,
            hasUnsyncedEdits: preservingLocalChanges && note.text != text)
        try persist(updated)
        let changed = updated.text != note.text
        note = updated
        hasLoadedBasket = true
        if changed {
            refreshItems()
            clearDeletionUndo()
            nameDrafts = nameDrafts.filter { id, _ in items.contains { $0.id == id } }
        }
        issue = nil
    }

    private func refreshItems(
        matching previousItems: [ObsidianBasketItem]? = nil, preservingLinePositions: Bool = false
    ) {
        var remaining = previousItems ?? items
        items = MarkdownList(text: note.text).items.map { parsed in
            var item = parsed
            let match: Int?
            if preservingLinePositions {
                match = remaining.firstIndex { $0.lineIndex == item.lineIndex }
            } else {
                match =
                    remaining.firstIndex { $0.title == item.title && $0.isCompleted == item.isCompleted }
                    ?? remaining.firstIndex { $0.title == item.title }
            }
            // Autosaving a name must keep the focused text field's identity.
            if let match {
                item.id = remaining.remove(at: match).id
            }
            return item
        }
    }

    private func cacheURL(for settings: ConnectionSettings) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("ObsidianBasket", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(settings.cacheKey + ".json")
    }

    private func loadCache(for settings: ConnectionSettings) throws -> CachedNote {
        let url = try cacheURL(for: settings)
        guard FileManager.default.fileExists(atPath: url.path) else { return CachedNote() }
        var cached = try JSONDecoder().decode(CachedNote.self, from: Data(contentsOf: url))
        if cached.hasChanges && cached.modifiedAt == nil {
            cached.modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate.map { $0.timeIntervalSince1970 * 1000 }
        }
        return cached
    }

    private func persist(_ note: CachedNote) throws {
        try JSONEncoder().encode(note).write(to: cacheURL(for: settings), options: .atomic)
    }
}
