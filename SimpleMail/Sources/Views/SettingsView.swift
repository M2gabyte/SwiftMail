import SwiftUI
import OSLog

private let settingsLogger = Logger(subsystem: "com.simplemail.app", category: "Settings")

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var themeManager = ThemeManager.shared
    @State private var showingSignOutAlert = false
    @State private var summaryStats = SummaryQueue.statsSnapshot()
    @State private var debugTestResult: String?
    @State private var showingDebugTestResult = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                accountSection
                swipeActionsSection
                displaySection
                notificationsSection
                privacySection
                composeSection
                inboxSection
                smartFeaturesSection
                summaryDebugSection
                debugSection
                gmailSettingsSection
                dataSection
                advancedSection
                aboutSection
                signOutSection
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
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
            .alert("Inbox Cache Tests", isPresented: $showingDebugTestResult, presenting: debugTestResult) { _ in
                Button("OK", role: .cancel) {}
            } message: { result in
                Text(result)
            }
            .onAppear {
                summaryStats = SummaryQueue.statsSnapshot()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            ForEach(viewModel.accounts, id: \.id) { account in
                Button {
                    viewModel.switchAccount(to: account)
                } label: {
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
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .font(.subheadline.weight(.semibold))
                            Text(account.email)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if viewModel.currentAccount?.id == account.id {
                            Label("Current", systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }

            NavigationLink("Add Account") {
                AddAccountView()
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private var swipeActionsSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "arrow.left", color: .blue)
                Picker("Left Swipe", selection: $viewModel.settings.leftSwipeAction) {
                    ForEach(SwipeAction.allCases, id: \.self) { action in
                        Label(action.title, systemImage: action.icon)
                            .tag(action)
                    }
                }
            }
            .font(.callout)

            HStack(spacing: 12) {
                SettingsIcon(systemName: "arrow.right", color: .blue)
                Picker("Right Swipe", selection: $viewModel.settings.rightSwipeAction) {
                    ForEach(SwipeAction.allCases, id: \.self) { action in
                        Label(action.title, systemImage: action.icon)
                            .tag(action)
                    }
                }
            }
            .font(.callout)
        } header: {
            Text("Swipe Actions")
        } footer: {
            Text("Configure what happens when you swipe on emails in the inbox.")
        }
    }

    @ViewBuilder
    private var displaySection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "person.circle.fill", color: .cyan)
                Toggle("Show Avatars", isOn: $viewModel.settings.showAvatars)
            }
            .font(.callout)
            .onChange(of: viewModel.settings.showAvatars) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "text.alignleft", color: .indigo)
                Picker("List Density", selection: $viewModel.settings.listDensity) {
                    Text("Comfortable").tag(ListDensity.comfortable)
                    Text("Compact").tag(ListDensity.compact)
                }
            }
            .font(.callout)
            .onChange(of: viewModel.settings.listDensity) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "circle.lefthalf.filled", color: .purple)
                Picker("Theme", selection: $themeManager.currentTheme) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
            }
            .font(.callout)

            HStack(spacing: 12) {
                SettingsIcon(systemName: "iphone.radiowaves.left.and.right", color: .orange)
                Toggle("Haptic Feedback", isOn: $viewModel.settings.hapticsEnabled)
            }
            .font(.callout)
            .onChange(of: viewModel.settings.hapticsEnabled) { _, _ in viewModel.saveSettings() }
        } header: {
            Text("Display")
        } footer: {
            Text("Compact mode hides avatars and email snippets for a denser list.")
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "bell.badge.fill", color: .red)
                Toggle("Enable Notifications", isOn: $viewModel.settings.notificationsEnabled)
            }
            .onChange(of: viewModel.settings.notificationsEnabled) { _, newValue in
                if newValue {
                    Task {
                        await viewModel.requestNotificationPermission()
                    }
                }
                viewModel.saveSettings()
            }

            if viewModel.settings.notificationsEnabled {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "envelope.fill", color: .orange)
                    Toggle("New Emails", isOn: $viewModel.settings.notifyNewEmails)
                }
                .onChange(of: viewModel.settings.notifyNewEmails) { _, _ in viewModel.saveSettings() }

                HStack(spacing: 12) {
                    SettingsIcon(systemName: "arrowshape.turn.up.left.fill", color: .yellow)
                    Toggle("Needs Reply", isOn: $viewModel.settings.notifyNeedsReply)
                }
                .onChange(of: viewModel.settings.notifyNeedsReply) { _, _ in viewModel.saveSettings() }

                HStack(spacing: 12) {
                    SettingsIcon(systemName: "star.fill", color: .yellow)
                    Toggle("VIP Senders", isOn: $viewModel.settings.notifyVIPSenders)
                }
                .onChange(of: viewModel.settings.notifyVIPSenders) { _, _ in viewModel.saveSettings() }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Receive notifications when new emails arrive during background sync.")
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "faceid", color: .blue)
                Toggle("Require Face ID", isOn: $viewModel.settings.biometricLock)
            }
            .onChange(of: viewModel.settings.biometricLock) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "photo.on.rectangle.angled", color: .orange)
                Toggle("Block Remote Images", isOn: $viewModel.settings.blockRemoteImages)
            }
            .onChange(of: viewModel.settings.blockRemoteImages) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "shield.lefthalf.filled", color: .green)
                Toggle("Block Tracking Pixels", isOn: $viewModel.settings.blockTrackingPixels)
            }
            .onChange(of: viewModel.settings.blockTrackingPixels) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "link.badge.plus", color: .mint)
                Toggle("Strip Link Tracking Parameters", isOn: $viewModel.settings.stripTrackingParameters)
            }
            .onChange(of: viewModel.settings.stripTrackingParameters) { _, _ in viewModel.saveSettings() }
        } header: {
            Text("Privacy & Security")
        } footer: {
            Text("Email content stays on your device. Tracking protection removes hidden pixels and common URL trackers.")
        }
    }

    @ViewBuilder
    private var composeSection: some View {
        Section {
            NavigationLink {
                SignatureEditorView(signature: $viewModel.settings.signature)
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "signature", color: .teal)
                    Text("Email Signature")
                }
            }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "arrow.uturn.backward.circle.fill", color: .purple)
                Picker("Undo Send", selection: $viewModel.settings.undoSendDelaySeconds) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }
            }
            .onChange(of: viewModel.settings.undoSendDelaySeconds) { _, _ in viewModel.saveSettings() }

            NavigationLink {
                ScheduledSendsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "calendar.badge.clock", color: .orange)
                    Text("Scheduled Sends")
                }
            }
        } header: {
            Text("Compose")
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        Section {
            NavigationLink {
                PrimaryInboxRulesView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "tray.full.fill", color: .indigo)
                    Text("Primary Inbox")
                }
            }

            NavigationLink {
                PinnedTabSettingsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "pin.fill", color: .orange)
                    Text("Pinned Tab")
                }
            }
        } header: {
            Text("Inbox")
        }
    }

    @ViewBuilder
    private var smartFeaturesSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "sparkles", color: .purple)
                Toggle("Auto-Summarize Long Emails", isOn: $viewModel.settings.autoSummarize)
            }
            .onChange(of: viewModel.settings.autoSummarize) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "bolt.fill", color: .orange)
                Toggle("Precompute Summaries (Recommended)", isOn: $viewModel.settings.precomputeSummaries)
            }
            .onChange(of: viewModel.settings.precomputeSummaries) { _, _ in viewModel.saveSettings() }

            HStack(spacing: 12) {
                SettingsIcon(systemName: "clock.badge.checkmark", color: .indigo)
                Toggle("Aggressive Background Summaries", isOn: $viewModel.settings.backgroundSummaryProcessing)
            }
            .onChange(of: viewModel.settings.backgroundSummaryProcessing) { _, _ in viewModel.saveSettings() }
            .disabled(!viewModel.settings.precomputeSummaries)

            HStack(spacing: 12) {
                SettingsIcon(systemName: "reply.all.fill", color: .blue)
                Toggle("Smart Reply Suggestions", isOn: $viewModel.settings.smartReplies)
            }
            .onChange(of: viewModel.settings.smartReplies) { _, _ in viewModel.saveSettings() }

            NavigationLink {
                VIPSendersView(accountEmail: viewModel.currentAccount?.email)
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "star.fill", color: .yellow)
                    Text("VIP Senders")
                }
            }

            NavigationLink {
                BlockedSendersView(accountEmail: viewModel.currentAccount?.email)
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "hand.raised.fill", color: .red)
                    Text("Blocked Senders")
                }
            }
        } header: {
            Text("Smart Features")
        } footer: {
            Text("Powered by on-device Apple Intelligence. Aggressive background summaries may use more battery.")
        }
    }

    @ViewBuilder
    private var summaryDebugSection: some View {
        Section {
            summaryStatRow("Queued", value: summaryStats.enqueued)
            summaryStatRow("Processed", value: summaryStats.processed)
            summaryStatRow("Skipped (Short)", value: summaryStats.skippedShort)
            summaryStatRow("Skipped (Battery)", value: summaryStats.skippedBattery)
            summaryStatRow("Skipped (Throttle)", value: summaryStats.skippedThrottle)
            summaryStatRow("Skipped (Cached)", value: summaryStats.skippedCached)
            summaryStatRow("Skipped (No Account)", value: summaryStats.skippedNoAccount)
            summaryStatRow("Failed", value: summaryStats.failed)

            if let lastRun = summaryStats.lastRun {
                let date = Date(timeIntervalSince1970: lastRun)
                HStack {
                    Text("Last Run")
                    Spacer()
                    Text(date, style: .time)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Refresh") {
                    summaryStats = SummaryQueue.statsSnapshot()
                }
                Spacer()
                Button("Reset") {
                    SummaryQueue.resetStats()
                    summaryStats = SummaryQueue.statsSnapshot()
                }
                .foregroundStyle(.red)
            }
        } header: {
            Text("Summary Debug")
        } footer: {
            Text("Counts are local to this device. Use Refresh after sync to see new activity.")
        }
    }

    @ViewBuilder
    private var debugSection: some View {
        Section {
            Button("Run Inbox Cache Tests") {
                Task { @MainActor in
                    debugTestResult = await InboxViewModelCacheTests.runAllTests()
                    showingDebugTestResult = true
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Runs cache invalidation checks in InboxViewModel.")
        }
    }

    @ViewBuilder
    private var gmailSettingsSection: some View {
        Section {
            NavigationLink {
                VacationResponderView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "palm.tree.fill", color: .orange)
                    Text("Vacation Responder")
                }
            }

            NavigationLink {
                LabelsManagementView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "tag.fill", color: .green)
                    Text("Labels")
                }
            }

            NavigationLink {
                FiltersManagementView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "line.3.horizontal.decrease.circle.fill", color: .blue)
                    Text("Filters")
                }
            }

            Button(action: {
                Task {
                    await viewModel.syncGmailSettings()
                }
            }) {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .cyan)
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
    }

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button(action: {
                Task {
                    await viewModel.clearLocalCache()
                }
            }) {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "trash.fill", color: .red)
                    Text("Clear Local Cache")
                    Spacer()
                    Text(viewModel.cacheSize)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                SnoozedEmailsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "clock.fill", color: .orange)
                    Text("Snoozed Emails")
                }
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Clearing cache will remove locally stored emails. They'll be re-downloaded on next sync.")
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "rectangle.stack.fill", color: .indigo)
                Toggle("Conversation Threading", isOn: $viewModel.settings.conversationThreading)
            }
            .onChange(of: viewModel.settings.conversationThreading) { _, _ in viewModel.saveSettings() }
        } header: {
            Text("Advanced")
        } footer: {
            Text("When threading is off, each message is shown individually instead of grouped by conversation.")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "info.circle.fill", color: .gray)
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            if let privacyURL = URL(string: "https://simplemail.app/privacy") {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "hand.raised.fill", color: .green)
                    Link("Privacy Policy", destination: privacyURL)
                }
            }
            if let termsURL = URL(string: "https://simplemail.app/terms") {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "doc.text.fill", color: .blue)
                    Link("Terms of Service", destination: termsURL)
                }
            }
            if let feedbackURL = URL(string: "mailto:support@simplemail.app") {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "envelope.fill", color: .orange)
                    Link("Send Feedback", destination: feedbackURL)
                }
            }
        } header: {
            Text("About")
        }
    }

    @ViewBuilder
    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showingSignOutAlert = true
            }
        }
    }

    private func summaryStatRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.2))
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 28, height: 28)
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
    var blockTrackingPixels: Bool = true
    var stripTrackingParameters: Bool = true
    var autoSummarize: Bool = true
    var precomputeSummaries: Bool = true
    var backgroundSummaryProcessing: Bool = false
    var smartReplies: Bool = true
    var signature: String = ""
    var undoSendDelaySeconds: Int = 5
    var hapticsEnabled: Bool = true

    // Advanced settings
    var conversationThreading: Bool = true
    // Note: listDensity (already above) is also surfaced in Advanced as "Preview density"
}

