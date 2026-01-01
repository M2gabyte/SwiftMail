import SwiftUI
import OSLog

private let settingsLogger = Logger(subsystem: "com.simplemail.app", category: "Settings")

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var themeManager = ThemeManager.shared
    @State private var showingSignOutAlert = false

    var body: some View {
        NavigationStack {
            List {
                // Account Section
                Section {
                    if let account = viewModel.currentAccount {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: account.photoURL ?? "")) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(.blue)
                                    .overlay {
                                        Text(account.name.prefix(1))
                                            .font(.title2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.white)
                                    }
                            }
                            .frame(width: 50, height: 50)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.headline)
                                Text(account.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    NavigationLink("Add Account") {
                        AddAccountView()
                    }
                } header: {
                    Text("Account")
                }

                // Swipe Actions Section
                Section {
                    Picker("Left Swipe", selection: $viewModel.settings.leftSwipeAction) {
                        ForEach(SwipeAction.allCases, id: \.self) { action in
                            Label(action.title, systemImage: action.icon)
                                .tag(action)
                        }
                    }

                    Picker("Right Swipe", selection: $viewModel.settings.rightSwipeAction) {
                        ForEach(SwipeAction.allCases, id: \.self) { action in
                            Label(action.title, systemImage: action.icon)
                                .tag(action)
                        }
                    }
                } header: {
                    Text("Swipe Actions")
                } footer: {
                    Text("Configure what happens when you swipe on emails in the inbox.")
                }

                // Display Section
                Section {
                    Toggle("Show Avatars", isOn: $viewModel.settings.showAvatars)
                        .onChange(of: viewModel.settings.showAvatars) { _, _ in viewModel.saveSettings() }

                    Picker("List Density", selection: $viewModel.settings.listDensity) {
                        Text("Comfortable").tag(ListDensity.comfortable)
                        Text("Compact").tag(ListDensity.compact)
                    }
                    .onChange(of: viewModel.settings.listDensity) { _, _ in viewModel.saveSettings() }

                    Picker("Theme", selection: $themeManager.currentTheme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Compact mode hides avatars and email snippets for a denser list.")
                }

                // Notifications Section
                Section {
                    Toggle("Enable Notifications", isOn: $viewModel.settings.notificationsEnabled)
                        .onChange(of: viewModel.settings.notificationsEnabled) { _, newValue in
                            if newValue {
                                Task {
                                    await viewModel.requestNotificationPermission()
                                }
                            }
                            viewModel.saveSettings()
                        }

                    if viewModel.settings.notificationsEnabled {
                        Toggle("New Emails", isOn: $viewModel.settings.notifyNewEmails)
                            .onChange(of: viewModel.settings.notifyNewEmails) { _, _ in viewModel.saveSettings() }
                        Toggle("Needs Reply", isOn: $viewModel.settings.notifyNeedsReply)
                            .onChange(of: viewModel.settings.notifyNeedsReply) { _, _ in viewModel.saveSettings() }
                        Toggle("VIP Senders", isOn: $viewModel.settings.notifyVIPSenders)
                            .onChange(of: viewModel.settings.notifyVIPSenders) { _, _ in viewModel.saveSettings() }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Receive notifications when new emails arrive during background sync.")
                }

                // Privacy Section
                Section {
                    Toggle("Require Face ID", isOn: $viewModel.settings.biometricLock)
                    Toggle("Block Remote Images", isOn: $viewModel.settings.blockRemoteImages)
                } header: {
                    Text("Privacy & Security")
                }

                // Signature Section
                Section {
                    NavigationLink("Email Signature") {
                        SignatureEditorView(signature: $viewModel.settings.signature)
                    }
                } header: {
                    Text("Compose")
                }

                // Smart Features Section
                Section {
                    Toggle("Auto-Summarize Long Emails", isOn: $viewModel.settings.autoSummarize)
                    Toggle("Smart Reply Suggestions", isOn: $viewModel.settings.smartReplies)

                    NavigationLink("VIP Senders") {
                        VIPSendersView()
                    }

                    NavigationLink("Blocked Senders") {
                        BlockedSendersView()
                    }
                } header: {
                    Text("Smart Features")
                } footer: {
                    Text("Powered by on-device Apple Intelligence. Your data stays private.")
                }

                // Gmail Settings Sync Section
                Section {
                    NavigationLink("Vacation Responder") {
                        VacationResponderView()
                    }

                    NavigationLink("Labels") {
                        LabelsManagementView()
                    }

                    NavigationLink("Filters") {
                        FiltersManagementView()
                    }

                    Button(action: {
                        Task {
                            await viewModel.syncGmailSettings()
                        }
                    }) {
                        HStack {
                            Text("Sync Gmail Settings")
                            Spacer()
                            if viewModel.isSyncingSettings {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isSyncingSettings)
                } header: {
                    Text("Gmail Settings")
                } footer: {
                    if let lastSync = viewModel.lastGmailSettingsSync {
                        Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    }
                }

                // Data Management Section
                Section {
                    Button(action: {
                        Task {
                            await viewModel.clearLocalCache()
                        }
                    }) {
                        HStack {
                            Text("Clear Local Cache")
                            Spacer()
                            Text(viewModel.cacheSize)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink("Snoozed Emails") {
                        SnoozedEmailsView()
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Clearing cache will remove locally stored emails. They'll be re-downloaded on next sync.")
                }

                // About Section
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    Link("Privacy Policy", destination: URL(string: "https://simplemail.app/privacy")!)
                    Link("Terms of Service", destination: URL(string: "https://simplemail.app/terms")!)
                    Link("Send Feedback", destination: URL(string: "mailto:support@simplemail.app")!)
                } header: {
                    Text("About")
                }

                // Sign Out
                Section {
                    Button("Sign Out", role: .destructive) {
                        showingSignOutAlert = true
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Sign Out?", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task {
                        await viewModel.signOut()
                    }
                }
            } message: {
                Text("You'll need to sign in again to access your email.")
            }
        }
    }
}

// MARK: - Settings Types

enum SwipeAction: String, CaseIterable, Codable {
    case archive
    case markRead
    case snooze
    case trash
    case star

    var title: String {
        switch self {
        case .archive: return "Archive"
        case .markRead: return "Mark Read/Unread"
        case .snooze: return "Snooze"
        case .trash: return "Trash"
        case .star: return "Star"
        }
    }

    var icon: String {
        switch self {
        case .archive: return "archivebox"
        case .markRead: return "envelope.open"
        case .snooze: return "clock"
        case .trash: return "trash"
        case .star: return "star"
        }
    }
}

enum ListDensity: String, Codable {
    case comfortable
    case compact
}

enum AppTheme: String, Codable {
    case system
    case light
    case dark
}

struct AppSettings: Codable {
    var leftSwipeAction: SwipeAction = .archive
    var rightSwipeAction: SwipeAction = .markRead
    var showAvatars: Bool = true
    var listDensity: ListDensity = .comfortable
    var theme: AppTheme = .system
    var notificationsEnabled: Bool = true
    var notifyNewEmails: Bool = true
    var notifyNeedsReply: Bool = true
    var notifyVIPSenders: Bool = true
    var biometricLock: Bool = false
    var blockRemoteImages: Bool = false
    var autoSummarize: Bool = true
    var smartReplies: Bool = true
    var signature: String = ""
}

// MARK: - Settings ViewModel

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var currentAccount: AuthService.Account?
    @Published var isSyncingSettings = false
    @Published var lastGmailSettingsSync: Date?
    @Published var cacheSize = "Calculating..."

    private let settingsKey = "appSettings"
    private let gmailSyncKey = "lastGmailSettingsSync"

    init() {
        loadSettings()
        currentAccount = AuthService.shared.currentAccount
        lastGmailSettingsSync = UserDefaults.standard.object(forKey: gmailSyncKey) as? Date
        calculateCacheSize()
    }

    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        }
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }

    func requestNotificationPermission() async {
        let granted = await BackgroundSyncManager.shared.requestNotificationPermission()
        if !granted {
            settings.notificationsEnabled = false
        }
    }

    func syncGmailSettings() async {
        isSyncingSettings = true
        defer { isSyncingSettings = false }

        do {
            // Fetch Gmail settings (labels, vacation responder, etc.)
            _ = try await GmailService.shared.fetchLabels()

            lastGmailSettingsSync = Date()
            UserDefaults.standard.set(lastGmailSettingsSync, forKey: gmailSyncKey)

            HapticFeedback.success()
        } catch {
            settingsLogger.error("Failed to sync Gmail settings: \(error.localizedDescription)")
            HapticFeedback.error()
        }
    }

    func clearLocalCache() async {
        EmailCacheManager.shared.clearCache()
        calculateCacheSize()
        HapticFeedback.success()
    }

    private func calculateCacheSize() {
        let count = EmailCacheManager.shared.cachedEmailCount
        cacheSize = "\(count) email\(count == 1 ? "" : "s")"
    }

    func signOut() async {
        EmailCacheManager.shared.clearCache()
        AuthService.shared.signOut()
    }
}

