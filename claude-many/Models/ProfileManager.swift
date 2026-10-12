import Foundation
import Observation

/// Core app logic: owns the profile list, persistence, and the lifecycle of
/// Claude processes. Kept free of SwiftUI so the whole thing is unit-testable
/// without launching Claude (the launcher is injected).
@Observable
@MainActor
final class ProfileManager {
    // MARK: Published state

    private(set) var profiles: [ClaudeProfile] = []
    var listedProfiles: [ClaudeProfile] { [.standard] + profiles }
    private(set) var runningProfileIDs: Set<UUID> = []
    private(set) var claudeBundleURL: URL
    private(set) var lastError: String?

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

    static let defaultBundleURL = URL(fileURLWithPath: "/Applications/Claude.app")

    /// UserDefaults key for a relocated Claude.app. Only written when the user
    /// picks a location other than the default.
    static let bundlePathDefaultsKey = "claudeBundlePath"

    var bundleExists: Bool {
        FileManager.default.fileExists(atPath: claudeBundleURL.path)
    }

    // MARK: Init

    // `defaults` stays an Optional: the compiler crashes emitting
    // `UserDefaults.standard` as a default argument inside a @State
    // property initializer on Xcode 16.4.
    init(
        store: ProfileStore? = nil,
        launcher: any ClaudeLauncher = RealClaudeLauncher(),
        claudeBundleURL: URL? = nil,
        defaults: UserDefaults? = nil,
        dataRootDirectory: URL = ProfileManager.profilesRootDirectory
    ) {
        self.store = store
            ?? ProfileStore(fileURL: Self.appSupportDirectory.appendingPathComponent("profiles.json"))
        self.launcher = launcher
        self.defaults = defaults ?? .standard
        self.dataRootDirectory = dataRootDirectory
        self.claudeBundleURL = claudeBundleURL ?? Self.storedBundleURL(in: self.defaults)
    }

    private static func storedBundleURL(in defaults: UserDefaults) -> URL {
        guard let path = defaults.string(forKey: bundlePathDefaultsKey),
              !path.isEmpty else {
            return defaultBundleURL
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

        let executable = claudeBundleURL.appendingPathComponent("Contents/MacOS/Claude")
        for handle in launcher.runningHandles(executable: executable) {
            guard handle.isRunning else { continue }
            let id: UUID
            switch handle.location {
            case .standard:
                id = ClaudeProfile.standard.id
            case .isolated(let dataDirectory):
                let directory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
                guard let profile = profiles.first(where: {
                    $0.dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path == directory
                }) else { continue }
                id = profile.id
            }
            guard handles[id] == nil else { continue }
            attach(handle: handle, to: id)
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
    func addProfile(named label: String) throws -> ClaudeProfile {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileManagerError.invalidLabel }

        let dataDirectory = try makeUniqueDataDirectory(for: trimmed)
        let profile = ClaudeProfile(label: trimmed, dataDirectory: dataDirectory)
        profiles.append(profile)
        try persist()
        return profile
    }

    /// Creates a profile with a placeholder name, like Finder's "untitled
    /// folder": the UI selects the name for immediate editing.
    @discardableResult
    func addUntitledProfile() throws -> ClaudeProfile {
        let base = "New Profile"
        let existing = Set(profiles.map(\.label))
        var label = base
        var counter = 2
        while existing.contains(label) {
            label = "\(base) \(counter)"
            counter += 1
        }
        return try addProfile(named: label)
    }

    func renameProfile(id: UUID, to newLabel: String) throws {
        guard id != ClaudeProfile.standard.id else { throw ProfileManagerError.builtInProfile }
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
        guard id != ClaudeProfile.standard.id else { throw ProfileManagerError.builtInProfile }
        stop(id: id)
        profiles.removeAll { $0.id == id }
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

        guard FileManager.default.fileExists(atPath: claudeBundleURL.path) else {
            throw ProfileManagerError.bundleMissing(path: claudeBundleURL.path)
        }

        // Create the profile's data directory lazily; Claude builds its own
        // layout (Local Storage, cookies, config, sessions) on first run.
        if let directory = profile.location.dataDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let executable = claudeBundleURL
            .appendingPathComponent("Contents/MacOS/Claude")
        let handle = try launcher.launch(
            executable: executable,
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

    /// Updates the Claude.app location and persists it. An empty path (or the
    /// default path) clears the override so the standard location is used.
    func setBundlePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultBundleURL.path {
            defaults.removeObject(forKey: Self.bundlePathDefaultsKey)
            claudeBundleURL = Self.defaultBundleURL
        } else {
            defaults.set(trimmed, forKey: Self.bundlePathDefaultsKey)
            claudeBundleURL = URL(fileURLWithPath: trimmed, isDirectory: true)
        }
    }

    func setBundleURL(_ url: URL) {
        setBundlePath(url.path)
    }

    func resetBundlePath() {
        defaults.removeObject(forKey: Self.bundlePathDefaultsKey)
        claudeBundleURL = Self.defaultBundleURL
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
        if result.isEmpty { result = "profile" }
        return result
    }
}

enum ProfileManagerError: LocalizedError, Equatable {
    case invalidLabel
    case profileNotFound
    case bundleMissing(path: String)
    case stopInProgress
    case builtInProfile

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            return "Profile name cannot be empty."
        case .profileNotFound:
            return "That profile no longer exists."
        case .bundleMissing(let path):
            return "Claude.app was not found at \(path). Install Claude Desktop or fix the path in Settings."
        case .stopInProgress:
            return "This profile's previous instance is still shutting down; try again in a moment."
        case .builtInProfile:
            return "Default Claude is built in and cannot be renamed or removed."
        }
    }
}