// MARK: - Settings ViewModel

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var currentAccount: AuthService.Account?
    @Published var accounts: [AuthService.Account] = []
    @Published var isSyncingSettings = false
    @Published var lastGmailSettingsSync: Date?
    @Published var cacheSize = "Calculating..."

    private let settingsKeyBase = "appSettings"
    private let gmailSyncKeyBase = "lastGmailSettingsSync"
    private var accountEmail: String? { currentAccount?.email.lowercased() }
    private var accountChangeObserver: NSObjectProtocol?

    init() {
        currentAccount = AuthService.shared.currentAccount
        accounts = AuthService.shared.accounts
        loadSettings()
        lastGmailSettingsSync = AccountDefaults.date(for: gmailSyncKeyBase, accountEmail: accountEmail)
        calculateCacheSize()

        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .accountDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentAccount = AuthService.shared.currentAccount
                self.accounts = AuthService.shared.accounts
                self.loadSettings()
                self.lastGmailSettingsSync = AccountDefaults.date(for: self.gmailSyncKeyBase, accountEmail: self.accountEmail)
                self.calculateCacheSize()
            }
        }
    }

    deinit {
        if let observer = accountChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadSettings() {
        guard let data = AccountDefaults.data(for: settingsKeyBase, accountEmail: accountEmail) else {
            settingsLogger.debug("No saved settings found, using defaults")
            return
        }

        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settingsLogger.debug("Loaded settings successfully")
        } catch {
            settingsLogger.error("Failed to decode settings: \(error.localizedDescription)")
        }
    }

    func saveSettings() {
        do {
            let encoded = try JSONEncoder().encode(settings)
            AccountDefaults.setData(encoded, for: settingsKeyBase, accountEmail: accountEmail)
            settingsLogger.debug("Saved settings successfully")
            BackgroundSyncManager.shared.scheduleSummaryProcessingIfNeeded()
        } catch {
            settingsLogger.error("Failed to encode settings: \(error.localizedDescription)")
        }
    }

    func requestNotificationPermission() async {
        let granted = await BackgroundSyncManager.shared.requestNotificationPermission()
        if !granted {
            settings.notificationsEnabled = false
        }
    }

    func switchAccount(to account: AuthService.Account) {
        AuthService.shared.switchAccount(to: account)
        currentAccount = account
        loadSettings()
        lastGmailSettingsSync = AccountDefaults.date(for: gmailSyncKeyBase, accountEmail: accountEmail)
        calculateCacheSize()
    }

    func syncGmailSettings() async {
        isSyncingSettings = true
        defer { isSyncingSettings = false }

        do {
            // Fetch Gmail settings (labels, vacation responder, etc.)
            _ = try await GmailService.shared.fetchLabels()

            lastGmailSettingsSync = Date()
            AccountDefaults.setDate(lastGmailSettingsSync, for: gmailSyncKeyBase, accountEmail: accountEmail)

            HapticFeedback.success()
        } catch {
            settingsLogger.error("Failed to sync Gmail settings: \(error.localizedDescription)")
            HapticFeedback.error()
        }
    }

    func clearLocalCache() async {
        EmailCacheManager.shared.clearCache(accountEmail: accountEmail)
        calculateCacheSize()
        HapticFeedback.success()
    }

    private func calculateCacheSize() {
        let count = EmailCacheManager.shared.cachedEmailCount(accountEmail: accountEmail)
        cacheSize = "\(count) email\(count == 1 ? "" : "s")"
    }

    func signOut() async {
        EmailCacheManager.shared.clearCache(accountEmail: accountEmail)
        AuthService.shared.signOut()
    }
}