// MARK: - Placeholder Views

struct AddAccountView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Add Another Account")
                .font(.title2)
                .fontWeight(.semibold)

            Button(action: {
                Task {
                    try? await AuthService.shared.signIn()
                }
            }) {
                HStack {
                    Image(systemName: "envelope.badge.shield.half.filled")
                    Text("Sign in with Google")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
        }
        .navigationTitle("Add Account")
    }
}

struct SignatureEditorView: View {
    @Binding var signature: String
    @State private var showingLinkSheet = false
    @State private var linkText = ""
    @State private var linkURL = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Formatting Toolbar
            HStack(spacing: 16) {
                Button(action: insertBold) {
                    Image(systemName: "bold")
                        .font(.title3)
                }

                Button(action: insertItalic) {
                    Image(systemName: "italic")
                        .font(.title3)
                }

                Button(action: { showingLinkSheet = true }) {
                    Image(systemName: "link")
                        .font(.title3)
                }

                Divider()
                    .frame(height: 20)

                Button(action: insertLineBreak) {
                    Image(systemName: "return")
                        .font(.title3)
                }

                Spacer()

                Button(action: clearSignature) {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))

            Divider()

            // Signature Editor
            TextEditor(text: $signature)
                .focused($isEditorFocused)
                .padding()

            Divider()

