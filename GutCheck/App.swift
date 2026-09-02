import SwiftUI
import CloudKit
import UIKit

/// CloudKit sync plumbing: push registration (silent pushes wake the sync
/// engine) and routing share-invite acceptance into CloudSync.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// Invite tapped while Scoop is already running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudSync.shared.acceptShare(metadata)
    }

    /// Invite tapped while Scoop is not running: the metadata arrives with the
    /// scene connection instead of the callback above.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            CloudSync.shared.acceptShare(metadata)
        }
    }
}

@main
struct GutCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .fontDesign(.rounded)
                .tint(DS.brand)
                .accentColor(DS.brand)
                .task {
                    CloudSync.shared.start(store: store)
                    DoseReminders.shared.attach(store: store)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await CloudSync.shared.fetchNow() }
                    }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.data.hasOnboarded {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            }
        } else {
            OnboardingFlow()
        }
    }
}