// MARK: - Placeholder Views

struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var initialAccountCount: Int?

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
        .onAppear {
            initialAccountCount = AuthService.shared.accounts.count
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountDidChange)) { _ in
            if let initial = initialAccountCount,
               AuthService.shared.accounts.count > initial {
                dismiss()
            }
        }
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
        let boldPattern = #/\*\*(.+?)\*\*/#
        if let match = text.firstMatch(of: boldPattern) {
            let boldText = String(match.1)
            if let range = result.range(of: "**\(boldText)**") {
                result.replaceSubrange(range, with: AttributedString(boldText, attributes: AttributeContainer([.font: UIFont.boldSystemFont(ofSize: 15)])))
            }
        }

        // Parse italic: _text_
        let italicPattern = #/_(.+?)_/#
        if let match = text.firstMatch(of: italicPattern) {
            let italicText = String(match.1)
            if let range = result.range(of: "_\(italicText)_") {
                result.replaceSubrange(range, with: AttributedString(italicText, attributes: AttributeContainer([.font: UIFont.italicSystemFont(ofSize: 15)])))
            }
        }

        // Parse links: [text](url)
        let linkPattern = #/\[(.+?)\]\((.+?)\)/#
        if let match = text.firstMatch(of: linkPattern) {
            let linkText = String(match.1)
            let linkURL = String(match.2)
            let fullMatch = "[\(linkText)](\(linkURL))"
            if let range = result.range(of: fullMatch),
               let url = URL(string: linkURL) {
                var linkAttr = AttributedString(linkText)
                linkAttr.link = url
                linkAttr.foregroundColor = Color.blue
                linkAttr.underlineStyle = Text.LineStyle.single
                result.replaceSubrange(range, with: linkAttr)
            }
        }

        return result
    }
}