            // Preview Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                SignaturePreview(signature: signature)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .background(Color(.systemGray6))
        }
        .navigationTitle("Email Signature")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingLinkSheet) {
            InsertLinkSheet(
                linkText: $linkText,
                linkURL: $linkURL,
                onInsert: insertLink
            )
        }
        .onAppear {
            isEditorFocused = true
        }
    }

    private func insertBold() {
        signature += "**bold text**"
    }

    private func insertItalic() {
        signature += "_italic text_"
    }

    private func insertLineBreak() {
        signature += "\n"
    }

    private func insertLink() {
        if !linkText.isEmpty && !linkURL.isEmpty {
            let formattedURL = linkURL.hasPrefix("http") ? linkURL : "https://\(linkURL)"
            signature += "[\(linkText)](\(formattedURL))"
        }
        linkText = ""
        linkURL = ""
    }

    private func clearSignature() {
        signature = ""
    }
}

// MARK: - Insert Link Sheet

struct InsertLinkSheet: View {
    @Binding var linkText: String
    @Binding var linkURL: String
    let onInsert: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link Text", text: $linkText)
                        .textInputAutocapitalization(.never)
                    TextField("URL", text: $linkURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Link Details")
                } footer: {
                    Text("Example: https://example.com")
                }
            }
            .navigationTitle("Insert Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onInsert()
                        dismiss()
                    }
                    .disabled(linkText.isEmpty || linkURL.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Signature Preview

struct SignaturePreview: View {
    let signature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if signature.isEmpty {
                Text("No signature")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                Text(parseSignature(signature))
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func parseSignature(_ text: String) -> AttributedString {
        var result = AttributedString(text)

        // Parse bold: **text**
        let boldPattern = /\*\*(.+?)\*\*/
        if let match = text.firstMatch(of: boldPattern) {
            let boldText = String(match.1)
            if let range = result.range(of: "**\(boldText)**") {
                result.replaceSubrange(range, with: AttributedString(boldText, attributes: AttributeContainer([.font: UIFont.boldSystemFont(ofSize: 15)])))
            }
        }

        // Parse italic: _text_
        let italicPattern = /_(.+?)_/
        if let match = text.firstMatch(of: italicPattern) {
            let italicText = String(match.1)
            if let range = result.range(of: "_\(italicText)_") {
                result.replaceSubrange(range, with: AttributedString(italicText, attributes: AttributeContainer([.font: UIFont.italicSystemFont(ofSize: 15)])))
            }
        }

        // Parse links: [text](url)
        let linkPattern = /\[(.+?)\]\((.+?)\)/
        if let match = text.firstMatch(of: linkPattern) {
            let linkText = String(match.1)
            let linkURL = String(match.2)
            let fullMatch = "[\(linkText)](\(linkURL))"
            if let range = result.range(of: fullMatch),
               let url = URL(string: linkURL) {
                var linkAttr = AttributedString(linkText)
                linkAttr.link = url
                linkAttr.foregroundColor = .blue
                linkAttr.underlineStyle = .single
                result.replaceSubrange(range, with: linkAttr)
            }
        }

        return result
    }
}

struct VIPSendersView: View {
    @State private var vipSenders: [String] = []
    @State private var showingAddSheet = false
    @State private var newSenderEmail = ""

    private let vipSendersKey = "vipSenders"

    var body: some View {
        List {
            ForEach(vipSenders, id: \.self) { sender in
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text(sender)
                        .font(.body)
                }
            }
            .onDelete(perform: removeVIP)
        }
        .navigationTitle("VIP Senders")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !vipSenders.isEmpty {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if vipSenders.isEmpty {
                ContentUnavailableView(
                    "No VIP Senders",
                    systemImage: "star",
                    description: Text("Add important senders to always be notified of their emails.")
                )
            }
        }
        .onAppear {
            loadVIPSenders()
        }
        .alert("Add VIP Sender", isPresented: $showingAddSheet) {
            TextField("Email address", text: $newSenderEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button("Cancel", role: .cancel) {
                newSenderEmail = ""
            }
            Button("Add") {
                addVIPSender()
            }
        } message: {
            Text("Enter the email address of the sender you want to mark as VIP.")
        }
    }

    private func loadVIPSenders() {
        vipSenders = UserDefaults.standard.stringArray(forKey: vipSendersKey) ?? []
    }

    private func addVIPSender() {
        let email = newSenderEmail.lowercased().trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, email.contains("@"), !vipSenders.contains(email) else {
            newSenderEmail = ""
            return
        }
        vipSenders.append(email)
        UserDefaults.standard.set(vipSenders, forKey: vipSendersKey)
        newSenderEmail = ""
        HapticFeedback.success()
    }

    private func removeVIP(at offsets: IndexSet) {
        vipSenders.remove(atOffsets: offsets)
        UserDefaults.standard.set(vipSenders, forKey: vipSendersKey)
        HapticFeedback.light()
    }
}

struct BlockedSendersView: View {
    @State private var blockedSenders: [String] = []

    private let blockedSendersKey = "blockedSenders"

    var body: some View {
        List {
            ForEach(blockedSenders, id: \.self) { sender in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sender)
                            .font(.body)
                    }
                    Spacer()
                }
            }
            .onDelete(perform: unblockSender)
        }
        .navigationTitle("Blocked Senders")
        .toolbar {
            if !blockedSenders.isEmpty {
                EditButton()
            }
        }
        .overlay {
            if blockedSenders.isEmpty {
                ContentUnavailableView(
                    "No Blocked Senders",
                    systemImage: "hand.raised",
                    description: Text("Blocked senders will be hidden from your inbox.")
                )
            }
        }
        .onAppear {
            loadBlockedSenders()
        }
    }

    private func loadBlockedSenders() {
        blockedSenders = UserDefaults.standard.stringArray(forKey: blockedSendersKey) ?? []
    }

    private func unblockSender(at offsets: IndexSet) {
        blockedSenders.remove(atOffsets: offsets)
        UserDefaults.standard.set(blockedSenders, forKey: blockedSendersKey)
        HapticFeedback.light()
    }
}

