import SwiftUI

struct ObsidianBasketView: View {
    let store: ObsidianBasketStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newItem = ""
    @State private var showingSettings = false
    @State private var showingConflict = false
    @State private var showingConnectionError = false
    @State private var itemHighlight: ItemHighlight?
    @State private var dismissedIssue: ObsidianBasketStore.BasketIssue?
    #if os(iOS)
        @State private var scrollPhase = ScrollPhase.idle
        @State private var refreshCompletion: CheckedContinuation<Void, Never>?
        // Keep deletion undo available when the iOS environment has no text-field undo manager.
        @State private var fallbackUndoManager = UndoManager()
        @State private var undoFocusRequest = UUID()
        @State private var keyboardIsVisible = false
    #endif
    @FocusState private var inputIsFocused: Bool
    @FocusState private var focusedItemID: String?
    #if os(macOS)
        @FocusState private var listIsFocused: Bool
    #endif

    private struct ItemHighlight: Identifiable {
        let id = UUID()
        let itemID: String
    }

    var body: some View {
        let items = store.items
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    // Reordering hides row IDs from ScrollViewReader. Expose those IDs on the
                    // resulting rows so duplicate items can be revealed when they are offscreen.
                    Group(
                        subviews: ForEach(items) { item in
                            ObsidianBasketRow(
                                store: store, item: item, focusedItem: $focusedItemID,
                                remove: { removeItems([item.id]) }
                            )
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        Color.accentColor.opacity(itemHighlight?.itemID == item.id ? 0.2 : 0)
                                    )
                                    #if os(macOS)
                                        // Extend the flash into the gutter without moving the row's controls.
                                        .padding(.trailing, -8)
                                    #endif
                            }
                            .disabled(!store.canEdit)
                            .deleteDisabled(!store.canEdit)
                            .contextMenu {
                                Button(.moveUp, systemImage: "arrow.up") {
                                    if let destination = item.moveUpDestination {
                                        store.move([item.id], before: items[destination].id)
                                    }
                                }
                                .disabled(!store.canEdit || item.moveUpDestination == nil)
                                Button(.moveDown, systemImage: "arrow.down") {
                                    if let destination = item.moveDownDestination {
                                        store.move(
                                            [item.id],
                                            before: destination < items.count
                                                ? items[destination].id : nil)
                                    }
                                }
                                .disabled(!store.canEdit || item.moveDownDestination == nil)
                                Divider()
                                Button(.delete, systemImage: "xmark", role: .destructive) {
                                    removeItems([item.id])
                                }
                                .disabled(!store.canEdit)
                            }
                        }.reorderable()
                    ) { rows in
                        ForEach(items.enumerated(), id: \.element.id) { index, item in
                            rows[index].id(item.id)
                        }
                        .onDelete { offsets in
                            removeItems(offsets.map { items[$0].id })
                        }
                        .selectionDisabled()
                        #if os(iOS)
                            // The controls already have 44-point targets. Avoid adding row height around them.
                            .listRowInsets(.vertical, 0)
                            .listRowInsets(.leading, 8)
                        #else
                            .listRowInsets(.leading, 0)
                            .listRowInsets(.trailing, 8)
                            // Start separators at the name column, beyond the checkbox's wider hit area.
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 32 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        #endif
                    }
                }
                .reorderContainer(for: ObsidianBasketItem.self, isEnabled: store.canEdit) {
                    difference in
                    let destinationID: String?
                    switch difference.destination.position {
                    case .before(let id):
                        destinationID = id
                    case .end:
                        destinationID = nil
                    }
                    store.move(difference.sources, before: destinationID)
                }
                // Full-width cells include the checkbox's left padding in hit testing.
                .listStyle(.plain)
                #if os(macOS)
                    // Match the inset list's control positions and row spacing.
                    .safeAreaPadding(.top, 10)
                    .environment(\.defaultMinListRowHeight, 40)
                    .focused($listIsFocused)
                #else
                    .scrollDismissesKeyboard(.interactively)
                    .gesture(DismissKeyboardGesture())
                    .onScrollPhaseChange { _, phase in
                        scrollPhase = phase
                        if phase == .idle {
                            refreshCompletion?.resume()
                            refreshCompletion = nil
                        }
                    }
                    .onDisappear {
                        scrollPhase = .idle
                        refreshCompletion?.resume()
                        refreshCompletion = nil
                    }
                #endif
                .refreshable { await refresh() }
                .onChange(of: itemHighlight?.id) {
                    if let itemHighlight {
                        proxy.scrollTo(itemHighlight.itemID, anchor: .center)
                    }
                }
                .task(id: itemHighlight?.id) {
                    guard itemHighlight != nil else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(reduceMotion ? 750 : 150))
                    } catch {
                        return
                    }
                    withAnimation(reduceMotion ? nil : .default) {
                        itemHighlight = nil
                    }
                }
                .overlay {
                    if !store.settings.isConfigured {
                        ContentUnavailableView {
                            Label(.connectVault, systemImage: "basket")
                        } actions: {
                            #if os(macOS)
                                SettingsLink { Text(.openSettings) }
                            #else
                                Button(.openSettings) { showingSettings = true }
                            #endif
                        }
                    } else if items.isEmpty {
                        switch store.loadState {
                        case .loading:
                            ProgressView(.loadingBasket)
                                .allowsHitTesting(false)
                        case .failed:
                            ContentUnavailableView {
                                Label(
                                    store.issue?.title ?? String(localized: .couldNotOpenBasket),
                                    systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(
                                    store.errorMessage ?? String(localized: .savedBasketOpenFailed))
                            } actions: {
                                Button(.tryAgain) { Task { await store.sync() } }
                                    .disabled(store.isSyncing)
                            }
                        case .loaded:
                            ContentUnavailableView(
                                .emptyBasket, systemImage: "basket",
                                description: Text(.addItemBelow)
                            )
                            .allowsHitTesting(false)
                        }
                    }
                }
                .navigationTitle(.basketTitle)
                .toolbar {
                    if let error = store.connectionError, store.conflict == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button(.liveUpdatesUnavailable, systemImage: "icloud.slash") {
                                showingConnectionError = true
                            }
                            .help(error)
                            .popover(isPresented: $showingConnectionError) {
                                Text(error)
                                    .textSelection(.enabled)
                                    .padding()
                                    .frame(idealWidth: 280, maxWidth: 320, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                    if store.conflict != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button(.resolveConflict, systemImage: "exclamationmark.icloud") {
                                showingConflict = true
                            }
                        }
                    }
                    #if os(iOS)
                        ToolbarItem(placement: .primaryAction) {
                            Button(.settingsTitle, systemImage: "gearshape") {
                                showingSettings = true
                            }
                        }
                    #endif
                }
                #if os(iOS)
                    .modifier(
                        InteractiveKeyboardDismissal(
                            scrollPhase: scrollPhase,
                            showsComposer: store.settings.isConfigured,
                            composer: composer))
                #else
                    .safeAreaBar(edge: .bottom) {
                        if store.settings.isConfigured {
                            composer
                        }
                    }
                #endif
                #if os(iOS)
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIResponder.keyboardWillShowNotification)
                    ) { _ in
                        keyboardIsVisible = true
                    }
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIResponder.keyboardWillHideNotification)
                    ) { _ in
                        keyboardIsVisible = false
                    }
                    .background {
                        UndoResponder(
                            undoManager: undoManager ?? fallbackUndoManager,
                            focusRequest: undoFocusRequest,
                            isActive: !showingSettings && store.conflict == nil
                                && !inputIsFocused && focusedItemID == nil)
                    }
                    .sheet(
                        isPresented: $showingSettings,
                        onDismiss: { showingConflict = store.conflict != nil }
                    ) {
                        SettingsView(store: store)
                    }
                #endif
                .sheet(
                    item: Binding(
                        get: { showingConflict ? store.conflict : nil },
                        set: { showingConflict = $0 != nil }
                    )
                ) { conflict in
                    ConflictView(store: store, conflict: conflict)
                }
                .task(id: scenePhase == .active ? store.connectionID : nil) {
                    guard scenePhase == .active else {
                        store.finishNameEditing()
                        return
                    }
                    await store.watchRemoteChanges()
                }
            }
        }
        .alert(
            store.issue?.title ?? "",
            isPresented: Binding(
                get: {
                    store.issue != nil && store.issue != dismissedIssue && store.conflict == nil
                },
                set: { if !$0 { dismissedIssue = store.issue } }
            )
        ) {
            Button(.ok, role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: store.isSyncing) {
            if !store.isSyncing && store.issue == nil { dismissedIssue = nil }
        }
        .onChange(of: store.settings) { dismissedIssue = nil }
        .onChange(of: store.connectionError) {
            if store.connectionError == nil { showingConnectionError = false }
        }
        .onChange(of: store.conflict?.id, initial: true) {
            if store.conflict == nil || !showingSettings {
                showingConflict = store.conflict != nil
            }
        }
    }

    private func refresh() async {
        await store.sync()
        #if os(iOS)
            guard !Task.isCancelled, scrollPhase != .idle else { return }
            // Ending a fast refresh during the pull's bounce resets the content inset abruptly.
            await withCheckedContinuation { refreshCompletion = $0 }
        #endif
    }

    private var composer: some View {
        HStack {
            TextField(.addItemPlaceholder, text: $newItem)
                .textFieldStyle(.plain)
                .focused($inputIsFocused)
                .onSubmit(addItem)
                .submitLabel(.done)
                .accessibilityLabel(.newBasketItem)
                .disabled(!store.canEdit)
            ZStack {
                // Reserve the button's space while it's hidden so typing doesn't move the text.
                if canAddItem {
                    Button(.addItem, systemImage: "arrow.up", action: addItem)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        #if os(iOS)
                            .controlSize(.mini)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        #endif
                        .transition(reduceMotion ? .identity : .scale)
                }
            }
            #if os(iOS)
                .frame(width: 44, height: 44)
            #else
                .frame(width: 28, height: 28)
            #endif
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: canAddItem)
        }
        #if os(iOS)
            .padding(.leading, 12)
            .frame(minHeight: 44)
        #else
            .padding(.leading)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
        #endif
        .glassEffect(.regular, in: Capsule())
        .contentShape(Capsule())
        // Include the capsule's blank area in the focus target, beyond the text field itself.
        .simultaneousGesture(
            TapGesture().onEnded {
                if store.canEdit {
                    inputIsFocused = true
                }
            }
        )
        .padding(.horizontal)
        #if os(iOS)
            .padding(.top, 8)
            // Keep the composer close to the home indicator when idle and leave a gap above the keyboard.
            .padding(.bottom, keyboardIsVisible ? 8 : -6)
        #else
            .padding(.vertical)
        #endif
    }

    private var canAddItem: Bool {
        store.canEdit && !newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func removeItems(_ ids: [String]) {
        inputIsFocused = false
        focusedItemID = nil
        #if os(macOS)
            store.remove(ids, undoManager: undoManager)
            // Return focus to the list so Command-Z applies to the deletion.
            listIsFocused = true
        #else
            store.remove(ids, undoManager: undoManager ?? fallbackUndoManager)
            undoFocusRequest = UUID()
        #endif
    }

    private func addItem() {
        guard canAddItem else {
            return
        }
        guard let result = store.add(newItem) else { return }
        newItem = ""
        if case .existing(let id, let wasCompleted) = result {
            itemHighlight = ItemHighlight(itemID: id)
            AccessibilityNotification.Announcement(
                wasCompleted
                    ? String(localized: .duplicateItemReopened)
                    : String(localized: .duplicateItem)
            ).post()
        }
    }
}

