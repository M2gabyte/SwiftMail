import SwiftUI
import SwiftData
import BackgroundTasks
import LocalAuthentication
import OSLog

private let logger = Logger(subsystem: "com.simplemail.app", category: "SimpleMailApp")

@main
struct SimpleMailApp: App {
    @StateObject private var authService = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Result of ModelContainer initialization - allows graceful error handling instead of fatalError
    private let modelContainerResult: Result<ModelContainer, Error>

    var sharedModelContainer: ModelContainer? {
        try? modelContainerResult.get()
    }

    init() {
        // Initialize ModelContainer with error handling
        let schema = Schema([
            Email.self,
            EmailDetail.self,
            SnoozedEmail.self,
            SenderPreference.self,
            QueuedEmail.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainerResult = .success(container)
        } catch {
            logger.error("Failed to create ModelContainer: \(error.localizedDescription)")
            self.modelContainerResult = .failure(error)
        }

        // Register background tasks
        BackgroundSyncManager.shared.registerBackgroundTasks()

        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
    }

    var body: some Scene {
        WindowGroup {
            if let container = sharedModelContainer {
                ContentView()
                    .environmentObject(authService)
                    .modelContainer(container)
                    .onOpenURL { url in
                        handleURL(url)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .openEmail)) { notification in
                        handleEmailNotification(notification)
                    }
            } else {
                DatabaseErrorView(error: modelContainerResult)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Clear badge count
                UNUserNotificationCenter.current().setBadgeCount(0)

            case .background:
                // Schedule background tasks
                BackgroundSyncManager.shared.scheduleBackgroundSync()
                BackgroundSyncManager.shared.scheduleNotificationCheck()
                BackgroundSyncManager.shared.scheduleSummaryProcessingIfNeeded()

            default:
                break
            }
        }
    }

    private func handleURL(_ url: URL) {
        // Handle OAuth callback
        logger.debug("Received URL: \(url.absoluteString)")
    }

    private func handleEmailNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let emailId = userInfo["emailId"] as? String,
              let threadId = userInfo["threadId"] as? String else {
            return
        }

        // Navigate to email detail
        // This would be handled by the navigation coordinator
        logger.debug("Open email: \(emailId) in thread: \(threadId)")
    }
}

// MARK: - Content View (Root)

struct ContentView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.modelContext) private var modelContext
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var biometricManager = BiometricAuthManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSignIn = true

    var body: some View {
        // Check configuration first
        if let configError = Config.validate() {
            ConfigurationErrorView(error: configError)
        } else {
            ZStack {
                Group {
                    if authService.isAuthenticated {
                        NavigationStack {
                            InboxView()
                        }
                            .transition(.opacity)
                    } else {
                        SignInView()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: authService.isAuthenticated)

                // Biometric Lock Screen
                if biometricManager.isLocked && authService.isAuthenticated {
                    LockScreenView()
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(themeManager.colorScheme)
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    biometricManager.lockIfNeeded()
                } else if newPhase == .active && biometricManager.isLocked {
                    Task {
                        await biometricManager.authenticate()
                    }
                }
            }
            .onAppear {
                EmailCacheManager.shared.configure(with: modelContext)
                SnoozeManager.shared.configure(with: modelContext)
                OutboxManager.shared.configure(with: modelContext)
                NetworkMonitor.shared.start()
            }
            .task {
                if authService.isAuthenticated {
                    await PeopleService.shared.preloadContacts()
                }
            }
        }
    }
}

// MARK: - Database Error View

