import SwiftUI
import AppKit

@main
struct ClaudeReplicantApp: App {
    @State private var manager: ProfileManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Built in init() rather than as a property initializer: SILGen
        // crashes evaluating the manager's default arguments in the @State
        // initializer context on Xcode 16.4.
        _manager = State(initialValue: ProfileManager())
    }

    var body: some Scene {
        // A single management window, like System Settings: the profile list
        // is the whole app, so opening additional copies of it adds nothing.
        Window(AppBranding.name, id: "main") {
            ContentView(manager: manager)
                .onAppear { manager.load() }
        }
        .defaultSize(width: 640, height: 440)
        .commands { ProfileCommands() }

        Settings {
            SettingsView(manager: manager)
        }
    }
}

/// The app only supervises Claude instances while its window is open, so it
/// follows the single-window-utility convention and quits when the last
/// window closes. Running Claude instances keep running and are adopted on
/// the next launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBridge = ProfilesMenuBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBridge.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