#if os(iOS)
    private struct InteractiveKeyboardDismissal<Composer: View>: ViewModifier {
        let scrollPhase: ScrollPhase
        let showsComposer: Bool
        let composer: Composer
        @State private var bottomMargin: CGFloat = 0
        @State private var pendingBottomMargin: CGFloat = 0

        func body(content: Content) -> some View {
            GeometryReader { geometry in
                let bottomInset = geometry.safeAreaInsets.bottom

                ZStack(alignment: .bottom) {
                    content
                        .contentMargins(
                            .bottom,
                            showsComposer ? bottomMargin : bottomInset,
                            for: .scrollContent
                        )
                        .ignoresSafeArea(edges: .bottom)
                    if showsComposer {
                        composer
                            .onGeometryChange(for: CGFloat.self) {
                                bottomInset + $0.size.height
                            } action: { margin in
                                pendingBottomMargin = margin
                                if scrollPhase == .idle {
                                    bottomMargin = margin
                                }
                            }
                    }
                }
            }
            .onChange(of: scrollPhase) {
                // Changing the list's insets during interactive keyboard dismissal resets
                // its overscroll. Let the native bounce finish before updating the margin.
                if scrollPhase == .idle {
                    bottomMargin = pendingBottomMargin
                }
            }
        }
    }