// MARK: - Vacation Responder View

struct VacationResponderView: View {
    @StateObject private var viewModel = VacationResponderViewModel()

    var body: some View {
        Form {
            Section {
                Toggle("Enable Vacation Responder", isOn: $viewModel.isEnabled)
            }

            if viewModel.isEnabled {
                Section {
                    DatePicker("Start Date", selection: $viewModel.startDate, displayedComponents: .date)
                    DatePicker("End Date", selection: $viewModel.endDate, displayedComponents: .date)
                }

                Section {
                    TextField("Subject", text: $viewModel.subject)
                    TextEditor(text: $viewModel.message)
                        .frame(minHeight: 150)
                } header: {
                    Text("Message")
                }

                Section {
                    Toggle("Only Reply to Contacts", isOn: $viewModel.onlyContacts)
                } footer: {
                    Text("When enabled, only emails from your contacts will receive auto-replies.")
                }
            }
        }
        .navigationTitle("Vacation Responder")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await viewModel.saveSettings()
                    }
                }
                .disabled(viewModel.isSaving)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .task {
            await viewModel.loadSettings()
        }
    }
}

@MainActor
class VacationResponderViewModel: ObservableObject {
    @Published var isEnabled = false
    @Published var startDate = Date()
    @Published var endDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @Published var subject = ""
    @Published var message = ""
    @Published var onlyContacts = false
    @Published var isLoading = false
    @Published var isSaving = false

