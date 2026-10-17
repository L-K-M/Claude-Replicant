import SwiftUI
import AppKit

/// Keys for app-wide preferences stored in UserDefaults.
enum AppPreferences {
    /// Shows the menu bar extra and keeps the app running without a window.
    static let showsMenuBarExtra = "showsMenuBarExtra"
}

/// The menu bar extra's label. It is on screen for as long as the extra is,
/// so it also keeps status discovery running after the window closes.
struct MenuBarLabel: View {
    let manager: ProfileManager

    var body: some View {
        Image(systemName: manager.runningCount > 0 ? "person.2.fill" : "person.2")
            .accessibilityLabel("\(AppBranding.name): \(manager.statusSummary)")
            .task { await manager.monitorRunningProcesses() }
    }
}

/// Switch to any profile without opening the window: click to start it or
/// bring it to the front.
struct MenuBarContent: View {
    @Bindable var manager: ProfileManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(manager.statusSummary)

        Divider()

        ForEach(manager.listedProfiles) { profile in
            Button {
                perform { manager.open(id: profile.id) }
            } label: {
                Label {
                    Text(profile.label)
                } icon: {
                    Image(nsImage: MenuStatusImage.image(running: manager.isRunning(id: profile.id)))
                }
            }
            .disabled(manager.bundleStatus(for: profile.app) != .available)
        }

        let running = manager.listedProfiles.filter { manager.isRunning(id: $0.id) }
        if !running.isEmpty {
            Menu("Stop") {
                ForEach(running) { profile in
                    Button(profile.label) { perform { manager.stop(id: profile.id) } }
                }
                Divider()
                Button("Stop All") { manager.stopAll() }
            }
        }
        Button("Start All") { perform { manager.startAll() } }
            .disabled(!manager.listedProfiles.contains {
                manager.bundleStatus(for: $0.app) == .available && !manager.isRunning(id: $0.id)
            })

        Divider()

        Button("Open \(AppBranding.name)", action: showWindow)
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit \(AppBranding.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        NSApp.activate()
        openWindow(id: AppBranding.mainWindowID)
    }

    /// Errors are shown as an alert in the window, which may be closed.
    private func perform(_ action: () -> Void) {
        action()
        if manager.lastError != nil { showWindow() }
    }
}

/// Menus draw SF Symbols as monochrome templates, so status dots are
/// plain colored images: green while running, a gray ring when stopped.
private enum MenuStatusImage {
    private static let diameter: CGFloat = 9

    static func image(running: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if running {
                NSColor.systemGreen.setFill()
                dot.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
