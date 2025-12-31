import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct SimpleMailApp: App {
    @StateObject private var authService = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Email.self,
            EmailDetail.self,
            SnoozedEmail.self,
            SenderPreference.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Register background tasks
        BackgroundSyncManager.shared.registerBackgroundTasks()

        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
                .onOpenURL { url in
                    handleURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openEmail)) { notification in
                    handleEmailNotification(notification)
                }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Clear badge count
                UNUserNotificationCenter.current().setBadgeCount(0)

            case .background:
                // Schedule background tasks
                BackgroundSyncManager.shared.scheduleBackgroundSync()
                BackgroundSyncManager.shared.scheduleNotificationCheck()

            default:
                break
            }
        }
    }

    private func handleURL(_ url: URL) {
        // Handle OAuth callback
        print("Received URL: \(url)")
    }

    private func handleEmailNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let emailId = userInfo["emailId"] as? String,
              let threadId = userInfo["threadId"] as? String else {
            return
        }

        // Navigate to email detail
        // This would be handled by the navigation coordinator
        print("Open email: \(emailId) in thread: \(threadId)")
    }
}

// MARK: - Content View (Root)

struct ContentView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showingSignIn = true

    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            } else {
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: authService.isAuthenticated)
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showingCompose = false
    @State private var showingSearch = false

    var body: some View {
        TabView(selection: $selectedTab) {
            InboxTab(
                showingCompose: $showingCompose,
                showingSearch: $showingSearch
            )
            .tabItem {
                Label("Inbox", systemImage: "tray.fill")
            }
            .tag(0)

            BriefingScreenView()
                .tabItem {
                    Label("Briefing", systemImage: "newspaper.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView()
        }
        .sheet(isPresented: $showingSearch) {
            SearchView()
        }
    }
}

// MARK: - Inbox Tab

struct InboxTab: View {
    @Binding var showingCompose: Bool
    @Binding var showingSearch: Bool

    var body: some View {
        InboxView()
    }
}

// MARK: - Sign In View

struct SignInView: View {
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        ZStack {
            TimeOfDayGradient()
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo
                VStack(spacing: 16) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, options: .repeating)

                    Text("SimpleMail")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("A better way to email")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
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
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image("google-logo")
                                .resizable()
                                .frame(width: 20, height: 20)
                        }

                        Text("Sign in with Google")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isLoading)
                .padding(.horizontal, 32)

                // Privacy note
                Text("Your emails stay on your device. We never see them.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
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
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - Haptic Feedback

enum HapticFeedback {
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    static func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    static func selection() {
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