struct DatabaseErrorView: View {
    let error: Result<ModelContainer, Error>

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 64))
                    .foregroundStyle(.red)

                Text("Database Error")
                    .font(.title)
                    .fontWeight(.bold)

                if case .failure(let err) = error {
                    Text(err.localizedDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Text("SimpleMail couldn't initialize its local database. Try restarting the app or reinstalling if the problem persists.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 12) {
                    Text("Error Code: DB_001")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospaced()

                    if let supportURL = URL(string: "mailto:support@simplemail.app?subject=Database%20Error%20DB_001") {
                        Link("Contact Support", destination: supportURL)
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Configuration Error View

struct ConfigurationErrorView: View {
    let error: ConfigurationError

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)

                Text("Configuration Error")
                    .font(.title)
                    .fontWeight(.bold)

                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                VStack(spacing: 12) {
                    Text("Error Code: CONFIG_\(errorCode)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospaced()

                    if let supportURL = URL(string: "mailto:support@simplemail.app?subject=Configuration%20Error%20CONFIG_\(errorCode)") {
                        Link("Contact Support", destination: supportURL)
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private var errorCode: String {
        switch error {
        case .missingClientId:
            return "001"
        case .missingRedirectUri:
            return "002"
        case .multipleErrors:
            return "999"
        }
    }
}

// MARK: - Lock Screen View

struct LockScreenView: View {
    @StateObject private var biometricManager = BiometricAuthManager.shared

    var body: some View {
        ZStack {
            // Blurred background
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("SimpleMail is Locked")
                    .font(.title2)
                    .fontWeight(.semibold)

                Button(action: {
                    Task {
                        await biometricManager.authenticate()
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: biometricManager.biometricIcon)
                        Text("Unlock with \(biometricManager.biometricName)")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 32)

                if let error = biometricManager.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Theme Manager

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var currentTheme: AppTheme = .system {
        didSet {
            saveTheme()
        }
    }

    var colorScheme: ColorScheme? {
        switch currentTheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private let themeKey = "appTheme"

    private init() {
        loadTheme()
    }

    private func loadTheme() {
        if let savedTheme = UserDefaults.standard.string(forKey: themeKey),
           let theme = AppTheme(rawValue: savedTheme) {
            currentTheme = theme
        }
    }

    private func saveTheme() {
        UserDefaults.standard.set(currentTheme.rawValue, forKey: themeKey)
    }
}

// MARK: - Biometric Auth Manager

@MainActor
class BiometricAuthManager: ObservableObject {
    static let shared = BiometricAuthManager()

    @Published var isLocked: Bool = false
    @Published var authError: String?

    private let settingsKey = "appSettings"

    var isBiometricEnabled: Bool {
        let accountEmail = AuthService.shared.currentAccount?.email
        if let data = AccountDefaults.data(for: settingsKey, accountEmail: accountEmail),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings.biometricLock
        }
        return false
    }

    var biometricType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    var biometricName: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    private init() {}

    func lockIfNeeded() {
        if isBiometricEnabled {
            isLocked = true
        }
    }

    func authenticate() async {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Try device passcode as fallback
            await authenticateWithPasscode()
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock SimpleMail to access your emails"
            )

            if success {
                isLocked = false
                authError = nil
            }
        } catch {
            authError = error.localizedDescription
            // Try device passcode as fallback
            await authenticateWithPasscode()
        }
    }

    private func authenticateWithPasscode() async {
        let context = LAContext()

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock SimpleMail to access your emails"
            )

            if success {
                isLocked = false
                authError = nil
            }
        } catch {
            authError = error.localizedDescription
        }
    }
}

// MARK: - Sign In View

struct SignInView: View {
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        ZStack {
            // Use a guaranteed dark gradient for the sign-in screen
            LinearGradient(
                colors: [
                    Color(red: 0.1, green: 0.2, blue: 0.4),
                    Color(red: 0.15, green: 0.15, blue: 0.3)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 16) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)

                    Text("SimpleMail")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("A better way to email")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                // Features
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "bolt.fill", text: "120fps buttery smooth scrolling")
                    FeatureRow(icon: "brain.head.profile", text: "Smart triage with Apple Intelligence")
                    FeatureRow(icon: "arrow.clockwise", text: "Background sync that just works")
                }
                .padding(.horizontal, 40)

                Spacer()

                // Sign In Button
                Button(action: signIn) {
                    HStack(spacing: 12) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        } else {
                            Image("google-logo")
                                .resizable()
                                .frame(width: 20, height: 20)
                        }

                        Text("Sign in with Google")
                    }
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)
                .padding(.horizontal, 32)

                // Privacy note
                Text("Your emails stay on your device. We never see them.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
                    .frame(height: 40)
            }
        }
        .alert("Sign In Failed", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error?.localizedDescription ?? "Unknown error")
        }
    }

    private func signIn() {
        isLoading = true

        Task {
            do {
                try await AuthService.shared.signIn()

                // Request notification permission
                await BackgroundSyncManager.shared.requestNotificationPermission()

                // Haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

            } catch {
                self.error = error
            }

            isLoading = false
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Haptic Feedback

@MainActor
enum HapticFeedback {
    private static var isEnabled: Bool {
        let accountEmail = AuthService.shared.currentAccount?.email
        guard let data = AccountDefaults.data(for: "appSettings", accountEmail: accountEmail),
              let settings = try? JSONDecoder().decode(HapticSettings.self, from: data) else {
            return true // Default to enabled
        }
        return settings.hapticsEnabled
    }

    // Minimal struct to decode just the haptics setting
    private struct HapticSettings: Decodable {
        var hapticsEnabled: Bool = true
    }

    static func light() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func medium() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    static func heavy() {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func error() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    static func selection() {
        guard isEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}

// MARK: - View Extensions

extension View {
    func withHapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) -> some View {
        self.simultaneousGesture(
            TapGesture().onEnded { _ in
                let generator = UIImpactFeedbackGenerator(style: style)
                generator.impactOccurred()
            }
        )
    }
}

// MARK: - Custom Animations

extension Animation {
    static var smoothSpring: Animation {
        .spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)
    }

    static var quickSpring: Animation {
        .spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0)
    }

    static var snappy: Animation {
        .spring(response: 0.2, dampingFraction: 1, blendDuration: 0)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
}
