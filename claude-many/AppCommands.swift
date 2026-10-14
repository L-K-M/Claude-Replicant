import SwiftUI
import AppKit
import Combine

/// The focused window's profile actions, exposed to the menu bar. Menus read
/// the precomputed titles and enabled flags; the closures act on the window's
/// current selection. Value type rebuilt by the view on every state change.
struct ProfileCommandContext {
    // State for labels and enablement
    var selectionCount: Int = 0
    var canOpen: Bool = false
    var canStop: Bool = false
    var canRename: Bool = false
    var canReveal: Bool = false
    var canCopyPath: Bool = false
    var canDelete: Bool = false
    var canStartAll: Bool = false
    var canStopAll: Bool = false
    var openTitle: String = "Open"
    var stopTitle: String = "Stop"
    var deleteTitle: String = "Delete Profile…"

    // Actions (empty selection keeps them harmless)
    var newProfile: (ManagedApp) -> Void = { _ in }
    var openSelected: () -> Void = {}
    var stopSelected: () -> Void = {}
    var renameSelected: () -> Void = {}
    var deleteSelected: () -> Void = {}
    var revealSelected: () -> Void = {}
    var copyPathSelected: () -> Void = {}
    var startAll: () -> Void = {}
    var stopAll: () -> Void = {}
    var openProfilesFolder: () -> Void = {}
}

struct ProfileCommandContextKey: FocusedValueKey {
    typealias Value = ProfileCommandContext
}

extension FocusedValues {
    var profileCommands: ProfileCommandContext? {
        get { self[ProfileCommandContextKey.self] }
        set { self[ProfileCommandContextKey.self] = newValue }
    }
}

/// Single-window app, so the command context is effectively app-global:
/// the view pushes the current selection state here and menu commands read
/// it. `@FocusedValue` stays the primary lookup (correct if the app ever
/// grows a second window); this is the deterministic fallback — an
/// ObservableObject because Commands rebuilds track DynamicProperty
/// dependencies, not Observation-framework reads.
@MainActor
final class ProfileCommandCenter: ObservableObject {
    static let shared = ProfileCommandCenter()
    @Published var context = ProfileCommandContext()
}

struct ProfileCommands: Commands {
    @FocusedValue(\.profileCommands) private var focusedContext
    @ObservedObject private var center = ProfileCommandCenter.shared

    private var context: ProfileCommandContext {
        focusedContext ?? center.context
    }

    // Items carry no baked `.disabled`: enablement and selection-dependent
    // titles are owned by ProfilesMenuBridge, which keeps the synthesized
    // NSMenuItems in sync with the live context. Actions stay safe on their
    // own — every closure is a no-op when it does not apply.
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(ManagedApp.claude.newProfileTitle) { context.newProfile(.claude) }
                .keyboardShortcut("n")
            Button(ManagedApp.chatGPT.newProfileTitle) { context.newProfile(.chatGPT) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandMenu("Profiles") {
            Button("Open") { context.openSelected() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop") { context.stopSelected() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Rename…") { context.renameSelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Delete Profile…") { context.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)

            Divider()

            Button("Reveal in Finder") { context.revealSelected() }
            Button("Copy Data Folder Path") { context.copyPathSelected() }

            Divider()

            Button("Start All") { context.startAll() }
            Button("Stop All") { context.stopAll() }

            Divider()

            Button("Open Profiles Folder in Finder") { context.openProfilesFolder() }
        }

        CommandGroup(replacing: .help) {
            Button("Claude Replicant Help") {
                NSWorkspace.shared.open(AppBranding.helpURL)
            }
        }
    }
}

/// Mirrors the live command context onto the synthesized Profiles menu.
/// SwiftUI bakes dynamic titles and `.disabled` at command-build time and
/// does not reliably re-evaluate them; the bridge writes the current state
/// on every context change and at every menu validation, so menu items and
/// their key equivalents always match the window's real selection.
@MainActor
final class ProfilesMenuBridge: NSObject, NSMenuDelegate {
    private weak var menu: NSMenu?
    private var cancellable: AnyCancellable?
    private var remainingAttempts = 20

    func install() {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == "Profiles" }),
              let menu = item.submenu else {
            // The synthesized menu bar appears during scene setup; retry briefly.
            if remainingAttempts > 0 {
                remainingAttempts -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.install()
                }
            }
            return
        }
        self.menu = menu
        menu.delegate = self
        sync()
        cancellable = ProfileCommandCenter.shared.$context
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
    }

    // Indices match the CommandMenu layout above: Open, Stop, Rename,
    // Delete, sep, Reveal, Copy Path, sep, Start All, Stop All, sep, Folder.
    private func sync() {
        guard let menu, menu.items.count == 12 else { return }
        let context = ProfileCommandCenter.shared.context
        apply(menu.items[0], title: context.openTitle, enabled: context.canOpen)
        apply(menu.items[1], title: context.stopTitle, enabled: context.canStop)
        apply(menu.items[2], enabled: context.canRename)
        apply(menu.items[3], title: context.deleteTitle, enabled: context.canDelete)
        apply(menu.items[5], enabled: context.canReveal)
        apply(menu.items[6], enabled: context.canCopyPath)
        apply(menu.items[8], enabled: context.canStartAll)
        apply(menu.items[9], enabled: context.canStopAll)
    }

    private func apply(_ item: NSMenuItem, title: String? = nil, enabled: Bool) {
        if let title, item.title != title { item.title = title }
        item.isEnabled = enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        sync()
    }

    func menuWillOpen(_ menu: NSMenu) {
        sync()
    }
}
