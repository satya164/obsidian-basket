import AppIntents
import SwiftUI

struct SettingsView: View {
    let store: ObsidianBasketStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ConnectionSettings
    @State private var savedSettings: ConnectionSettings
    @State private var password = ""
    @State private var savedPassword: String?
    @State private var passwordWasEdited = false
    @State private var passwordIsVisible = false
    @FocusState private var focusedField: Field?
    #if os(iOS)
        @State private var passwordIsFocused = false
    #endif
    @State private var credentialError: String?
    @State private var connectionResult: ConnectionResult?
    @State private var showingConnectionResult = false
    @State private var isChecking = false
    @State private var confirmingDiscard = false
    @State private var confirmingReset = false
    @State private var issue: SettingsIssue?
    @State private var connectionTask: Task<Void, Never>?
    #if os(macOS)
        @FocusState private var formIsFocused: Bool
    #endif

    private enum Field {
        case server
        case database
        case username
        case hiddenPassword
        case visiblePassword
        case notePath
    }

    private enum ConnectionResult {
        case connected(noteExists: Bool)
        case failed(String)

        var message: String {
            switch self {
            case .connected(let noteExists):
                noteExists
                    ? String(localized: .connectedNoteFound)
                    : String(localized: .connectedNoteMissing)
            case .failed(let message):
                message
            }
        }
    }

    private enum SettingsIssue {
        case keychain(String)
        case connection(String)
        case save(String)
        case reset(String)
        case shortcuts(String)

        var title: String {
            switch self {
            case .keychain: String(localized: .couldNotAccessPassword)
            case .connection: String(localized: .connectionFailedTitle)
            case .save: String(localized: .couldNotSaveSettings)
            case .reset: String(localized: .couldNotResetSettings)
            case .shortcuts: String(localized: .couldNotOpenShortcuts)
            }
        }

        var message: String {
            switch self {
            case .keychain(let message), .connection(let message), .save(let message), .reset(let message),
                .shortcuts(let message):
                message
            }
        }
    }

    init(store: ObsidianBasketStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
        _savedSettings = State(initialValue: store.settings)
    }

    private var hasChanges: Bool {
        settings != savedSettings
            || (savedPassword.map { password != $0 } ?? passwordWasEdited)
    }

    private var canSave: Bool {
        hasChanges && savedPassword != nil && !store.isSyncing
    }