struct VIPSendersView: View {
    let accountEmail: String?
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
        vipSenders = AccountDefaults.stringArray(for: vipSendersKey, accountEmail: accountEmail)
    }

    private func addVIPSender() {
        let email = newSenderEmail.lowercased().trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, email.contains("@"), !vipSenders.contains(email) else {
            newSenderEmail = ""
            return
        }
        vipSenders.append(email)
        AccountDefaults.setStringArray(vipSenders, for: vipSendersKey, accountEmail: accountEmail)
        newSenderEmail = ""
        HapticFeedback.success()
    }

    private func removeVIP(at offsets: IndexSet) {
        vipSenders.remove(atOffsets: offsets)
        AccountDefaults.setStringArray(vipSenders, for: vipSendersKey, accountEmail: accountEmail)
        HapticFeedback.light()
    }
}

struct BlockedSendersView: View {
    let accountEmail: String?
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
        blockedSenders = AccountDefaults.stringArray(for: blockedSendersKey, accountEmail: accountEmail)
    }

    private func unblockSender(at offsets: IndexSet) {
        blockedSenders.remove(atOffsets: offsets)
        AccountDefaults.setStringArray(blockedSenders, for: blockedSendersKey, accountEmail: accountEmail)
        HapticFeedback.light()
    }
}

