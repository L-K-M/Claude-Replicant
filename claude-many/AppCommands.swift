import SwiftUI
import AppKit
import Combine
import os

/// The focused window's profile actions, exposed to the menu bar. Menus read
/// the precomputed titles and enabled flags; the closures act on the window's
/// current selection. Value type rebuilt by the view on every state change.
struct ProfileCommandContext {
    // State for labels and enablement
    var selectionCount: Int = 0
    var canOpen: Bool = false
    var canStop: Bool = false
    var canRestart: Bool = false
    var canRename: Bool = false
    var canReveal: Bool = false
    var canCopyPath: Bool = false
    var canDelete: Bool = false
    var canStartAll: Bool = false
    var canStopAll: Bool = false
    var openTitle: String = "Open"
    var stopTitle: String = "Stop"
    var restartTitle: String = "Restart"
    var deleteTitle: String = "Delete Profile…"

    // Actions (empty selection keeps them harmless)
    var newProfile: (ManagedApp) -> Void = { _ in }
    var openSelected: () -> Void = {}
    var stopSelected: () -> Void = {}
    var restartSelected: () -> Void = {}
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

        CommandMenu(ProfilesMenu.title) {
            Button(ProfilesMenu.Item.open.title) { context.openSelected() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(ProfilesMenu.Item.stop.title) { context.stopSelected() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button(ProfilesMenu.Item.restart.title) { context.restartSelected() }
                .keyboardShortcut("r")
            // No Return shortcut: a menu key equivalent fires in every
            // window, text fields included. The list handles Return itself.
            Button(ProfilesMenu.Item.rename.title) { context.renameSelected() }
            Button(ProfilesMenu.Item.delete.title) { context.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)

            Divider()

            Button(ProfilesMenu.Item.reveal.title) { context.revealSelected() }
            Button(ProfilesMenu.Item.copyPath.title) { context.copyPathSelected() }

            Divider()

            Button(ProfilesMenu.Item.startAll.title) { context.startAll() }
            Button(ProfilesMenu.Item.stopAll.title) { context.stopAll() }

            Divider()

            Button(ProfilesMenu.Item.openFolder.title) { context.openProfilesFolder() }
        }

        CommandGroup(replacing: .help) {
            Button("Claude Replicant Help") {
                NSWorkspace.shared.open(AppBranding.helpURL)
            }
        }
    }
}

/// The Profiles menu as SwiftUI builds it. `ProfilesMenuBridge` finds the
/// menu and its items by these titles.
enum ProfilesMenu {
    static let title = "Profiles"

    enum Item: CaseIterable {
        case open, stop, restart, rename, delete, reveal, copyPath, startAll, stopAll, openFolder

        /// The title SwiftUI gives the item. The bridge retitles some.
        var title: String {
            switch self {
            case .open: return "Open"
            case .stop: return "Stop"
            case .restart: return "Restart"
            case .rename: return "Rename…"
            case .delete: return "Delete Profile…"
            case .reveal: return "Reveal in Finder"
            case .copyPath: return "Copy Data Folder Path"
            case .startAll: return "Start All"
            case .stopAll: return "Stop All"
            case .openFolder: return "Open Profiles Folder in Finder"
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
    private var cancellable: AnyCancellable?
    private var remainingAttempts = 20
    /// Items matched so far, kept after the bridge retitles them. Weak keys:
    /// items SwiftUI replaces go away, and new ones arrive with their
    /// original titles.
    private let matchedItems = NSMapTable<NSMenuItem, MatchedItem>.weakToStrongObjects()
    private var reportedMissingItems = false
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? AppBranding.name, category: "ProfilesMenu")

    private final class MatchedItem {
        let item: ProfilesMenu.Item
        init(_ item: ProfilesMenu.Item) { self.item = item }
    }

    func install() {
        guard let menu = Self.profilesMenu() else {
            // The synthesized menu bar appears during scene setup; retry briefly.
            if remainingAttempts > 0 {
                remainingAttempts -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.install()
                }
            }
            return
        }
        sync(menu, with: ProfileCommandCenter.shared.context)
        cancellable = ProfileCommandCenter.shared.$context
            .receive(on: RunLoop.main)
            .sink { [weak self] context in
                // Looked up each time: SwiftUI may rebuild the menu.
                guard let self, let menu = Self.profilesMenu() else { return }
                self.sync(menu, with: context)
            }
    }

    private static func profilesMenu() -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == ProfilesMenu.title }?.submenu
    }

    /// AppKit ignores `isEnabled` while `autoenablesItems` is on, the
    /// default, so the bridge turns it off before writing states.
    func sync(_ menu: NSMenu, with context: ProfileCommandContext) {
        menu.delegate = self
        menu.autoenablesItems = false

        var found: Set<ProfilesMenu.Item> = []
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            guard let item = match(menuItem) else { continue }
            found.insert(item)
            let (title, isEnabled) = Self.state(of: item, in: context)
            if let title, menuItem.title != title { menuItem.title = title }
            menuItem.isEnabled = isEnabled
        }
        reportMissingItems(Set(ProfilesMenu.Item.allCases).subtracting(found))
    }

    private func match(_ menuItem: NSMenuItem) -> ProfilesMenu.Item? {
        if let matched = matchedItems.object(forKey: menuItem) { return matched.item }
        guard let item = ProfilesMenu.Item.allCases.first(where: { $0.title == menuItem.title }) else { return nil }
        matchedItems.setObject(MatchedItem(item), forKey: menuItem)
        return item
    }

    /// The title to show (nil keeps the original) and whether it applies.
    private static func state(of item: ProfilesMenu.Item, in context: ProfileCommandContext) -> (String?, Bool) {
        switch item {
        case .open: return (context.openTitle, context.canOpen)
        case .stop: return (context.stopTitle, context.canStop)
        case .restart: return (context.restartTitle, context.canRestart)
        case .rename: return (nil, context.canRename)
        case .delete: return (context.deleteTitle, context.canDelete)
        case .reveal: return (nil, context.canReveal)
        case .copyPath: return (nil, context.canCopyPath)
        case .startAll: return (nil, context.canStartAll)
        case .stopAll: return (nil, context.canStopAll)
        case .openFolder: return (nil, true)
        }
    }

    /// A renamed or removed command would silently stay enabled; say so once.
    private func reportMissingItems(_ missing: Set<ProfilesMenu.Item>) {
        guard !missing.isEmpty, !reportedMissingItems else { return }
        reportedMissingItems = true
        Self.logger.error("Profiles menu items not found: \(String(describing: missing), privacy: .public)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        sync(menu, with: ProfileCommandCenter.shared.context)
    }

    func menuWillOpen(_ menu: NSMenu) {
        sync(menu, with: ProfileCommandCenter.shared.context)
    }
}