#endif

private struct ObsidianBasketRow: View {
    let store: ObsidianBasketStore
    let item: ObsidianBasketItem
    let focusedItem: FocusState<String?>.Binding
    let remove: () -> Void
    @State private var nameSelection: TextSelection?
    #if os(macOS)
        @State private var isHovered = false
        @FocusState private var deleteIsFocused: Bool
    #endif

    private var nameIsFocused: Bool { focusedItem.wrappedValue == item.id }

    var body: some View {
        let name = store.nameDrafts[item.id] ?? item.title
        HStack {
            Toggle(
                isOn: Binding(
                    get: { item.isCompleted },
                    set: { _ in store.toggle(item.id) }
                )
            ) {
                #if os(macOS)
                    Text(item.title)
                #else
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
                #endif
            }
            #if os(macOS)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.vertical, 8)
            #else
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isCompleted ? .completed : .notCompleted)
            #endif
            .padding(.horizontal, 8)
            .background {
                // Include the padding in hit testing so clicks beside the checkbox still toggle it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.toggle(item.id)
                    }
                    .allowsHitTesting(store.canEdit)
                    .accessibilityHidden(true)
            }
            // Keep the wider hit area without pushing the item name inward.
            .padding(.trailing, -8)

            TextField(
                .itemName,
                text: Binding(
                    get: { name },
                    set: { store.editName(item.id, to: $0) }
                ),
                selection: $nameSelection
            )
            .textFieldStyle(.plain)
            .foregroundStyle(item.isCompleted && !nameIsFocused ? Color.clear : Color.primary)
            .overlay(alignment: .leading) {
                // Keep the completed style consistent on macOS, where text fields ignore strikethrough.
                if item.isCompleted && !nameIsFocused {
                    Text(name)
                        .foregroundStyle(.primary)
                        .strikethrough()
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused(focusedItem, equals: item.id)
            .submitLabel(.done)
            .onSubmit {
                focusedItem.wrappedValue = nil
            }
            .onChange(of: nameIsFocused) { _, focused in
                if !focused {
                    store.finishNameEditing(item.id)
                }
                #if os(macOS)
                    if focused {
                        // Start with a caret so a click to edit doesn't select the existing name.
                        nameSelection = TextSelection(insertionPoint: name.endIndex)
                    }
                #endif
            }
            .accessibilityLabel(.itemName)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
                .frame(minHeight: 44)
            #else
                .padding(.vertical, 8)
                // An unfocused macOS text field only reacted over its text. Cover the full name
                // area until editing starts, then leave native caret and selection handling intact.
                .overlay {
                    if !nameIsFocused {
                        Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedItem.wrappedValue = item.id
                        }
                        .allowsHitTesting(store.canEdit)
                        .accessibilityHidden(true)
                    }
                }
            #endif
            #if os(macOS)
                // Keep the control's space reserved so the name doesn't move on hover.
                Button(role: .destructive, action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .imageScale(.medium)
                .buttonStyle(.borderless)
                .padding(.horizontal, -8)
                .focused($deleteIsFocused)
                .foregroundStyle(.secondary)
                .help(.deleteNamedItem(item.title))
                .accessibilityLabel(.deleteNamedItem(item.title))
                .opacity(isHovered || deleteIsFocused ? 1 : 0)
                .allowsHitTesting(isHovered || deleteIsFocused)
            #endif
        }
        #if os(macOS)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        #else
            // Show completion changes immediately. The default iOS toggle animation felt slow.
            .transaction(value: item.isCompleted) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        #endif
        .accessibilityElement(children: .contain)
    }
}