    var body: some View {
        Group {
            #if os(macOS)
                editor
                    .safeAreaBar(edge: .bottom) {
                        HStack {
                            Spacer()
                            Button(.cancel, action: requestDismissal)
                                .keyboardShortcut(.cancelAction)
                            Button(.save, action: save)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canSave)
                        }
                        .padding()
                    }
                    .frame(width: 480, height: 500)
                    .navigationTitle(.settingsTitle)
            #else
                NavigationStack { editor }
            #endif
        }
        #if os(macOS)
            .dismissalConfirmationDialog(.unsavedChanges, shouldPresent: hasChanges) {
                Button(.discardChanges, role: .destructive) { resetDraft() }
                Button(.keepEditing, role: .cancel) {}
            }
        #else
            .background {
                SheetDismissalConfirmation(hasChanges: hasChanges, onDismissAttempt: requestDismissal)
            }
            .confirmationDialog(
                .unsavedChanges, isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button(.discardChanges, role: .destructive) {
                    resetDraft()
                    dismissWithoutConfirmation()
                }
                Button(.keepEditing, role: .cancel) {}
            }
        #endif
        .alert(
            issue?.title ?? "",
            isPresented: Binding(
                get: { issue != nil },
                set: { if !$0 { issue = nil } }
            ), presenting: issue
        ) { issue in
            if case .keychain = issue {
                Button(.tryAgain) { loadPassword() }
            }
            Button(.ok, role: .cancel) {}
        } message: { issue in
            Text(issue.message)
        }
    }

    private var editor: some View {
        Form {
            Section {
                LabeledContent(.serverURL) {
                    TextField(
                        .serverURL, text: $settings.server,
                        prompt: Text(verbatim: "https://example.com")
                    )
                        .labelsHidden()
                        .focused($focusedField, equals: .server)
                        #if os(iOS)
                            .keyboardType(.URL)
                        #endif
                }
                .focusOnTap { focusedField = .server }
                LabeledContent(.database) {
                    TextField(.database, text: $settings.database, prompt: Text(""))
                        .labelsHidden()
                        .focused($focusedField, equals: .database)
                }
                .focusOnTap { focusedField = .database }
                LabeledContent(.username) {
                    TextField(.username, text: $settings.username, prompt: Text(""))
                        .labelsHidden()
                        .focused($focusedField, equals: .username)
                        .textContentType(.username)
                }
                .focusOnTap { focusedField = .username }
                LabeledContent(.password) {
                    HStack {
                        Group {
                            #if os(iOS)
                                PasswordTextField(
                                    text: passwordBinding, isSecure: !passwordIsVisible,
                                    isFocused: $passwordIsFocused
                                )
                            #else
                                if passwordIsVisible {
                                    TextField(.password, text: passwordBinding, prompt: Text(""))
                                        .focused($focusedField, equals: .visiblePassword)
                                } else {
                                    SecureField(.password, text: passwordBinding, prompt: Text(""))
                                        .focused($focusedField, equals: .hiddenPassword)
                                }
                            #endif
                        }
                        .labelsHidden()
                        .textContentType(.password)

                        Button {
                            passwordIsVisible.toggle()
                            #if os(iOS)
                                passwordIsFocused = true
                            #else
                                focusedField = passwordIsVisible ? .visiblePassword : .hiddenPassword
                            #endif
                        } label: {
                            Image(systemName: passwordIsVisible ? "eye.slash" : "eye")
                                #if os(iOS)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                #endif
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(passwordIsVisible ? .hidePassword : .showPassword)
                        .help(passwordIsVisible ? .hidePassword : .showPassword)
                    }
                }
                #if os(iOS)
                    .focusOnTap { passwordIsFocused = true }
                #endif
            } header: {
                Text(.couchDB)
            } footer: {
                Text(
                    .liveSyncSettingsHelp
                )
            }
            .labeledContentStyle(SettingsFieldStyle())
            Section {
                LabeledContent(.notePath) {
                    TextField(.notePath, text: $settings.notePath, prompt: Text(""))
                        .labelsHidden()
                        .focused($focusedField, equals: .notePath)
                }
                .labeledContentStyle(SettingsFieldStyle())
                .focusOnTap { focusedField = .notePath }
                Toggle(.caseSensitivePaths, isOn: $settings.caseSensitivePaths)
            } header: {
                Text(.obsidianNote)
            } footer: {
                Text(
                    .notePathHelp
                )
            }
            Section {
                HStack {
                    Button(.testConnection) {
                        connectionTask = Task { await testConnection() }
                    }
                    .disabled(savedPassword == nil || isChecking)
                    connectionStatus
                    Spacer(minLength: 0)
                }
                #if os(iOS)
                    // The status target is already 44 points tall. Extra form insets made
                    // this row taller than the Reset Settings row.
                    .listRowInsets(.vertical, 0)
                #endif
            }
            Section {
                Text(.siriExample)
                #if os(iOS)
                    ShortcutsLink()
                #else
                    if let shortcutsURL = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.shortcuts")
                    {
                        Button(.openShortcuts) {
                            Task {
                                do {
                                    _ = try await NSWorkspace.shared.openApplication(
                                        at: shortcutsURL, configuration: NSWorkspace.OpenConfiguration())
                                } catch {
                                    issue = .shortcuts(error.localizedDescription)
                                }
                            }
                        }
                    }
                #endif
            } header: {
                Text(.siri)
            } footer: {
                #if os(iOS)
                    Text(.siriSetupHelp)
                #else
                    Text(.siriMacSetupHelp)
                #endif
            }
            Section {
                Button(.resetSettings, role: .destructive) {
                    confirmingReset = true
                }
                .disabled(store.isSyncing)
                .confirmationDialog(
                    .resetSettingsConfirmation, isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button(.resetSettings, role: .destructive, action: resetSettings)
                    Button(.cancel, role: .cancel) {}
                } message: {
                    Text(
                        .resetSettingsHelp
                    )
                }
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        #if os(macOS)
            // Start with focus on the form so the first stored value isn't selected on opening.
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focused($formIsFocused)
            .defaultFocus($formIsFocused, true)
        #endif
        #if os(iOS)
            .textInputAutocapitalization(.never)
            .background(DisableSpellChecking().allowsHitTesting(false))
            .scrollDismissesKeyboard(.interactively)
            .gesture(DismissKeyboardGesture())
            .navigationTitle(.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.cancel, action: requestDismissal)
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(.save, action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave)
                }
            }
        #endif
        .onAppear(perform: loadDraft)
        .onDisappear {
            connectionTask?.cancel()
            showingConnectionResult = false
            passwordIsVisible = false
        }
        .onChange(of: settings) {
            connectionTask?.cancel()
            showingConnectionResult = false
            connectionResult = nil
        }
        .onChange(of: password) {
            connectionTask?.cancel()
            showingConnectionResult = false
            connectionResult = nil
        }
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { password },
            set: {
                password = $0
                passwordWasEdited = true
            }
        )
    }

    private var connectionStatus: some View {
        // Reserve one slot for idle, progress and results so testing doesn't shift the row.
        ZStack {
            if isChecking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(.testingConnection)
            } else if let failure = connectionIssue {
                Button {
                    if case .keychain = failure {
                        issue = failure
                    } else {
                        showingConnectionResult = true
                    }
                } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(.showFailureDetails(failure.title))
                .help(failure.message)
            } else if case .connected(let noteExists) = connectionResult, let connectionResult {
                Button {
                    showingConnectionResult = true
                } label: {
                    Image(systemName: noteExists ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(noteExists ? Color.green : Color.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(connectionResult.message)
                .help(connectionResult.message)
            }
        }
        #if os(iOS)
            .frame(width: 44, height: 44)
        #else
            .frame(width: 20, height: 20)
        #endif
        .popover(isPresented: $showingConnectionResult) {
            if let connectionResult {
                Text(connectionResult.message)
                    .textSelection(.enabled)
                    .padding()
                    .frame(idealWidth: 280, maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var connectionIssue: SettingsIssue? {
        if let credentialError {
            return .keychain(credentialError)
        }
        if case .failed(let message) = connectionResult {
            return .connection(message)
        }
        return nil
    }

    private func requestDismissal() {
        #if os(iOS)
            if hasChanges {
                confirmingDiscard = true
            } else {
                dismiss()
            }
        #else
            dismiss()
        #endif
    }

    private func loadDraft() {
        settings = store.settings
        savedSettings = store.settings
        connectionResult = nil
        passwordWasEdited = false
        passwordIsVisible = false
        loadPassword()
    }

    private func loadPassword() {
        savedPassword = nil
        credentialError = nil
        do {
            let storedPassword = try CredentialStore.password(for: savedSettings)
            if !passwordWasEdited {
                password = storedPassword
            }
            savedPassword = storedPassword
        } catch {
            credentialError = error.localizedDescription
            issue = .keychain(error.localizedDescription)
        }
    }

    private func resetDraft() {
        connectionTask?.cancel()
        settings = savedSettings
        passwordIsVisible = false
        password = savedPassword ?? ""
        passwordWasEdited = false
        connectionResult = nil
    }

    private func dismissWithoutConfirmation() {
        var transaction = Transaction()
        transaction.dismissBehavior = .destructive
        withTransaction(transaction) { dismiss() }
    }

    private func save() {
        do {
            try store.saveSettings(settings, password: password)
            settings = store.settings
            savedSettings = settings
            savedPassword = password
            dismissWithoutConfirmation()
            Task { await store.sync() }
        } catch {
            issue = .save(error.localizedDescription)
        }
    }

    private func resetSettings() {
        connectionTask?.cancel()
        do {
            try store.resetSettings()
            loadDraft()
        } catch {
            issue = .reset(error.localizedDescription)
        }
    }

    private func testConnection() async {
        showingConnectionResult = false
        isChecking = true
        connectionResult = nil
        defer { isChecking = false }
        do {
            let settings = try settings.validated()
            let note = try await CouchDBClient(settings: settings, password: password).load()
            guard !Task.isCancelled else { return }
            let result = ConnectionResult.connected(noteExists: note != nil)
            connectionResult = result
            AccessibilityNotification.Announcement(result.message).post()
        } catch {
            guard !Task.isCancelled else { return }
            connectionResult = .failed(error.localizedDescription)
            AccessibilityNotification.Announcement(String(localized: .connectionFailedAnnouncement))
                .post()
        }
    }
}

// Stack labels above values to leave the full row width for long URLs.
private struct SettingsFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            configuration.label
                .font(.subheadline)
                .foregroundStyle(.secondary)
            configuration.content
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
            .frame(minHeight: 44, alignment: .leading)
        #endif
    }
}

extension View {
    @ViewBuilder
    fileprivate func focusOnTap(_ action: @escaping () -> Void) -> some View {
        #if os(iOS)
            // Include the label and padding in the focus target. Taps outside the input didn't focus it.
            padding()
                .contentShape(.rect)
                .onTapGesture(perform: action)
                .listRowInsets(.all, 0)
        #else
            self
        #endif
    }
}
