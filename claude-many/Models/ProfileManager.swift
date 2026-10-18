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
    /// Why profiles.json could not be opened at all (as opposed to decoded),
    /// or could not be kept safely before rewriting. Saving would replace
    /// it, so changes are refused until a later load succeeds.
    @ObservationIgnored private var unopenedProfileList: String?

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
    private let trash: FileTrash
    /// Unused folders under `dataRootDirectory`, as of the last change to
    /// the list; see `unlistedData`.
    private var scannedUnlistedData: [UnlistedProfileData] = []
    /// The last scan left out folders untracked instances run in; scans
    /// repeat with discovery until they are free.
    @ObservationIgnored private var unlistedDataHeldByInstances = false
    /// Folders the list on disk names, as comparable paths. Never offered as
    /// unlisted, even when a failed save left `profiles` without them. Nil
    /// while the file names folders that could not be decoded: then no
    /// folder is offered until a save succeeds.
    @ObservationIgnored private var savedDataDirectories: Set<String>? = []
    private var handles: [UUID: ClaudeProcessHandle] = [:]
    /// Pending force-kill timers, one per stopped profile.
    private var forceKillTasks: [UUID: Task<Void, Never>] = [:]
    /// Every data folder loaded or handed out this session. Undo can bring
    /// back any of them, so a folder name a profile gave up (or a deleted
    /// profile left behind) is never given to another profile.
    @ObservationIgnored private var claimedDataDirectories: Set<String> = []
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
        dataRootDirectory: URL = ProfileManager.profilesRootDirectory,
        trash: FileTrash = .system
    ) {
        self.store = store
            ?? ProfileStore(fileURL: Self.appSupportDirectory.appendingPathComponent("profiles.json"))
        self.launcher = launcher
        self.defaults = defaults ?? .standard
        self.dataRootDirectory = dataRootDirectory
        self.trash = trash

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
        defer {
            refreshRunningProcesses()
            rescanUnlistedData()
        }

        let contents: ProfileStore.Contents
        savedDataDirectories = []
        do {
            contents = try store.loadReadable()
            unopenedProfileList = nil
        } catch is DecodingError {
            profiles = []
            unopenedProfileList = nil
            setAsideUnreadableList(.move, problem: "Your profile list could not be read.")
            return
        } catch CocoaError.fileReadNoSuchFile {
            // Removed between the existence check and the read: nothing to protect.
            profiles = []
            unopenedProfileList = nil
            return
        } catch {
            profiles = []
            unopenedProfileList = error.localizedDescription
            lastError = ProfileManagerError.profileListUnavailable(reason: error.localizedDescription).localizedDescription
            return
        }

        profiles = contents.profiles
        savedDataDirectories = Self.comparablePaths(of: profiles)
        claimedDataDirectories.formUnion(profiles.map(\.dataDirectory.path))
        // Repairs persist, so they run only once any unreadable list is safely set aside.
        guard contents.unreadableCount > 0 else {
            repairOverlongDataDirectories()
            return
        }

        let count = contents.unreadableCount
        let problem = count == 1
            ? "1 profile could not be read and was left out."
            : "\(count) profiles could not be read and were left out."
        guard setAsideUnreadableList(.copy, problem: problem) else { return }

        // Start the new file with everything that was readable.
        do {
            try persist()
        } catch {
            // The old file stays, naming folders of entries that could not
            // be decoded. (Needs the save, not the copy, to fail: untested.)
            savedDataDirectories = nil
            lastError = [lastError, "Saving the readable profiles failed: \(error.localizedDescription)"]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        repairOverlongDataDirectories()
    }

    /// The next save would replace a list that still holds unreadable
    /// entries, so move it aside first and say where it went. Returns
    /// whether the list may be written now: its original is kept, or gone.
    @discardableResult
    private func setAsideUnreadableList(_ method: ProfileStore.SetAside, problem: String) -> Bool {
        do {
            let copy = try store.setAsideUnreadableFile(method)
            lastError = "\(problem) The original was kept at \(copy.path). Profile data folders were not changed."
            return true
        } catch where !FileManager.default.fileExists(atPath: store.fileURL.path) {
            // Removed since it was read (say, by a sync tool): no save can
            // overwrite it any more, so there is nothing left to protect.
            lastError = "\(problem) The file was removed before it could be kept. Profile data folders were not changed."
            return true
        } catch {
            unopenedProfileList = error.localizedDescription
            lastError = "\(problem) It could not be set aside (\(error.localizedDescription)), so changes are not saved until it can be."
            return false
        }
    }

    /// Profiles saved before folder names were capped can hold a name the
    /// file system refuses. Such a folder can never have been created, so
    /// give the profile a fresh, capped one. Names merely longer than the
    /// cap ("…-2" after a capped base) are valid and stay.
    private func repairOverlongDataDirectories() {
        var repaired = false
        for index in profiles.indices {
            let directory = profiles[index].dataDirectory
            let storedLength = directory.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count
            guard storedLength > Self.maximumFileNameLength,
                  directory.deletingLastPathComponent().standardizedFileURL.path == dataRootDirectory.standardizedFileURL.path,
                  !FileManager.default.fileExists(atPath: directory.path) else { continue }
            let replacement = claimUniqueDataDirectory(for: profiles[index].label)
            profiles[index] = profiles[index].withDataDirectory(replacement)
            repaired = true
        }
        guard repaired else { return }
        do {
            try persist()
        } catch {
            report(error)
        }
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
        if unlistedDataHeldByInstances { rescanUnlistedData() }
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
        if let unopenedProfileList {
            throw ProfileManagerError.profileListUnavailable(reason: unopenedProfileList)
        }
        try save(profiles)
    }

    /// Writes `list` and remembers which folders the file now names.
    private func save(_ list: [ClaudeProfile]) throws {
        try store.save(list)
        savedDataDirectories = Self.comparablePaths(of: list)
    }

    /// Changes are refused while the list on disk could not be opened or
    /// kept safely, before anything (a row, a running instance) is touched.
    /// The next `load()` (reopening the window or the app) tries again; a
    /// reload in the middle of a change would leave undo with a stale list.
    private func ensureProfileListWritable() throws {
        if let unopenedProfileList {
            throw ProfileManagerError.profileListUnavailable(reason: unopenedProfileList)
        }
    }

    // MARK: Profile CRUD

    @discardableResult
    func addProfile(named label: String, app: ManagedApp = .claude) throws -> ClaudeProfile {
        try ensureProfileListWritable()
        guard let trimmed = ClaudeProfile.normalizedLabel(label) else { throw ProfileManagerError.invalidLabel }

        let dataDirectory = claimUniqueDataDirectory(for: trimmed)
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
        try ensureProfileListWritable()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        guard let trimmed = ClaudeProfile.normalizedLabel(newLabel) else { throw ProfileManagerError.invalidLabel }
        profiles[index].label = trimmed
        renameUnusedDataDirectory(at: index)
        try persist()
    }

    /// New profiles start as "New Claude Profile", and their folder is only
    /// created on first Start. Until then the folder follows the name, so
    /// "Work" lives in `Profiles/work`, not `Profiles/new-claude-profile`.
    /// A folder that exists is never moved.
    private func renameUnusedDataDirectory(at index: Int) {
        let profile = profiles[index]
        guard handles[profile.id] == nil,
              let current = profile.location.dataDirectory,
              current.deletingLastPathComponent().standardizedFileURL.path == dataRootDirectory.standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: current.path) else { return }

        // "work-2" already fits "Work" when "work" was taken.
        let base = Self.slug(for: profile.label)
        let name = current.lastPathComponent
        guard name != base, !(name.hasPrefix(base + "-") && Int(name.dropFirst(base.count + 1)) != nil) else { return }
        profiles[index] = profile.withDataDirectory(claimUniqueDataDirectory(for: profile.label))
    }

    /// Removes the profile from the list (stopping it first if running).
    /// Its data directory is deliberately left on disk: it holds the account's
    /// login and conversations, and deletion is destructive.
    func removeProfile(id: UUID) throws {
        guard !ClaudeProfile.isBuiltIn(id: id) else { throw ProfileManagerError.builtInProfile }
        try ensureProfileListWritable()
        stop(id: id)
        profiles.removeAll { $0.id == id }
        releaseUnlistedBuiltIns()
        try persist()
        rescanUnlistedData()
    }

    /// Drag-to-reorder within the user-managed profiles (the built-in Default
    /// entry is not part of `profiles` and always stays first).
    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try ensureProfileListWritable()
        // Drag offsets always fit; anything else changes nothing.
        guard source.allSatisfy(profiles.indices.contains), (0...profiles.count).contains(destination) else { return }
        profiles.move(fromOffsets: source, toOffset: destination)
        try persist()
    }

    /// Replaces the profile list wholesale. Used by Undo to restore a snapshot
    /// taken before a mutation. Persistence failure is reported, not thrown:
    /// undo handlers must not fail. Returns false when the list could not be
    /// changed at all, so the caller registers no redo for it.
    @discardableResult
    func restoreProfiles(_ snapshot: [ClaudeProfile]) -> Bool {
        do {
            try ensureProfileListWritable()
        } catch {
            report(error)
            return false
        }
        let snapshotIDs = Set(snapshot.map(\.id))
        for id in profiles.map(\.id) where !snapshotIDs.contains(id) {
            stop(id: id)
        }
        profiles = snapshot.map(keepingDataDirectoryInUse)
        // Every name is claimed when handed out; restored ones stay claimed
        // even if that changes.
        claimedDataDirectories.formUnion(profiles.map(\.dataDirectory.path))
        releaseUnlistedBuiltIns()
        do {
            try persist()
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
        rescanUnlistedData()
        return true
    }

    /// Undoing a rename restores the old folder name, but if the profile
    /// was started since, its data now lives in the new folder. A folder
    /// that exists, or that a tracked instance uses, is never abandoned.
    /// A profile only leaves a folder that does not exist, so an old folder
    /// that exists now belongs to someone else and is never restored.
    private func keepingDataDirectoryInUse(_ restored: ClaudeProfile) -> ClaudeProfile {
        let fileManager = FileManager.default
        guard let restoredDirectory = restored.location.dataDirectory,
              let currentDirectory = profiles.first(where: { $0.id == restored.id })?.location.dataDirectory,
              currentDirectory != restoredDirectory,
              handles[restored.id] != nil
                || fileManager.fileExists(atPath: currentDirectory.path)
                || fileManager.fileExists(atPath: restoredDirectory.path)
        else { return restored }
        return restored.withDataDirectory(currentDirectory)
    }

    // MARK: Unlisted data

    /// Folders under the profiles root that no listed profile uses, newest
    /// first. A folder an instance still runs in (a deleted profile still
    /// quitting) is left out until it exits.
    var unlistedData: [UnlistedProfileData] {
        let inUse = Set(handles.values.compactMap(\.dataDirectory).map(Self.comparablePath))
        return scannedUnlistedData.filter { !inUse.contains(Self.comparablePath($0.directory)) }
    }

    /// Lists an unlisted folder again as a profile that uses it as is, so
    /// that account's sign-in and history come back.
    @discardableResult
    func restoreUnlistedData(at directory: URL) throws -> ClaudeProfile {
        try ensureProfileListWritable()
        guard !instanceRuns(in: directory) else {
            throw ProfileManagerError.dataInUse(name: directory.lastPathComponent)
        }
        let data = try currentUnlistedData(at: directory)
        let profile = ClaudeProfile(label: data.suggestedLabel, app: data.app, dataDirectory: data.directory)
        // Saved first: a failed save must leave the folder listed as unused.
        try save(profiles + [profile])
        profiles.append(profile)
        rescanUnlistedData()
        return profile
    }

    /// Moves an unlisted folder to the Trash and returns where it went, for
    /// Undo. Refused while any instance runs in it, listed or not.
    func trashUnlistedData(at directory: URL) throws -> URL {
        try ensureProfileListWritable()
        guard !instanceRuns(in: directory) else {
            throw ProfileManagerError.dataInUse(name: directory.lastPathComponent)
        }
        let data = try currentUnlistedData(at: directory)
        defer { rescanUnlistedData() }
        return try trash.moveToTrash(data.directory)
    }

    /// Moves a folder `trashUnlistedData(at:)` trashed back, for Undo.
    func putBackTrashedData(from trashed: URL, to original: URL) throws {
        defer { rescanUnlistedData() }
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    /// The listed entry for `directory`. An exact match wins, so on a
    /// case-sensitive volume `work` never stands in for `WORK`.
    private func currentUnlistedData(at directory: URL) throws -> UnlistedProfileData {
        rescanUnlistedData()
        let candidates = unlistedData
        let exactPath = directory.standardizedFileURL.path
        let path = Self.comparablePath(directory)
        guard let data = candidates.first(where: { $0.directory.standardizedFileURL.path == exactPath })
                ?? candidates.first(where: { Self.comparablePath($0.directory) == path }) else {
            throw ProfileManagerError.unlistedDataUnavailable
        }
        return data
    }

    private func instanceRuns(in directory: URL) -> Bool {
        instanceDataDirectories().contains(Self.comparablePath(directory))
    }

    /// Where any instance of either app runs, tracked or not, as comparable
    /// paths.
    private func instanceDataDirectories() -> Set<String> {
        var directories: Set<String> = []
        for app in ManagedApp.allCases {
            let executable = bundleURL(for: app).appendingPathComponent(app.executablePath)
            for handle in launcher.runningHandles(app: app, executable: executable) {
                if let directory = handle.dataDirectory { directories.insert(Self.comparablePath(directory)) }
            }
        }
        return directories
    }

    /// Lists the root's visible subfolders that no profile uses and no
    /// running instance holds (one a deleted profile left running before
    /// a relaunch is never adopted). Nothing while the list cannot be
    /// opened: which folders it names is unknown. Never creates the root.
    private func rescanUnlistedData() {
        unlistedDataHeldByInstances = false
        guard unopenedProfileList == nil else {
            scannedUnlistedData = []
            return
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dataRootDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            scannedUnlistedData = []
            return
        }

        // Tracked instances are left to `unlistedData`, so a deleted
        // profile's folder shows up as soon as its instance exits.
        guard let savedDataDirectories else {
            scannedUnlistedData = []
            return
        }
        var used = Self.comparablePaths(of: profiles).union(savedDataDirectories)
        var heldByInstances: Set<String> = []
        if !entries.isEmpty {
            let tracked = Set(handles.values.compactMap(\.dataDirectory).map(Self.comparablePath))
            heldByInstances = instanceDataDirectories().subtracting(tracked).subtracting(used)
            used.formUnion(heldByInstances)
        }
        scannedUnlistedData = entries.compactMap { folder -> UnlistedProfileData? in
            guard let values = try? folder.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !used.contains(Self.comparablePath(folder)) else { return nil }
            return UnlistedProfileData(directory: folder, app: Self.app(usingDataIn: folder),
                                       modified: values.contentModificationDate)
        }
        .sorted { first, second in
            // Newest first; the name keeps equal dates from trading places.
            let firstModified = first.modified ?? .distantPast
            let secondModified = second.modified ?? .distantPast
            guard firstModified == secondModified else { return firstModified > secondModified }
            return first.directory.lastPathComponent < second.directory.lastPathComponent
        }
        unlistedDataHeldByInstances = entries.contains { heldByInstances.contains(Self.comparablePath($0)) }
    }

    /// ChatGPT profiles get a `.codex` folder on first start, Claude ones
    /// `.claude`; a folder with neither is taken for Claude.
    private static func app(usingDataIn folder: URL) -> ManagedApp {
        let chatGPTConfiguration = ClaudeLaunchConfiguration(app: .chatGPT, dataDirectory: folder).codeConfigurationDirectory
        guard let chatGPTConfiguration,
              FileManager.default.fileExists(atPath: chatGPTConfiguration.path) else { return .claude }
        return .chatGPT
    }

    private static func comparablePaths(of profiles: [ClaudeProfile]) -> Set<String> {
        Set(profiles.map { comparablePath($0.dataDirectory) })
    }

    /// Paths compared so that one folder never counts as two: symlinks
    /// resolved, Unicode normalized, and case folded, as on the default
    /// case-insensitive volume. A folder that only differs in case is
    /// treated as in use, which can hide one but never offers a used one.
    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
            .lowercased()
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

    /// A folder name for `label` that no profile has used this session and
    /// that does not exist on disk, e.g. "work" or "work-2".
    private func claimUniqueDataDirectory(for label: String) -> URL {
        let occupied = claimedDataDirectories.union(profiles.map(\.dataDirectory.path))
        let base = Self.slug(for: label)
        var candidate = base
        var counter = 2

        while FileManager.default.fileExists(atPath: dataRootDirectory
            .appendingPathComponent(candidate).path)
            || occupied.contains(dataRootDirectory
                .appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        let directory = dataRootDirectory.appendingPathComponent(candidate, isDirectory: true)
        claimedDataDirectories.insert(directory.path)
        return directory
    }

    /// Folder names stay below the 255-byte file name limit even when the
    /// file system stores them decomposed (at most about three times
    /// longer) and a "-N" suffix is added.
    static let maximumSlugLength = 64
    /// NAME_MAX on APFS and HFS+, in bytes of the stored (decomposed) name.
    private static let maximumFileNameLength = 255

    /// "My Work (2)" -> "my-work-2". Lowercase, non-alphanumerics become
    /// single dashes, trimmed.
    static func slug(for label: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in label.lowercased().unicodeScalars {
            // A mark that opens a word has no letter of its own and would
            // fuse with the dash before it ("-\u{301}" is one character).
            if Self.isCombiningMark(scalar) && (pendingDash || result.isEmpty) {
                continue
            }
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

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Cuts whole characters, then any dash left dangling at the end.
    private static func truncated(_ slug: String, toUTF8Length limit: Int) -> String {
        var result = ""
        for character in slug {
            guard result.utf8.count + character.utf8.count <= limit else { break }
            result.append(character)
        }
        // By character: a dash fused with a mark after it ("-\u{FF9E}") is
        // still a dangling dash.
        while result.last?.unicodeScalars.first == "-" { result.removeLast() }
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
    case profileListUnavailable(reason: String)
    case unlistedDataUnavailable
    case dataInUse(name: String)

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
        case .profileListUnavailable(let reason):
            return "Your profile list was left as it is (\(reason)). Changes are not saved; fix the file, then quit and reopen Claude Replicant."
        case .unlistedDataUnavailable:
            return "That folder is no longer unlisted: a profile uses it, or it was moved."
        case .dataInUse(let name):
            return "“\(name)” is in use by a running instance. Quit that instance first."
        }
    }
}