    func loadSettings() async {
        isLoading = true
        // TODO: Load from Gmail API when vacation settings endpoint is added
        isLoading = false
    }

    func saveSettings() async {
        isSaving = true
        // TODO: Save to Gmail API when vacation settings endpoint is added
        HapticFeedback.success()
        isSaving = false
    }
}

// MARK: - Labels Management View

struct LabelsManagementView: View {
    @StateObject private var viewModel = LabelsManagementViewModel()

    var body: some View {
        List {
            Section {
                ForEach(viewModel.systemLabels) { label in
                    LabelRow(label: label)
                }
            } header: {
                Text("System Labels")
            }

            Section {
                ForEach(viewModel.userLabels) { label in
                    LabelRow(label: label)
                }
                .onDelete { indexSet in
                    Task {
                        await viewModel.deleteLabels(at: indexSet)
                    }
                }
            } header: {
                Text("Custom Labels")
            }
        }
        .navigationTitle("Labels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { viewModel.showingCreateLabel = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingCreateLabel) {
            CreateLabelView { name, color in
                Task {
                    await viewModel.createLabel(name: name, color: color)
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.systemLabels.isEmpty {
                ProgressView()
            }
        }
        .task {
            await viewModel.loadLabels()
        }
    }
}

struct LabelRow: View {
    let label: GmailLabel

    var body: some View {
        HStack {
            Circle()
                .fill(labelColor)
                .frame(width: 12, height: 12)

            Text(label.name)

            Spacer()

            if let count = label.messagesUnread, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var labelColor: Color {
        if let colorStr = label.color?.backgroundColor {
            return Color(hex: colorStr) ?? .gray
        }
        return .gray
    }
}

struct CreateLabelView: View {
    let onCreate: (String, Color) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedColor = Color.blue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label Name", text: $name)
                }

                Section {
                    ColorPicker("Color", selection: $selectedColor)
                }
            }
            .navigationTitle("New Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, selectedColor)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

@MainActor
class LabelsManagementViewModel: ObservableObject {
    @Published var systemLabels: [GmailLabel] = []
    @Published var userLabels: [GmailLabel] = []
    @Published var isLoading = false
    @Published var showingCreateLabel = false

    func loadLabels() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let labels = try await GmailService.shared.fetchLabels()
            systemLabels = labels.filter { $0.type == "system" }
            userLabels = labels.filter { $0.type == "user" }
        } catch {
            settingsLogger.error("Failed to load labels: \(error.localizedDescription)")
        }
    }

    func createLabel(name: String, color: Color) async {
        // TODO: Implement label creation via Gmail API
        HapticFeedback.success()
    }

    func deleteLabels(at indexSet: IndexSet) async {
        // TODO: Implement label deletion via Gmail API
        userLabels.remove(atOffsets: indexSet)
        HapticFeedback.medium()
    }
}

// MARK: - Filters Management View

struct FiltersManagementView: View {
    @StateObject private var viewModel = FiltersManagementViewModel()

    var body: some View {
        List {
            ForEach(viewModel.filters) { filter in
                FilterRow(filter: filter)
            }
            .onDelete { indexSet in
                Task {
                    await viewModel.deleteFilters(at: indexSet)
                }
            }
        }
        .navigationTitle("Filters")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { viewModel.showingCreateFilter = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingCreateFilter) {
            CreateFilterView { filter in
                Task {
                    await viewModel.createFilter(filter)
                }
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.filters.isEmpty {
                ContentUnavailableView(
                    "No Filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Create filters to automatically sort your emails.")
                )
            }
        }
        .task {
            await viewModel.loadFilters()
        }
    }
}

struct EmailFilter: Identifiable {
    let id: String
    let from: String?
    let to: String?
    let subject: String?
    let action: String
}

struct FilterRow: View {
    let filter: EmailFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let from = filter.from {
                Text("From: \(from)")
                    .font(.subheadline)
            }
            if let subject = filter.subject {
                Text("Subject: \(subject)")
                    .font(.subheadline)
            }
            Text(filter.action)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct CreateFilterView: View {
    let onCreate: (EmailFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var subject = ""
    @State private var action = "Archive"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("From", text: $from)
                    TextField("Subject contains", text: $subject)
                } header: {
                    Text("Match Criteria")
                }

                Section {
                    Picker("Action", selection: $action) {
                        Text("Archive").tag("Archive")
                        Text("Mark as Read").tag("Mark as Read")
                        Text("Star").tag("Star")
                        Text("Apply Label").tag("Apply Label")
                        Text("Delete").tag("Delete")
                    }
                } header: {
                    Text("Action")
                }
            }
            .navigationTitle("New Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let filter = EmailFilter(
                            id: UUID().uuidString,
                            from: from.isEmpty ? nil : from,
                            to: nil,
                            subject: subject.isEmpty ? nil : subject,
                            action: action
                        )
                        onCreate(filter)
                        dismiss()
                    }
                    .disabled(from.isEmpty && subject.isEmpty)
                }
            }
        }
    }
}

@MainActor
class FiltersManagementViewModel: ObservableObject {
    @Published var filters: [EmailFilter] = []
    @Published var isLoading = false
    @Published var showingCreateFilter = false

    func loadFilters() async {
        isLoading = true
        // TODO: Load filters from Gmail API
        isLoading = false
    }

    func createFilter(_ filter: EmailFilter) async {
        filters.append(filter)
        HapticFeedback.success()
        // TODO: Create filter via Gmail API
    }

    func deleteFilters(at indexSet: IndexSet) async {
        filters.remove(atOffsets: indexSet)
        HapticFeedback.medium()
        // TODO: Delete filter via Gmail API
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