private struct ConflictView: View {
    let store: ObsidianBasketStore
    let conflict: SyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var resolution = Resolution.merge
    @State private var showingError = false

    private enum Resolution: CaseIterable {
        case merge
        case local
        case remote

        var title: LocalizedStringResource {
            switch self {
            case .merge: .mergeChanges
            case .local: .keepLocalCopy
            case .remote: .useServerCopy
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(.resolution, selection: $resolution) {
                        ForEach(Resolution.allCases, id: \.self) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    #if os(macOS)
                        .pickerStyle(.radioGroup)
                    #else
                        .pickerStyle(.inline)
                    #endif
                } footer: {
                    switch resolution {
                    case .merge:
                        EmptyView()
                    case .local:
                        Text(.replaceServerWarning)
                    case .remote:
                        Text(
                            conflict.remote == nil
                                ? .clearLocalWarning
                                : .replaceLocalWarning
                        )
                    }
                }
                Section(.thisDevice) {
                    Text(store.note.text.isEmpty ? String(localized: .emptyNote) : store.note.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Section(.serverCopy) {
                    Text(
                        conflict.remote.map {
                            $0.text.isEmpty ? String(localized: .emptyNote) : $0.text
                        }
                            ?? String(localized: .missingServerNote)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(store.isSyncing)
            .safeAreaBar(edge: .bottom) {
                #if os(macOS)
                    HStack {
                        resolutionStatus
                        Spacer()
                        cancelButton
                        resolveButton
                    }
                    .padding()
                #else
                    resolutionStatus
                #endif
            }
            // Keep a compact navigation title on iOS. Omit the macOS title so the sheet
            // starts directly with the resolution choices, without an extra heading.
            #if os(iOS)
                .navigationTitle(.resolveConflict)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        cancelButton
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        resolveButton
                    }
                }
            #endif
        }
        .interactiveDismissDisabled(store.isSyncing)
        .alert(.couldNotResolveConflict, isPresented: $showingError) {
            Button(.ok, role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        #if os(macOS)
            .frame(width: 480, height: 560)
        #endif
    }

    @ViewBuilder
    private var resolutionStatus: some View {
        if store.isSyncing {
            ProgressView(.resolvingConflict)
                #if os(macOS)
                    .controlSize(.small)
                #else
                    .padding()
                #endif
        } else if store.errorMessage != nil {
            Button {
                showingError = true
            } label: {
                Label(.showError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            #if os(iOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            #endif
        }
    }

    private var cancelButton: some View {
        Button(.cancel, role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(store.isSyncing)
    }

    private var resolveButton: some View {
        Button(.resolve, systemImage: "checkmark", role: .confirm) {
            let resolution = resolution
            Task {
                switch resolution {
                case .merge:
                    await store.resolveConflict(.merge)
                case .local:
                    await store.resolveConflict(.keepLocal)
                case .remote:
                    store.useRemoteVersion()
                }
                if store.errorMessage != nil {
                    showingError = true
                }
            }
        }
        #if os(macOS)
            .labelStyle(.titleOnly)
        #else
            .labelStyle(.iconOnly)
        #endif
        .keyboardShortcut(.defaultAction)
        .disabled(store.isSyncing)
    }
}
