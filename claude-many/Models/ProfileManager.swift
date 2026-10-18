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
    /// Stopped by us, but the old process has not exited yet.
    private var stoppingProfileIDs: Set<UUID> = []
    /// Entries to start as soon as their stopping instance exits.
    private var startsAfterExit: Set<UUID> = []
    private(set) var lastError: String?
    /// Each app's installed version, read with every scan.
    private(set) var installedVersions: [ManagedApp: String] = [:]
    /// The version each tracked instance runs, as far as known: the
    /// installed version when it was started or first seen.
    private var instanceVersions: [UUID: String] = [:]
    /// The version whose restart notice the user postponed, per app.
    private var postponedRestartVersions: [ManagedApp: String] = [:]
    /// Isolated entries that quit on their own, with the version the last
    /// scan before the quit found installed, until an update shows up or
    /// `updateRelaunchWindow` passes.
    @ObservationIgnored private var recentExits: [UUID: (installed: String?, date: Date)] = [:]
    private var closedForUpdateIDs: [UUID] = []
    private var bundleURLs: [ManagedApp: URL]
    /// Why profiles.json could not be opened at all (as opposed to decoded),
    /// or could not be kept safely before rewriting. Saving would replace
    /// it, so changes are refused until a later load succeeds.
    @ObservationIgnored private var unopenedProfileList: String?

    /// Bundle checks as of the last refresh, for views: rendering must not
    /// read Info.plist from disk. `bundleStatus(for:)` checks now.
    private var knownBundleStatuses: [ManagedApp: AppBundleStatus] = [:]

    /// Entries to open when Claude Replicant starts. Default entries can be
    /// marked too, so the set lives in defaults rather than profiles.json.
    private var launchProfileIDs: Set<UUID>
    @ObservationIgnored private var didOpenLaunchProfiles = false
    private static let launchProfilesDefaultsKey = "opensAtLaunchProfileIDs"

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
    /// Escalates each stop until its process exits; see `StopTimeline`.
    private var stopSupervisors: [UUID: Task<Void, Never>] = [:]
    private let stopTimeline: StopTimeline
    /// Every data folder loaded or handed out this session. Undo can bring
    /// back any of them, so a folder name a profile gave up (or a deleted
    /// profile left behind) is never given to another profile.
    @ObservationIgnored private var claimedDataDirectories: Set<String> = []
    private static let reconciliationInterval: Duration = .seconds(2)
    /// How long after an instance quits an update can still explain it:
    /// the updater replaces the bundle once the app has quit.
    private static let updateRelaunchWindow: TimeInterval = 120
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

    func lastKnownBundleStatus(for app: ManagedApp) -> AppBundleStatus {
        knownBundleStatuses[app] ?? bundleStatus(for: app)
    }

    /// Writes only on change: every write invalidates the views that read it.
    private func recordBundleStatus(_ status: AppBundleStatus, for app: ManagedApp) {
        guard knownBundleStatuses[app] != status else { return }
        knownBundleStatuses[app] = status
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
        trash: FileTrash = .system,
        stopTimeline: StopTimeline = .standard
    ) {
        self.store = store
            ?? ProfileStore(fileURL: Self.appSupportDirectory.appendingPathComponent("profiles.json"))
        self.launcher = launcher
        self.defaults = defaults ?? .standard
        self.dataRootDirectory = dataRootDirectory
        self.trash = trash
        self.stopTimeline = stopTimeline

        var bundleURLs: [ManagedApp: URL] = [:]
        for app in ManagedApp.allCases {
            bundleURLs[app] = Self.storedBundleURL(for: app, in: self.defaults)
        }
        // Tests inject scratch bundles; the app uses stored or default locations.
        if let claudeBundleURL { bundleURLs[.claude] = claudeBundleURL }
        if let chatGPTBundleURL { bundleURLs[.chatGPT] = chatGPTBundleURL }
        self.bundleURLs = bundleURLs

        let launchIDs = self.defaults.stringArray(forKey: Self.launchProfilesDefaultsKey) ?? []
        launchProfileIDs = Set(launchIDs.compactMap(UUID.init(uuidString:)))

        // After every stored property is set: these are observed accessors.
        for app in ManagedApp.allCases {
            knownBundleStatuses[app] = app.bundleStatus(at: self.bundleURLs[app] ?? app.defaultBundleURL)
        }
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
        for app in ManagedApp.allCases {
            recordBundleStatus(bundleStatus(for: app), for: app)
        }
        refreshInstalledVersions()

        // Classic or another app at the configured path cannot be started,
        // so never manage instances running from it either.
        for app in listedApps where lastKnownBundleStatus(for: app).isApp {
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
            // A pending Stop keeps its handle until the process exits or
            // the stop gives up.
            guard stopSupervisors[id] == nil else { continue }
            handle.terminationHandler = nil
            handles[id] = nil
            instanceVersions[id] = nil
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

    /// nil returns the profile to its automatic color.
    func setColor(_ color: ProfileColor?, forProfile id: UUID) throws {
        guard !ClaudeProfile.isBuiltIn(id: id) else { throw ProfileManagerError.builtInProfile }
        try ensureProfileListWritable()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        profiles[index].color = color
        try persist()
    }

    /// Removes the profile from the list (stopping it first if running).
    /// Its data directory is deliberately left on disk: it holds the account's
    /// login and conversations, and deletion is destructive.
    func removeProfile(id: UUID) throws {
        guard !ClaudeProfile.isBuiltIn(id: id) else { throw ProfileManagerError.builtInProfile }
        try ensureProfileListWritable()
        stop(id: id)
        profiles.removeAll { $0.id == id }
        closedForUpdateIDs.removeAll { $0 == id }
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

    func state(of id: UUID) -> InstanceState {
        if runningProfileIDs.contains(id) { return .running }
        guard stoppingProfileIDs.contains(id) else { return .stopped }
        return startsAfterExit.contains(id) ? .restarting : .stopping
    }

    /// An isolated profile that never ran has no data folder yet, so its
    /// first start is a sign-in.
    func needsSignIn(id: UUID) -> Bool {
        guard let directory = listedProfiles.first(where: { $0.id == id })?.location.dataDirectory else { return false }
        return !FileManager.default.fileExists(atPath: directory.path)
    }

    /// Running entries of the same app, in list order. Browser sign-in and
    /// connector callbacks can reach any of them instead of a new profile.
    func otherRunningProfiles(sameAppAs id: UUID) -> [ClaudeProfile] {
        guard let app = listedProfiles.first(where: { $0.id == id })?.app else { return [] }
        return listedProfiles.filter { $0.id != id && $0.app == app && isRunning(id: $0.id) }
    }

    /// Launch only after a fresh scan, so an externally opened default instance is not duplicated.
    func start(id: UUID) throws {
        guard let profile = listedProfiles.first(where: { $0.id == id }) else {
            throw ProfileManagerError.profileNotFound
        }
        refreshRunningProcesses()
        try launch(profile)
    }

    /// Callers scan for running instances first.
    private func launch(_ profile: ClaudeProfile) throws {
        let id = profile.id
        guard !isRunning(id: id) else { return }

        // stop() reports the profile as stopped immediately, but the previous
        // process can stay alive for up to the force-kill grace period.
        // Launching now would put a second instance into a data directory the
        // old process still owns.
        if let previous = handles[id], previous.isRunning {
            throw ProfileManagerError.stopInProgress
        }

        let bundle = try launchableBundle(for: profile.app)

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

    /// The app's bundle, or the reason it cannot start an instance now.
    private func launchableBundle(for app: ManagedApp) throws -> URL {
        let bundle = bundleURL(for: app)
        let status = app.bundleStatus(at: bundle)
        recordBundleStatus(status, for: app)
        switch status {
        case .available:
            return bundle
        case .missing:
            throw ProfileManagerError.bundleMissing(app: app, path: bundle.path)
        case .unsupported:
            throw ProfileManagerError.unsupportedBundle(app: app, path: bundle.path)
        case .otherApp:
            throw ProfileManagerError.otherApp(app: app, path: bundle.path)
        }
    }

    /// Registers a live handle as the running instance for a profile and
    /// observes its termination. The `isRunning` re-check after assigning the
    /// handler covers a process that exited before the handler could be set
    /// (Foundation never invokes a termination handler attached to a process
    /// that already exited).
    private func attach(handle: ClaudeProcessHandle, to id: UUID) {
        handles[id] = handle
        runningProfileIDs.insert(id)
        if let app = listedProfiles.first(where: { $0.id == id })?.app {
            instanceVersions[id] = installedVersions[app]
        }
        closedForUpdateIDs.removeAll { $0 == id }

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
        switch state(of: id) {
        case .running:
            if let handle = handles[id] { launcher.activate(handle: handle) }
        case .stopping, .restarting:
            startsAfterExit.insert(id)
        case .stopped:
            do {
                try start(id: id)
            } catch {
                report(error)
            }
        }
    }

    /// Quits the instance and starts it again once the old process has
    /// exited, e.g. to pick up an app update. A stopped entry just starts.
    /// An instance whose app can no longer start (moved, replaced by an
    /// unsupported build) keeps running.
    func restart(id: UUID) {
        switch state(of: id) {
        case .running:
            guard let app = listedProfiles.first(where: { $0.id == id })?.app else { return }
            do {
                _ = try launchableBundle(for: app)
            } catch {
                report(error)
                return
            }
            stop(id: id)
            startsAfterExit.insert(id)
        case .stopping, .restarting:
            startsAfterExit.insert(id)
        case .stopped:
            open(id: id)
        }
    }

    /// Asks the instance to quit the way ⌘Q does, so it can save its state,
    /// and escalates only while it keeps running (see `StopTimeline`). The
    /// entry is `.stopping` until the process exits; that also cancels a
    /// start queued behind it.
    func stop(id: UUID) {
        if startsAfterExit.contains(id) { startsAfterExit.remove(id) }
        guard isRunning(id: id), let handle = handles[id] else { return }
        runningProfileIDs.remove(id)
        stoppingProfileIDs.insert(id)
        handle.terminate()
        superviseStop(of: id, handle: handle, after: .quitRequested)
    }

    /// Kills an instance that is taking too long to quit; it may lose
    /// unsaved state. Only while stopping: a running instance is asked to
    /// quit first.
    func forceQuit(id: UUID) {
        guard stoppingProfileIDs.contains(id), let handle = handles[id] else { return }
        handle.terminateForcefully()
        superviseStop(of: id, handle: handle, after: .killed)
    }

    /// Takes the next escalation step each time a delay passes with the
    /// process still running. Cancelled when the process exits.
    private func superviseStop(of id: UUID, handle: ClaudeProcessHandle, after step: StopTimeline.Step) {
        stopSupervisors[id]?.cancel()
        let timeline = stopTimeline
        stopSupervisors[id] = Task { [weak self] in
            var step = step
            while true {
                try? await Task.sleep(for: timeline.delay(after: step))
                guard !Task.isCancelled, let self, self.handles[id] === handle else { return }
                // An exit the termination callback has not reported yet.
                guard handle.isRunning else {
                    self.handleTermination(of: id, handle: handle)
                    return
                }

                switch step {
                case .quitRequested:
                    handle.sendTerminationSignal()
                    step = .terminated
                case .terminated:
                    handle.terminateForcefully()
                    step = .killed
                case .killed:
                    self.giveUpStopping(id: id, handle: handle)
                    return
                }
            }
        }
    }

    /// Not even SIGKILL ended the process (it is stuck in the kernel). It
    /// still runs in the profile's folder, as discovery would report anyway,
    /// so a listed entry counts as running again instead of "Stopping…"
    /// forever. A deleted profile's process is let go: no row shows it, and
    /// discovery only adopts listed entries. A start queued behind it is
    /// dropped, and the error names the process.
    private func giveUpStopping(id: UUID, handle: ClaudeProcessHandle) {
        guard handles[id] === handle else { return }
        stoppingProfileIDs.remove(id)
        startsAfterExit.remove(id)
        stopSupervisors[id] = nil

        let label = listedProfiles.first { $0.id == id }?.label
        if label == nil {
            handle.terminationHandler = nil
            handles[id] = nil
        } else {
            runningProfileIDs.insert(id)
        }
        report(ProfileManagerError.didNotQuit(label: label, processIdentifier: handle.processIdentifier))
    }

    /// Also cancels starts queued behind instances that are still quitting.
    func stopAll() {
        if !startsAfterExit.isEmpty { startsAfterExit.removeAll() }
        for id in Array(runningProfileIDs) {
            stop(id: id)
        }
    }

    /// Starts every listed profile that is not already running. Failures on
    /// one profile do not prevent the rest from starting; the last error is
    /// surfaced to the user.
    func startAll() {
        refreshRunningProcesses()
        for profile in listedProfiles where !isRunning(id: profile.id) {
            guard state(of: profile.id) == .stopped else {
                startsAfterExit.insert(profile.id)
                continue
            }
            do {
                try launch(profile)
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
        // Quit on its own, perhaps to install an update: the updater
        // replaces the bundle after the app quits. The last scan's version,
        // not the bundle's now: the quit can reach here after the swap.
        // See `profilesClosedForUpdate`.
        if !stoppingProfileIDs.contains(id), let app = profiles.first(where: { $0.id == id })?.app {
            recentExits[id] = (installedVersions[app], Date())
        }
        instanceVersions[id] = nil
        handles[id] = nil
        runningProfileIDs.remove(id)
        stoppingProfileIDs.remove(id)
        stopSupervisors[id]?.cancel()
        stopSupervisors[id] = nil

        guard startsAfterExit.remove(id) != nil,
              listedProfiles.contains(where: { $0.id == id }) else { return }
        do {
            try start(id: id)
        } catch {
            report(error)
        }
    }

    // MARK: App updates

    func installedVersion(of app: ManagedApp) -> String? {
        installedVersions[app]
    }

    /// Running entries of `app` started before its installed version: they
    /// run the old one until restarted. Empty after `postponeRestart(for:)`
    /// until another version is installed.
    func instancesNeedingRestart(for app: ManagedApp) -> [ClaudeProfile] {
        guard let installed = installedVersions[app],
              postponedRestartVersions[app] != installed else { return [] }
        return listedProfiles.filter { profile in
            guard profile.app == app, isRunning(id: profile.id),
                  let running = instanceVersions[profile.id] else { return false }
            return running != installed
        }
    }

    func postponeRestart(for app: ManagedApp) {
        postponedRestartVersions[app] = installedVersions[app]
    }

    /// Isolated entries that quit on their own while their app was updated.
    /// Claude's updater relaunches the app without the profile's folder, so
    /// a window that reopened by itself belongs to the Default entry.
    var profilesClosedForUpdate: [ClaudeProfile] {
        closedForUpdateIDs.compactMap { id in profiles.first { $0.id == id } }
    }

    func dismissClosedForUpdate(id: UUID) {
        closedForUpdateIDs.removeAll { $0 == id }
    }

    private func refreshInstalledVersions() {
        // An unsupported build (ChatGPT Classic) has no version worth
        // tracking: its instances cannot be restarted from here.
        for app in ManagedApp.allCases {
            let version = bundleStatus(for: app) == .unsupported ? nil : app.bundleVersion(at: bundleURL(for: app))
            if installedVersions[app] != version { installedVersions[app] = version }
        }

        // Seen while the version could not be read, say mid-update: assume
        // current, as for instances adopted at launch.
        for profile in listedProfiles where isRunning(id: profile.id) && instanceVersions[profile.id] == nil {
            if let installed = installedVersions[profile.app] { instanceVersions[profile.id] = installed }
        }

        let now = Date()
        for (id, exit) in recentExits {
            guard now.timeIntervalSince(exit.date) < Self.updateRelaunchWindow,
                  let app = profiles.first(where: { $0.id == id })?.app else {
                recentExits[id] = nil
                continue
            }
            guard let installed = installedVersions[app], installed != exit.installed else { continue }
            recentExits[id] = nil
            if !isRunning(id: id), !closedForUpdateIDs.contains(id) { closedForUpdateIDs.append(id) }
        }
    }

    // MARK: Open at launch

    func opensAtLaunch(id: UUID) -> Bool {
        launchProfileIDs.contains(id)
    }

    /// Kept for removed profiles too, so undoing a delete keeps the choice.
    func setOpensAtLaunch(_ opens: Bool, id: UUID) {
        if opens {
            launchProfileIDs.insert(id)
        } else {
            launchProfileIDs.remove(id)
        }
        defaults.set(launchProfileIDs.map(\.uuidString).sorted(), forKey: Self.launchProfilesDefaultsKey)
    }

    /// Starts the marked entries that are not running, once per run of the
    /// app: the window can close and reopen without starting them again.
    /// Running ones are left alone, so a login launch pulls no window
    /// forward. The first failure is reported after the rest have started,
    /// since a successful start clears the error; so is an error from
    /// before, such as a list that could not be loaded.
    func openProfilesMarkedForLaunch() {
        guard !didOpenLaunchProfiles else { return }
        didOpenLaunchProfiles = true
        let earlierError = lastError
        var firstFailure: (any Error)?
        for profile in listedProfiles where launchProfileIDs.contains(profile.id) && !isRunning(id: profile.id) {
            do {
                try start(id: profile.id)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure {
            report(firstFailure)
        } else if lastError == nil {
            lastError = earlierError
        }
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
        recordBundleStatus(bundleStatus(for: app), for: app)
    }

    func setBundleURL(_ url: URL, for app: ManagedApp) {
        setBundlePath(url.path, for: app)
    }

    func resetBundlePath(for app: ManagedApp) {
        defaults.removeObject(forKey: app.bundlePathDefaultsKey)
        bundleURLs[app] = app.defaultBundleURL
        recordBundleStatus(bundleStatus(for: app), for: app)
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
    case otherApp(app: ManagedApp, path: String)
    case stopInProgress
    case builtInProfile
    case profileListUnavailable(reason: String)
    case unlistedDataUnavailable
    case dataInUse(name: String)
    case didNotQuit(label: String?, processIdentifier: Int32)

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
        case .otherApp(let app, let path):
            return "The app at \(path) is not \(app.productName). Choose \(app.bundleName) in Settings."
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
        case .didNotQuit(let label, let processIdentifier):
            let instance = label.map { "“\($0)”" } ?? "An instance"
            return "\(instance) (process \(processIdentifier)) did not quit, even when forced, and is still running. Check it in Activity Monitor."
        }
    }
}
