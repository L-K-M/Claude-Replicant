import Foundation
import Observation

/// Core app logic: owns the profile list, persistence, and the lifecycle of
/// Claude and ChatGPT processes. Kept free of SwiftUI so the whole thing is
/// unit-testable without launching either app (the launcher is injected).
@Observable
@MainActor
final class ProfileManager {
    // MARK: Published state

    private(set) var profiles: [ClaudeProfile] = []
    private(set) var runningProfileIDs: Set<UUID> = []
    private(set) var lastError: String?
    private var bundleURLs: [ManagedApp: URL]

    /// Claude is always listed; ChatGPT once it has a profile.
    var listedApps: [ManagedApp] {
        ManagedApp.allCases.filter { app in
            app.listsDefaultWithoutProfiles || profiles.contains { $0.app == app }
        }
    }

    /// Pinned "Default <app>" entries, above the reorderable profiles.
    var builtInProfiles: [ClaudeProfile] { listedApps.map(ClaudeProfile.builtIn(for:)) }
    var listedProfiles: [ClaudeProfile] { builtInProfiles + profiles }

    var runningCount: Int { runningProfileIDs.count }

    /// One-line summary for the window's status area.
    var statusSummary: String {
        runningCount == 0
            ? "No instances running"
            : "\(runningCount) of \(listedProfiles.count) running"
    }

    // MARK: Dependencies

    let store: ProfileStore
    /// Root under which each profile's private data directory is created
    /// (`<dataRootDirectory>/<slug>`). Defaults to the app's own
    /// `Profiles` folder; injectable so tests can use scratch roots.
    let dataRootDirectory: URL
    private let launcher: any ClaudeLauncher
    private let defaults: UserDefaults
    private var handles: [UUID: ClaudeProcessHandle] = [:]
    /// Pending force-kill timers, one per stopped profile.
    private var forceKillTasks: [UUID: Task<Void, Never>] = [:]
    private static let reconciliationInterval: Duration = .seconds(2)
    private var monitorOwner: UUID?

    // MARK: Well-known paths

