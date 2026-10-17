import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var manager: ProfileManager

    @State private var selection: Set<UUID> = []
    @State private var editingID: UUID?
    @State private var editingDraft = ""
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showingDeleteConfirm = false
    @State private var signInCheck: SignInCheck?
    @Environment(\.undoManager) private var envUndoManager
    @Environment(\.openSettings) private var openSettings
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(manager.listedApps.filter { manager.bundleStatus(for: $0) != .available }) { app in
                bundleBanner(for: app)
                Divider()
            }

            List(selection: $selection) {
                // Built-in Default entries sit outside the reorderable
                // ForEach, so they always stay pinned at the top.
                ForEach(manager.builtInProfiles) { profile in
                    row(for: profile)
                }

                ForEach(manager.profiles) { profile in
                    row(for: profile)
                }
                .onMove(perform: moveProfiles)

                if manager.profiles.isEmpty {
                    emptyState
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: UUID.self, menu: contextMenuContent, primaryAction: openProfiles)
        }
        .frame(minWidth: 460, minHeight: 260)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ManagedApp.allCases) { app in
                        Button(app.newProfileTitle) { newProfile(app) }
                    }
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .help("New Profile (⌘N for Claude, ⌥⌘N for ChatGPT)")
            }
            ToolbarItem(placement: .status) {
                // macOS 26 wraps toolbar items in a glass capsule sized to
                // the text; inset it so the label clears the rounded ends.
                Text(manager.statusSummary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
        .task { await manager.monitorRunningProcesses() }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) { manager.clearError() }
        } message: {
            Text(manager.lastError ?? "")
        }
        .alert(deleteAlertTitle, isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive, action: performDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAlertMessage)
        }
        .alert(signInCheck?.title ?? "", isPresented: signInCheckBinding, presenting: signInCheck) { check in
            Button("Quit Others and Start") { quitOthersAndStart(check) }
            Button("Start Anyway") { manager.open(id: check.profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { check in
            Text(check.message)
        }
        .focusedSceneValue(\.profileCommands, commandContext)
        .onAppear(perform: syncCommandContext)
        .onChange(of: commandContextSignature) { _, _ in syncCommandContext() }
        .onChange(of: nameFieldFocused) { _, focused in
            // Clicking elsewhere commits an in-progress rename, like Finder.
            if !focused { commitEditing() }
        }
    }

    private func row(for profile: ClaudeProfile) -> some View {
        ProfileRowView(
            manager: manager,
            profile: profile,
            isEditing: editingID == profile.id,
            draft: $editingDraft,
            nameFieldFocused: $nameFieldFocused,
            commitEditing: commitEditing,
            cancelEditing: cancelEditing,
            requestStart: { open(profile) },
            requestRename: { beginRename(profile.id) },
            requestDelete: { requestDelete([profile.id]) }
        )
        .tag(profile.id)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Isolated Profiles", systemImage: "person.2")
        } description: {
            Text("Default Claude uses your normal login.\nAdd an isolated Claude or ChatGPT profile to run another account alongside it.")
        } actions: {
            ForEach(ManagedApp.allCases) { app in
                Button(app.newProfileTitle) { newProfile(app) }
            }
        }
    }

    /// Shown while a listed app is missing or is a build that cannot run profiles.
    private func bundleBanner(for app: ManagedApp) -> some View {
        let path = MacPlatform.homeRelativePath(of: manager.bundleURL(for: app))
        let unsupported = manager.bundleStatus(for: app) == .unsupported
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(unsupported ? "\(app.bundleName) cannot run profiles" : "\(app.bundleName) was not found")
                    .font(.headline)
                Text(unsupported
                     ? "The app at \(path) is an unsupported build, such as ChatGPT Classic. Install the current \(app.productName) app or locate it."
                     : "Expected at \(path). \(app.name) profiles cannot start until you locate it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate \(app.bundleName)…") { locateBundle(for: app) }
            Button("Settings…") { openSettings() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Menu commands

    private var selectedProfiles: [ClaudeProfile] {
        manager.listedProfiles.filter { selection.contains($0.id) }
    }

    private var commandContext: ProfileCommandContext {
        let targets = selectedProfiles
        let deletables = targets.filter { !$0.isDefault }
        let runningTargets = targets.filter { manager.isRunning(id: $0.id) }
        var context = ProfileCommandContext()
        context.selectionCount = targets.count
        context.canOpen = !targets.isEmpty
        context.canStop = !runningTargets.isEmpty
        context.canRename = editingID == nil && targets.count == 1 && !targets[0].isDefault
        context.canReveal = !targets.isEmpty
        context.canCopyPath = targets.count == 1
        context.canDelete = !deletables.isEmpty
        let launchableApps = manager.listedApps.filter { manager.bundleStatus(for: $0) == .available }
        context.canStartAll = manager.listedProfiles.contains {
            launchableApps.contains($0.app) && !manager.isRunning(id: $0.id)
        }
        context.canStopAll = manager.runningCount > 0
        context.openTitle = targets.count == 1 ? "Open “\(targets[0].label)”" : "Open \(targets.count) Profiles"
        context.stopTitle = runningTargets.count == 1 ? "Stop “\(runningTargets[0].label)”" : "Stop \(runningTargets.count) Profiles"
        context.deleteTitle = deleteTitle(for: deletables)
        context.newProfile = newProfile
        context.openSelected = { openProfiles(selection) }
        context.stopSelected = { stopProfiles(selection) }
        context.renameSelected = {
            if targets.count == 1 { beginRename(targets[0].id) }
        }
        context.deleteSelected = { requestDelete(selection) }
        context.revealSelected = { reveal(selection) }
        context.copyPathSelected = {
            if targets.count == 1 { MacPlatform.copyPathToPasteboard(targets[0].dataDirectory) }
        }
        context.startAll = manager.startAll
        context.stopAll = manager.stopAll
        context.openProfilesFolder = openProfilesFolder
        return context
    }

    /// Everything the command context depends on, so `onChange` republishes
    /// it to the shared command center on every relevant state change.
    private var commandContextSignature: String {
        let selectionPart = selection.sorted { $0.uuidString < $1.uuidString }
            .map(\.uuidString).joined()
        let profilePart = manager.profiles.map { "\($0.id.uuidString)=\($0.label)" }.joined()
        let runningPart = manager.runningProfileIDs.sorted { $0.uuidString < $1.uuidString }
            .map(\.uuidString).joined()
        let editingPart = editingID?.uuidString ?? ""
        let bundlePart = ManagedApp.allCases.map { "\(manager.bundleStatus(for: $0))" }.joined(separator: ",")
        return [selectionPart, editingPart, profilePart, runningPart, bundlePart]
            .joined(separator: "|")
    }

    private func syncCommandContext() {
        ProfileCommandCenter.shared.context = commandContext
    }

    private func deleteTitle(for deletables: [ClaudeProfile]) -> String {
        if deletables.count == 1 {
            return "Delete “\(deletables[0].label)”…"
        }
        return "Delete \(deletables.count) Profiles…"
    }

    @ViewBuilder
    private func contextMenuContent(for ids: Set<UUID>) -> some View {
        let targets = manager.listedProfiles.filter { ids.contains($0.id) }
        if targets.isEmpty {
            ForEach(ManagedApp.allCases) { app in
                Button(app.newProfileTitle) { newProfile(app) }
            }
        } else {
            if targets.count == 1 {
                Button("Open “\(targets[0].label)”") { openProfiles(ids) }
            } else {
                Button("Open \(targets.count) Profiles") { openProfiles(ids) }
            }
            if targets.contains(where: { manager.isRunning(id: $0.id) }) {
                Button("Stop") { stopProfiles(ids) }
            }
            Divider()
            if targets.count == 1, !targets[0].isDefault {
                Button("Rename…") { beginRename(targets[0].id) }
            }
            Button("Reveal in Finder") { reveal(ids) }
            if targets.count == 1 {
                Button("Copy Data Folder Path") {
                    MacPlatform.copyPathToPasteboard(targets[0].dataDirectory)
                }
            }
            let deletables = targets.filter { !$0.isDefault }
            if !deletables.isEmpty {
                Divider()
                Button(deleteTitle(for: deletables), role: .destructive) {
                    requestDelete(ids)
                }
            }
        }
    }

    // MARK: Actions

    private func newProfile(_ app: ManagedApp) {
        var created: ClaudeProfile?
        performProfileEdit("New Profile") {
            created = try manager.addUntitledProfile(for: app)
        }
        if let created {
            selection = [created.id]
            beginRename(created.id)
        }
    }

    /// "Open" acts like double-clicking a file: start a stopped instance or
    /// bring a running one to the front. Never stops a running profile, and
    /// never fires while a rename text field is active.
    private func openProfiles(_ ids: Set<UUID>) {
        guard editingID == nil else { return }
        let targets = manager.listedProfiles.filter { ids.contains($0.id) }
        if targets.count == 1 {
            open(targets[0])
            return
        }
        for profile in targets {
            manager.open(id: profile.id)
        }
    }

    /// A profile's first start is its sign-in, and the browser's callback
    /// can reach another running instance of the same app instead. Offer
    /// to quit those first.
    private func open(_ profile: ClaudeProfile) {
        let others = manager.otherRunningProfiles(sameAppAs: profile.id)
        guard !manager.isRunning(id: profile.id), manager.needsSignIn(id: profile.id), !others.isEmpty else {
            manager.open(id: profile.id)
            return
        }
        signInCheck = SignInCheck(profile: profile, others: others)
    }

    private func quitOthersAndStart(_ check: SignInCheck) {
        for other in check.others {
            manager.stop(id: other.id)
        }
        manager.open(id: check.profile.id)
    }

    private var signInCheckBinding: Binding<Bool> {
        Binding(
            get: { signInCheck != nil },
            set: { if !$0 { signInCheck = nil } }
        )
    }

    private func stopProfiles(_ ids: Set<UUID>) {
        for profile in manager.listedProfiles where ids.contains(profile.id) {
            manager.stop(id: profile.id)
        }
    }

    private func reveal(_ ids: Set<UUID>) {
        let urls = manager.listedProfiles
            .filter { ids.contains($0.id) }
            .map(\.dataDirectory)
        MacPlatform.revealInFinder(urls)
    }

    private func openProfilesFolder() {
        // The root is created lazily; make it exist so Finder has something
        // real to show.
        try? FileManager.default.createDirectory(
            at: ProfileManager.profilesRootDirectory,
            withIntermediateDirectories: true
        )
        MacPlatform.revealInFinder(ProfileManager.profilesRootDirectory)
    }

    private func locateBundle(for app: ManagedApp) {
        MacPlatform.chooseApplicationBundle(named: app.bundleName) { url in
            if let url { manager.setBundleURL(url, for: app) }
        }
    }

    // MARK: Inline rename

    private func beginRename(_ id: UUID) {
        guard let profile = manager.listedProfiles.first(where: { $0.id == id }),
              !profile.isDefault else { return }
        editingID = id
        editingDraft = profile.label
        nameFieldFocused = true
        // Select the whole name so typing replaces it, like a Finder rename.
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitEditing() {
        guard let id = editingID else { return }
        editingID = nil
        nameFieldFocused = false
        performProfileEdit("Rename Profile") {
            try manager.renameProfile(id: id, to: editingDraft)
        }
    }

    private func cancelEditing() {
        editingID = nil
        nameFieldFocused = false
    }

    // MARK: Delete

    private func requestDelete(_ ids: Set<UUID>) {
        let deletable = ids.filter { !ClaudeProfile.isBuiltIn(id: $0) }
        guard !deletable.isEmpty else { return }
        pendingDeleteIDs = deletable
        showingDeleteConfirm = true
    }

    private var pendingDeleteProfiles: [ClaudeProfile] {
        manager.listedProfiles.filter { pendingDeleteIDs.contains($0.id) }
    }

    private var deleteAlertTitle: String {
        let targets = pendingDeleteProfiles
        if targets.count == 1 {
            return "Delete “\(targets[0].label)”?"
        }
        return "Delete \(targets.count) Profiles?"
    }

    private var deleteAlertMessage: String {
        let targets = pendingDeleteProfiles
        let running = targets.filter { manager.isRunning(id: $0.id) }.count
        var parts: [String] = []
        if running == 1 {
            parts.append("It is currently running and will be quit first.")
        } else if running > 1 {
            parts.append("\(running) of them are currently running and will be quit first.")
        }
        parts.append("This only removes \(targets.count == 1 ? "it" : "them") from the list. The data directory stays on disk, so nothing is lost.")
        return parts.joined(separator: " ")
    }

    private func performDelete() {
        let ids = pendingDeleteIDs
        pendingDeleteIDs = []
        selection.subtract(ids)
        performProfileEdit(ids.count > 1 ? "Delete Profiles" : "Delete Profile") {
            for id in ids {
                try manager.removeProfile(id: id)
            }
        }
    }

    // MARK: Undo plumbing

    private func moveProfiles(from source: IndexSet, to destination: Int) {
        performProfileEdit("Reorder Profiles") {
            try manager.moveProfiles(fromOffsets: source, toOffset: destination)
        }
    }

    /// Runs a mutation and registers a snapshot restore on the window's
    /// undo manager. Undo restores the profile list; process state (running
    /// instances) is deliberately not part of it.
    private func performProfileEdit(_ actionName: String, _ mutate: () throws -> Void) {
        let before = manager.profiles
        do {
            try mutate()
        } catch {
            manager.report(error)
            return
        }
        guard manager.profiles != before else { return }
        registerRestore(before, name: actionName)
    }

    /// The window's own undo manager is the canonical place for edits: the
    /// Edit menu's Undo/Redo items route to it through the responder chain,
    /// and it lazily exists for every NSWindow. The environment value is a
    /// (possibly bridged) shortcut to the same object when populated.
    private var undoManager: UndoManager? {
        envUndoManager ?? NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager
    }

    private func registerRestore(_ target: [ClaudeProfile], name: String) {
        guard let undoManager else { return }
        Self.registerRestore(on: undoManager, manager: manager, target: target, name: name)
    }

    private static func registerRestore(
        on undoManager: UndoManager,
        manager: ProfileManager,
        target: [ClaudeProfile],
        name: String
    ) {
        let snapshotBefore = manager.profiles
        undoManager.registerUndo(withTarget: manager) { manager in
            // registerUndo handlers are nonisolated; undo is only ever
            // triggered from the menu bar or a shortcut on the main thread.
            MainActor.assumeIsolated {
                manager.restoreProfiles(target)
                // Registered while undoing, this becomes the redo action.
                registerRestore(on: undoManager, manager: manager, target: snapshotBefore, name: name)
            }
        }
        undoManager.setActionName(name)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.clearError() } }
        )
    }
}

/// A first start while other instances of the same app are running.
private struct SignInCheck {
    let profile: ClaudeProfile
    let others: [ClaudeProfile]

    var title: String {
        "Quit other \(profile.app.name) instances before signing in?"
    }

    var message: String {
        let names = others.map { "“\($0.label)”" }.joined(separator: ", ")
        return "“\(profile.label)” has not been signed in yet. Sign-in links from your browser can open in a running instance (\(names)) instead of this one. Quit Others stops them; their logins are kept."
    }
}