struct ScheduledSendsView: View {
    @State private var scheduled = ScheduledSendManager.shared.loadAll()
    @State private var rescheduleItem: ScheduledSend?
    @State private var rescheduleDate = Date().addingTimeInterval(60 * 15)

    var body: some View {
        List {
            if scheduled.isEmpty {
                ContentUnavailableView(
                    "No Scheduled Emails",
                    systemImage: "clock",
                    description: Text("Scheduled sends will appear here.")
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(scheduled) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                            .font(.headline)
                        Text("To: \(item.to.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Send at \(item.sendAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Reschedule") {
                                rescheduleItem = item
                                rescheduleDate = max(Date().addingTimeInterval(60), item.sendAt)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                ScheduledSendManager.shared.remove(id: item.id)
                                scheduled = ScheduledSendManager.shared.loadAll()
                            } label: {
                                Text("Cancel")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Scheduled Sends")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $rescheduleItem) { item in
            NavigationStack {
                Form {
                    DatePicker(
                        "Send at",
                        selection: $rescheduleDate,
                        in: Date().addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                .navigationTitle("Reschedule")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            rescheduleItem = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            ScheduledSendManager.shared.reschedule(id: item.id, date: rescheduleDate)
                            scheduled = ScheduledSendManager.shared.loadAll()
                            rescheduleItem = nil
                        }
                    }
                }
            }
        }
        .onAppear {
            scheduled = ScheduledSendManager.shared.loadAll()
        }
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

// MARK: - Preview

#Preview {
    SettingsView()
}