    /// `~/Library/Application Support/Claude-Many` – everything claude-many
    /// owns lives under here (profile list + per-profile data dirs).
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("Claude-Many", isDirectory: true)
    }()

    static let profilesRootDirectory: URL =
        appSupportDirectory.appendingPathComponent("Profiles", isDirectory: true)

    func bundleURL(for app: ManagedApp) -> URL {
        bundleURLs[app] ?? app.defaultBundleURL
    }

    func bundleStatus(for app: ManagedApp) -> AppBundleStatus {
        app.bundleStatus(at: bundleURL(for: app))
    }

    // MARK: Init

    // `defaults` stays an Optional: the compiler crashes emitting
    // `UserDefaults.standard` as a default argument inside a @State
    // property initializer on Xcode 16.4.
    init(
        store: ProfileStore? = nil,
        launcher: any ClaudeLauncher = RealClaudeLauncher(),
        claudeBundleURL: URL? = nil,
        chatGPTBundleURL: URL? = nil,
        defaults: UserDefaults? = nil,
        dataRootDirectory: URL = ProfileManager.profilesRootDirectory
    ) {
        self.store = store
            ?? ProfileStore(fileURL: Self.appSupportDirectory.appendingPathComponent("profiles.json"))
        self.launcher = launcher
        self.defaults = defaults ?? .standard
        self.dataRootDirectory = dataRootDirectory

        var bundleURLs: [ManagedApp: URL] = [:]
        for app in ManagedApp.allCases {
            bundleURLs[app] = Self.storedBundleURL(for: app, in: self.defaults)
        }
        // Tests inject scratch bundles; the app uses stored or default locations.
        if let claudeBundleURL { bundleURLs[.claude] = claudeBundleURL }
        if let chatGPTBundleURL { bundleURLs[.chatGPT] = chatGPTBundleURL }
        self.bundleURLs = bundleURLs
    }

    /// Only written when the user picks a location other than the default.
    private static func storedBundleURL(for app: ManagedApp, in defaults: UserDefaults) -> URL {
        guard let path = defaults.string(forKey: app.bundlePathDefaultsKey),
              !path.isEmpty else {
            return app.defaultBundleURL
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Load / persist

    func load() {
        do {
            profiles = try store.load()
        } catch {
            lastError = "Could not load profiles: \(error.localizedDescription)"
            return
        }
        refreshRunningProcesses()
    }

    /// Reconcile external starts as well as instances left over from an app relaunch.
    func refreshRunningProcesses() {
        for (id, handle) in handles where !handle.isRunning {
            handleTermination(of: id, handle: handle)
        }
        releaseUnlistedBuiltIns()

        // Classic at the configured path cannot be started, so never manage
        // its normal instance either.
        for app in listedApps where bundleStatus(for: app) != .unsupported {
            let executable = bundleURL(for: app).appendingPathComponent(app.executablePath)
            for handle in launcher.runningHandles(app: app, executable: executable) {
                guard handle.isRunning,
                      let id = profileID(owning: handle.location, app: app),
                      handles[id] == nil else { continue }
                attach(handle: handle, to: id)
            }
        }
    }

    /// The listed entry whose storage a discovered instance uses, if any.
    private func profileID(owning location: ClaudeInstanceLocation, app: ManagedApp) -> UUID? {
        guard let dataDirectory = location.dataDirectory else { return ClaudeProfile.builtIn(for: app).id }

        let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return profiles.first {
            $0.app == app && $0.dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path == directory
        }?.id
    }

    /// Deleting the last ChatGPT profile unlists Default ChatGPT. Stop
    /// tracking that normal instance without quitting it.
    private func releaseUnlistedBuiltIns() {
        let listed = Set(listedProfiles.map(\.id))
        for (id, handle) in handles where ClaudeProfile.isBuiltIn(id: id) && !listed.contains(id) {
            // A pending Stop keeps its handle until the process exits.
            guard forceKillTasks[id] == nil else { continue }
            handle.terminationHandler = nil
            handles[id] = nil
            runningProfileIDs.remove(id)
        }
    }

    /// Views own their task lifetimes; only one scans, and another takes over after cancellation.
    func monitorRunningProcesses() async {
        let owner = UUID()
        defer {
            if monitorOwner == owner { monitorOwner = nil }
        }

        while !Task.isCancelled {
            if monitorOwner == nil || monitorOwner == owner {
                monitorOwner = owner
                refreshRunningProcesses()
            }
            do {
                try await Task.sleep(for: Self.reconciliationInterval)
            } catch {
                return
            }
        }
    }

    private func persist() throws {
        try store.save(profiles)
    }

    // MARK: Profile CRUD

    @discardableResult
    func addProfile(named label: String, app: ManagedApp = .claude) throws -> ClaudeProfile {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileManagerError.invalidLabel }

        let dataDirectory = try makeUniqueDataDirectory(for: trimmed)
        let profile = ClaudeProfile(label: trimmed, app: app, dataDirectory: dataDirectory)
        profiles.append(profile)
        try persist()
        return profile
    }

    /// Creates a profile with a placeholder name, like Finder's "untitled
    /// folder": the UI selects the name for immediate editing.
    @discardableResult
    func addUntitledProfile(for app: ManagedApp) throws -> ClaudeProfile {
        let base = app.newProfileTitle
        let existing = Set(profiles.map(\.label))
        var label = base
        var counter = 2
        while existing.contains(label) {
            label = "\(base) \(counter)"
            counter += 1
        }
        return try addProfile(named: label, app: app)
    }

    func renameProfile(id: UUID, to newLabel: String) throws {
        guard !ClaudeProfile.isBuiltIn(id: id) else { throw ProfileManagerError.builtInProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileManagerError.invalidLabel }
        profiles[index].label = trimmed
        try persist()
    }

    /// Removes the profile from the list (stopping it first if running).
    /// Its data directory is deliberately left on disk: it holds the account's
    /// login and conversations, and deletion is destructive.
    func removeProfile(id: UUID) throws {
        guard !ClaudeProfile.isBuiltIn(id: id) else { throw ProfileManagerError.builtInProfile }
        stop(id: id)
        profiles.removeAll { $0.id == id }
        releaseUnlistedBuiltIns()
        try persist()
    }

    /// Drag-to-reorder within the user-managed profiles (the built-in Default
    /// entry is not part of `profiles` and always stays first).
    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        profiles.move(fromOffsets: source, toOffset: destination)
        try persist()
    }

    /// Replaces the profile list wholesale. Used by Undo to restore a snapshot
    /// taken before a mutation. Persistence failure is reported, not thrown:
    /// undo handlers must not fail.
    func restoreProfiles(_ snapshot: [ClaudeProfile]) {
        let snapshotIDs = Set(snapshot.map(\.id))
        for id in profiles.map(\.id) where !snapshotIDs.contains(id) {
            stop(id: id)
        }
        profiles = snapshot
        releaseUnlistedBuiltIns()
        do {
            try persist()
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    // MARK: Start / stop

    func isRunning(id: UUID) -> Bool {
        runningProfileIDs.contains(id)
    }

    /// Launch only after a fresh scan, so an externally opened default instance is not duplicated.
    func start(id: UUID) throws {
        guard let profile = listedProfiles.first(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        refreshRunningProcesses()
        guard !isRunning(id: id) else { return }

        // stop() reports the profile as stopped immediately, but the previous
        // process can stay alive for up to the force-kill grace period.
        // Launching now would put a second instance into a data directory the
        // old process still owns.
        if let previous = handles[id], previous.isRunning {
            throw ProfileManagerError.stopInProgress
        }

        let bundle = bundleURL(for: profile.app)
        switch profile.app.bundleStatus(at: bundle) {
        case .available:
            break
        case .missing:
            throw ProfileManagerError.bundleMissing(app: profile.app, path: bundle.path)
        case .unsupported:
            throw ProfileManagerError.unsupportedBundle(app: profile.app, path: bundle.path)
        }

        // Create the profile's data directory lazily; the app builds its own
        // layout (Local Storage, cookies, config, sessions) on first run.
        if let directory = profile.location.dataDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let handle = try launcher.launch(
            app: profile.app,
            executable: bundle.appendingPathComponent(profile.app.executablePath),
            location: profile.location
        )
        attach(handle: handle, to: id)
        lastError = nil
    }

    /// Registers a live handle as the running instance for a profile and
    /// observes its termination. The `isRunning` re-check after assigning the
    /// handler covers a process that exited before the handler could be set
    /// (Foundation never invokes a termination handler attached to a process
    /// that already exited).
    private func attach(handle: ClaudeProcessHandle, to id: UUID) {
        handles[id] = handle
        runningProfileIDs.insert(id)

        handle.terminationHandler = { [weak self, weak handle] in
            // Process calls the handler on an arbitrary queue; hop to the
            // main actor before touching any state. Weak captures keep the
            // handle's closure from retaining the handle itself.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let handle else { return }
                    self?.handleTermination(of: id, handle: handle)
                }
            }
        }
        if !handle.isRunning {
            handleTermination(of: id, handle: handle)
        }
    }

    /// "Open" a profile like a document: starts it when stopped, or brings the
    /// existing instance's windows to the front when already running.
    func open(id: UUID) {
        if isRunning(id: id), let handle = handles[id] {
            launcher.activate(handle: handle)
            return
        }
        do {
            try start(id: id)
        } catch {
            report(error)
        }
    }

    /// Asks the instance to quit cleanly (SIGTERM), then force-kills it if it
    /// has not exited within a few seconds. The UI reflects "stopped"
    /// immediately; internal bookkeeping is cleaned up when the process exits.
    func stop(id: UUID) {
        guard isRunning(id: id), let handle = handles[id] else { return }
        runningProfileIDs.remove(id)
        forceKillTasks[id]?.cancel()
        handle.terminate()

        let task = Task { [weak handle] in
            try? await Task.sleep(for: .seconds(5))
            guard let handle, handle.isRunning else { return }
            handle.terminateForcefully()
        }
        forceKillTasks[id] = task
    }

    func stopAll() {
        for id in Array(runningProfileIDs) {
            stop(id: id)
        }
    }

    /// Starts every listed profile that is not already running. Failures on
    /// one profile do not prevent the rest from starting; the last error is
    /// surfaced to the user.
    func startAll() {
        for profile in listedProfiles where !isRunning(id: profile.id) {
            do {
                try start(id: profile.id)
            } catch {
                report(error)
            }
        }
    }

    private func handleTermination(of id: UUID, handle: ClaudeProcessHandle) {
        // Only clean up if this is still the tracked handle for the profile:
        // a stale handle from an earlier stop could otherwise wipe out the
        // bookkeeping of a freshly restarted instance.
        guard handles[id] === handle else { return }
        handles[id] = nil
        runningProfileIDs.remove(id)
        forceKillTasks[id]?.cancel()
        forceKillTasks[id] = nil
    }

    // MARK: Settings

    /// Updates an app's location and persists it. An empty path (or the
    /// default path) clears the override so the standard location is used.
    func setBundlePath(_ path: String, for app: ManagedApp) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != app.defaultBundleURL.path else {
            resetBundlePath(for: app)
            return
        }
        defaults.set(trimmed, forKey: app.bundlePathDefaultsKey)
        bundleURLs[app] = URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    func setBundleURL(_ url: URL, for app: ManagedApp) {
        setBundlePath(url.path, for: app)
    }

    func resetBundlePath(for app: ManagedApp) {
        defaults.removeObject(forKey: app.bundlePathDefaultsKey)
        bundleURLs[app] = app.defaultBundleURL
    }

    func report(_ error: any Error) {
        lastError = error.localizedDescription
    }

    func clearError() {
        lastError = nil
    }

    // MARK: Helpers

    /// Builds a unique, filesystem-friendly directory name for a new profile.
    private func makeUniqueDataDirectory(for label: String) throws -> URL {
        let base = Self.slug(for: label)
        var candidate = base
        var counter = 2

        let occupied = Set(profiles.map { $0.dataDirectory.path })
        while FileManager.default.fileExists(atPath: dataRootDirectory
            .appendingPathComponent(candidate).path)
            || occupied.contains(dataRootDirectory
                .appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return dataRootDirectory.appendingPathComponent(candidate, isDirectory: true)
    }

    /// Folder names stay below the 255-byte file name limit even when the
    /// file system stores them decomposed (at most about three times
    /// longer) and a "-N" suffix is added.
    static let maximumSlugLength = 64

    /// "My Work (2)" -> "my-work-2". Lowercase, non-alphanumerics become
    /// single dashes, trimmed.
    static func slug(for label: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in label.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !result.isEmpty {
                    result.append("-")
                }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        // After the cut: one character can be longer than the whole limit.
        let slug = truncated(result, toUTF8Length: maximumSlugLength)
        return slug.isEmpty ? "profile" : slug
    }

    /// Cuts whole characters, then any dash left dangling at the end.
    private static func truncated(_ slug: String, toUTF8Length limit: Int) -> String {
        var result = ""
        for character in slug {
            guard result.utf8.count + character.utf8.count <= limit else { break }
            result.append(character)
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}

enum ProfileManagerError: LocalizedError, Equatable {
    case invalidLabel
    case profileNotFound
    case bundleMissing(app: ManagedApp, path: String)
    case unsupportedBundle(app: ManagedApp, path: String)
    case stopInProgress
    case builtInProfile

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "Profile name cannot be empty."
        case .profileNotFound:
            return "That profile no longer exists."
        case .bundleMissing(let app, let path):
            return "\(app.bundleName) was not found at \(path). Install \(app.productName) or fix the path in Settings."
        case .unsupportedBundle(let app, let path):
            return "The app at \(path) cannot run separate \(app.name) profiles. ChatGPT Classic is not supported; install the current \(app.productName) app or fix the path in Settings."
        case .stopInProgress:
            return "This profile's previous instance is still shutting down; try again in a moment."
        case .builtInProfile:
            return "Default entries are built in and cannot be renamed or removed."
        }
    }
}
