import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
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

                    Picker("List Density", selection: $viewModel.settings.listDensity) {
                        Text("Comfortable").tag(ListDensity.comfortable)
                        Text("Compact").tag(ListDensity.compact)
                    }

                    Picker("Theme", selection: $viewModel.settings.theme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                } header: {
                    Text("Display")
                }

                // Notifications Section
                Section {
                    Toggle("Push Notifications", isOn: $viewModel.settings.notificationsEnabled)
                        .onChange(of: viewModel.settings.notificationsEnabled) { _, newValue in
                            if newValue {
                                Task {
                                    await viewModel.requestNotificationPermission()
                                }
                            }
                        }

                    if viewModel.settings.notificationsEnabled {
                        Toggle("New Emails", isOn: $viewModel.settings.notifyNewEmails)
                        Toggle("Needs Reply", isOn: $viewModel.settings.notifyNeedsReply)
                        Toggle("VIP Senders", isOn: $viewModel.settings.notifyVIPSenders)
                    }
                } header: {
                    Text("Notifications")
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

    private let settingsKey = "appSettings"

    init() {
        loadSettings()
        currentAccount = AuthService.shared.currentAccount
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

    func signOut() async {
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

    var body: some View {
        VStack {
            TextEditor(text: $signature)
                .padding()
        }
        .navigationTitle("Email Signature")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct VIPSendersView: View {
    @State private var vipSenders: [String] = []

    var body: some View {
        List {
            ForEach(vipSenders, id: \.self) { sender in
                Text(sender)
            }
            .onDelete { indexSet in
                vipSenders.remove(atOffsets: indexSet)
            }
        }
        .navigationTitle("VIP Senders")
        .toolbar {
            EditButton()
        }
        .overlay {
            if vipSenders.isEmpty {
                ContentUnavailableView(
                    "No VIP Senders",
                    systemImage: "star",
                    description: Text("Mark important senders as VIP to always be notified.")
                )
            }
        }
    }
}

struct BlockedSendersView: View {
    @State private var blockedSenders: [String] = []

    var body: some View {
        List {
            ForEach(blockedSenders, id: \.self) { sender in
                Text(sender)
            }
            .onDelete { indexSet in
                blockedSenders.remove(atOffsets: indexSet)
            }
        }
        .navigationTitle("Blocked Senders")
        .toolbar {
            EditButton()
        }
        .overlay {
            if blockedSenders.isEmpty {
                ContentUnavailableView(
                    "No Blocked Senders",
                    systemImage: "hand.raised",
                    description: Text("Blocked senders will be automatically moved to trash.")
                )
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
