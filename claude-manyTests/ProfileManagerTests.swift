import XCTest
@testable import claude_many

/// Records launches instead of spawning real processes, so the manager's
/// behavior can be tested without touching Claude. Only ever touched from
/// the main actor (the manager and the tests are both main-actor isolated),
/// so unchecked Sendable is safe here.
final class FakeClaudeLauncher: ClaudeLauncher, @unchecked Sendable {
    struct LaunchRecord: Equatable {
        let app: ManagedApp
        let executable: URL
        let location: ClaudeInstanceLocation
        var dataDirectory: URL? { location.dataDirectory }
    }

    private(set) var launches: [LaunchRecord] = []
    private(set) var launchedHandles: [FakeClaudeProcess] = []
    var shouldThrow: (any Error)?
    /// Handles `runningHandles(app:executable:)` returns for their app,
    /// simulating live processes discovered at load time (e.g. left over
    /// from a relaunch).
    var runningHandlesToReturn: [FakeClaudeProcess] = []
    /// When true, a launched process is already dead by the time launch()
    /// returns (it exited before the manager could attach its handler).
    var launchReturnsDeadHandle = false
    private(set) var discoveryCalls = 0
    private(set) var activatedPIDs: [Int32] = []
    /// When set, launch() throws this error once that many launches have
    /// already succeeded — a later profile failing while earlier ones started.
    var errorAfterLaunchCount: (count: Int, error: any Error)?

    func launch(app: ManagedApp, executable: URL, location: ClaudeInstanceLocation) throws -> ClaudeProcessHandle {
        if let errorAfterLaunchCount, launches.count >= errorAfterLaunchCount.count {
            throw errorAfterLaunchCount.error
        }
        if let shouldThrow { throw shouldThrow }
        launches.append(LaunchRecord(app: app, executable: executable, location: location))
        let handle = FakeClaudeProcess(app: app, dataDirectory: location.dataDirectory)
        launchedHandles.append(handle)
        if launchReturnsDeadHandle {
            handle.simulateExit()
        }
        return handle
    }

    func runningHandles(app: ManagedApp, executable: URL) -> [ClaudeProcessHandle] {
        discoveryCalls += 1
        return runningHandlesToReturn.filter { $0.app == app }
    }

    func activate(handle: ClaudeProcessHandle) {
        activatedPIDs.append(handle.processIdentifier)
    }
}

final class FakeClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    var processIdentifier: Int32 { 4242 }
    let app: ManagedApp
    let dataDirectory: URL?
    private(set) var terminationRequested = false
    private(set) var forceKilled = false
    private(set) var exited = false
    var terminationHandler: (@Sendable () -> Void)?

    /// Models reality: SIGTERM leaves the process alive until it actually
    /// exits, so terminate() does not end the process by itself.
    var isRunning: Bool { !exited }

    init(app: ManagedApp = .claude, dataDirectory: URL? = nil) {
        self.app = app
        self.dataDirectory = dataDirectory
    }

    func terminate() { terminationRequested = true }
    func terminateForcefully() { forceKilled = true; exited = true }

    /// Simulates the process exiting on its own (after SIGTERM or on its own).
    func simulateExit() {
        exited = true
        terminationHandler?()
    }
}

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var tempDir: URL!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-mgr-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "claude-many-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        launcher = FakeClaudeLauncher()
        manager = makeManager()
    }

    override func tearDown() async throws {
        manager.stopAll()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(
            store: ProfileStore(fileURL: tempDir.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: tempDir.appendingPathComponent("Claude.app"),
            defaults: defaults,
            dataRootDirectory: tempDir.appendingPathComponent("Profiles")
        )
    }

    /// A manager that resolves the Claude.app location from defaults alone,
    /// like the real app does.
    private func makeManagerWithoutBundleOverride() -> ProfileManager {
        ProfileManager(
            store: ProfileStore(fileURL: tempDir.appendingPathComponent("profiles.json")),
            launcher: launcher,
            defaults: defaults,
            dataRootDirectory: tempDir.appendingPathComponent("Profiles")
        )
    }

    private func makeBundle() throws {
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Claude.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: Slugging

    func testSlugGeneration() {
        XCTAssertEqual(ProfileManager.slug(for: "My Work"), "my-work")
        XCTAssertEqual(ProfileManager.slug(for: "My  Work!! (2)"), "my-work-2")
        XCTAssertEqual(ProfileManager.slug(for: "Ötzi's äccount"), "ötzi-s-äccount")
        XCTAssertEqual(ProfileManager.slug(for: "   "), "profile")
        XCTAssertEqual(ProfileManager.slug(for: "Claude"), "claude")
    }

    // MARK: Add / rename / remove

    func testAddProfileCreatesUniqueDataDirsUnderProfilesRoot() throws {
        let p1 = try manager.addProfile(named: "Work")
        let p2 = try manager.addProfile(named: "Personal")
        let p3 = try manager.addProfile(named: "Work") // same label -> unique dir

        XCTAssertEqual(manager.profiles.count, 3)
        let slash = CharacterSet(charactersIn: "/")
        XCTAssertEqual(p1.dataDirectory.deletingLastPathComponent().path.trimmingCharacters(in: slash),
                       manager.dataRootDirectory.path.trimmingCharacters(in: slash))
        XCTAssertEqual(p2.dataDirectory.lastPathComponent, "personal")
        XCTAssertEqual(p3.dataDirectory.lastPathComponent, "work-2")
        XCTAssertNotEqual(p1.dataDirectory, p2.dataDirectory)
        XCTAssertNotEqual(p1.dataDirectory, p3.dataDirectory)
        XCTAssertTrue(p1.dataDirectory.path.hasPrefix(tempDir.path), "data dirs must stay in the scratch root")
    }

    func testAddProfileRejectsEmptyName() {
        XCTAssertThrowsError(try manager.addProfile(named: "   ")) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidLabel)
        }
        XCTAssertEqual(manager.profiles.count, 0)
    }

    func testAddProfilePersistsImmediately() throws {
        let profile = try manager.addProfile(named: "Persisted")
        let reloaded = ProfileManager(store: manager.store, launcher: launcher, claudeBundleURL: manager.bundleURL(for: .claude))
        reloaded.load()
        XCTAssertEqual(reloaded.profiles, [profile])
    }

    func testRenameProfile() throws {
        let profile = try manager.addProfile(named: "Before")
        try manager.renameProfile(id: profile.id, to: "After")
        XCTAssertEqual(manager.profiles.first?.label, "After")
        XCTAssertEqual(manager.profiles.first?.dataDirectory, profile.dataDirectory, "renaming must not move the data dir")
    }

    func testNamesAreTrimmedAndBlankNamesAreNoNames() {
        XCTAssertEqual(ClaudeProfile.normalizedLabel("  Work \n"), "Work")
        XCTAssertNil(ClaudeProfile.normalizedLabel(""))
        XCTAssertNil(ClaudeProfile.normalizedLabel(" \t\n "), "the rename field reverts on this instead of failing")
    }

    func testRenameProfileRejectsEmptyName() throws {
        let profile = try manager.addProfile(named: "Before")
        XCTAssertThrowsError(try manager.renameProfile(id: profile.id, to: " ")) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidLabel)
        }
        XCTAssertEqual(manager.profiles.first?.label, "Before")
    }

    func testRemoveProfileStopsItFirst() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Temp")
        try manager.start(id: profile.id)
        XCTAssertTrue(manager.isRunning(id: profile.id))

        try manager.removeProfile(id: profile.id)
        XCTAssertEqual(manager.profiles, [])
        XCTAssertFalse(manager.isRunning(id: profile.id))
        XCTAssertTrue(launcher.launchedHandles.last?.terminationRequested == true, "running profile must be stopped on removal")
    }

    func testRemoveProfileKeepsDataDirectoryOnDisk() throws {
        let profile = try manager.addProfile(named: "KeepMe")
        try FileManager.default.createDirectory(at: profile.dataDirectory, withIntermediateDirectories: true)
        try manager.removeProfile(id: profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
    }

    // MARK: Start

    func testStartFailsWithFriendlyErrorWhenBundleMissing() throws {
        let profile = try manager.addProfile(named: "X")
        XCTAssertThrowsError(try manager.start(id: profile.id)) { error in
            XCTAssertEqual(error as? ProfileManagerError,
                           .bundleMissing(app: .claude, path: tempDir.appendingPathComponent("Claude.app").path))
        }
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertFalse(manager.isRunning(id: profile.id))
    }

    func testStartLaunchesWithProfileDataDirectory() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Env Check")
        try manager.start(id: profile.id)

        XCTAssertTrue(manager.isRunning(id: profile.id))
        XCTAssertEqual(launcher.launches.count, 1)
        let record = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(record.executable.path,
                       tempDir.appendingPathComponent("Claude.app/Contents/MacOS/Claude").path)
        XCTAssertEqual(record.dataDirectory, profile.dataDirectory)
    }

    func testStartCreatesDataDirectoryLazily() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Lazy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
        try manager.start(id: profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
    }

    func testStartIsIdempotentWhileRunning() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Once")
        try manager.start(id: profile.id)
        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testStartUnknownProfileThrows() {
        XCTAssertThrowsError(try manager.start(id: UUID())) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileNotFound)
        }
    }

    func testStartAfterExternalExitCanRestart() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Restart")
        try manager.start(id: profile.id)
        let handle = launcher.launchedHandles.first!

        handle.simulateExit()
        let expectation = expectation(description: "termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(manager.isRunning(id: profile.id))

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    func testQuickStopStartCannotLaunchDuplicateWhileOldProcessAlive() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Quick")
        try manager.start(id: profile.id)
        let first = try XCTUnwrap(launcher.launchedHandles.first)

        manager.stop(id: profile.id)
        XCTAssertFalse(manager.isRunning(id: profile.id), "stop reports stopped immediately")
        XCTAssertTrue(first.isRunning, "fake models the SIGTERM grace window: the old process is still alive")

        XCTAssertThrowsError(try manager.start(id: profile.id)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .stopInProgress)
        }
        XCTAssertEqual(launcher.launches.count, 1, "no duplicate may be launched into a data dir the old process still owns")

        first.simulateExit()
        let expectation = expectation(description: "termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2, "start works once the old process has actually exited")
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    func testStartReconcilesProcessThatExitedBeforeHandlerAssignment() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "FastExit")
        launcher.launchReturnsDeadHandle = true

        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertFalse(manager.isRunning(id: profile.id),
                       "a process that died before the handler was attached must not stick as Running")

        launcher.launchReturnsDeadHandle = false
        try manager.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 2, "the profile must be startable again")
        XCTAssertTrue(manager.isRunning(id: profile.id))
    }

    // MARK: Stop

    func testStopMarksProfileStoppedAndTerminatesProcess() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "StopMe")
        try manager.start(id: profile.id)

        manager.stop(id: profile.id)
        XCTAssertFalse(manager.isRunning(id: profile.id), "stop must take effect immediately")
        XCTAssertTrue(launcher.launchedHandles.first?.terminationRequested == true)
    }

    func testStopOfStoppedProfileIsNoOp() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Idle")
        manager.stop(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 0)
    }

    // MARK: Relaunch reconciliation

    func testLoadMarksProfileRunningWhenLiveProcessOwnsItsDataDir() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Leftover")
        let leftover = FakeClaudeProcess(dataDirectory: profile.dataDirectory)
        launcher.runningHandlesToReturn = [leftover]

        let reloaded = makeManager()
        reloaded.load()

        XCTAssertTrue(reloaded.isRunning(id: profile.id),
                      "a leftover instance must show as running after relaunch")

        try reloaded.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 0,
                       "start must not spawn a duplicate into a data dir a live process owns")
        XCTAssertTrue(reloaded.isRunning(id: profile.id))

        reloaded.stop(id: profile.id)
        XCTAssertTrue(leftover.terminationRequested, "stop must terminate the leftover instance")

        leftover.simulateExit()
        let expectation = expectation(description: "leftover termination observed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(reloaded.isRunning(id: profile.id), "state must clean up when the leftover exits")

        try reloaded.start(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1, "the profile must be startable again")
        XCTAssertTrue(reloaded.isRunning(id: profile.id))
    }

    func testLoadIgnoresLiveProcessesWithoutAMatchingProfile() throws {
        let profile = try manager.addProfile(named: "Only")
        let foreign = FakeClaudeProcess(dataDirectory: tempDir.appendingPathComponent("elsewhere"))
        launcher.runningHandlesToReturn = [foreign]

        let reloaded = makeManager()
        reloaded.load()

        XCTAssertFalse(reloaded.isRunning(id: profile.id),
                       "a process owning a different data dir must not mark the profile running")
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func testLoadMatchesEquivalentDataDirectoryPaths() throws {
        let profile = try manager.addProfile(named: "Work")
        let equivalent = profile.dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("unused/../work", isDirectory: true)
        launcher.runningHandlesToReturn = [FakeClaudeProcess(dataDirectory: equivalent)]

        let reloaded = makeManager()
        reloaded.load()

        XCTAssertTrue(reloaded.isRunning(id: profile.id))
        XCTAssertEqual(reloaded.profiles.first?.dataDirectory, profile.dataDirectory,
                       "matching must not rewrite the persisted path")
    }

    // MARK: Persistence across instances

    func testProfilesSurviveManagerRecreation() throws {
        try manager.addProfile(named: "Alpha")
        try manager.addProfile(named: "Beta")

        let reloaded = makeManager()
        reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(reloaded.profiles, manager.profiles)
    }

    func testLoadReportsErrorOnCorruptStore() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("profiles.json").path,
                                       contents: Data("garbage".utf8))
        let corrupt = makeManager()
        corrupt.load()
        XCTAssertNotNil(corrupt.lastError)
        XCTAssertEqual(corrupt.profiles, [])
    }

    // MARK: Untitled naming / reorder / restore

    func testAddUntitledProfileNumbersPlaceholders() throws {
        let first = try manager.addUntitledProfile(for: .claude)
        let second = try manager.addUntitledProfile(for: .claude)
        try manager.renameProfile(id: first.id, to: "Work")
        // "New Claude Profile" is free again after the rename, so it gets reused.
        let third = try manager.addUntitledProfile(for: .claude)
        let fourth = try manager.addUntitledProfile(for: .claude)

        XCTAssertEqual(manager.profiles.first { $0.id == first.id }?.label, "Work")
        XCTAssertEqual(second.label, "New Claude Profile 2")
        XCTAssertEqual(third.label, "New Claude Profile")
        XCTAssertEqual(fourth.label, "New Claude Profile 3")
        XCTAssertEqual(manager.profiles.count, 4)
    }

    func testMoveProfilesReordersAndPersists() throws {
        let a = try manager.addProfile(named: "A")
        let b = try manager.addProfile(named: "B")
        let c = try manager.addProfile(named: "C")

        try manager.moveProfiles(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(manager.profiles.map(\.label), ["B", "C", "A"])

        let reloaded = ProfileManager(store: manager.store, launcher: launcher, claudeBundleURL: manager.bundleURL(for: .claude))
        reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.id), [b.id, c.id, a.id])
    }

    func testRestoreProfilesRestoresSnapshotAndPersists() throws {
        let a = try manager.addProfile(named: "A")
        let b = try manager.addProfile(named: "B")
        let snapshot = manager.profiles

        try manager.removeProfile(id: a.id)
        try manager.renameProfile(id: b.id, to: "Renamed")
        XCTAssertEqual(manager.profiles.map(\.label), ["Renamed"])

        manager.restoreProfiles(snapshot)
        XCTAssertEqual(manager.profiles.map(\.label), ["A", "B"])

        let reloaded = ProfileManager(store: manager.store, launcher: launcher, claudeBundleURL: manager.bundleURL(for: .claude))
        reloaded.load()
        XCTAssertEqual(reloaded.profiles, snapshot, "undo restore must persist")
    }

    func testRestoreProfilesStopsProfilesAbsentFromSnapshot() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Running")
        try manager.start(id: profile.id)
        XCTAssertTrue(manager.isRunning(id: profile.id))

        manager.restoreProfiles([])
        XCTAssertFalse(manager.isRunning(id: profile.id))
        XCTAssertTrue(launcher.launchedHandles.last?.terminationRequested == true,
                      "undoing an add must stop the profile's live instance")
    }

    // MARK: Open / activate

    func testOpenStartsStoppedProfileAndActivatesRunningOne() throws {
        try makeBundle()
        let profile = try manager.addProfile(named: "Work")

        manager.open(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(manager.isRunning(id: profile.id))
        XCTAssertTrue(launcher.activatedPIDs.isEmpty, "a fresh start needs no activation")

        manager.open(id: profile.id)
        XCTAssertEqual(launcher.launches.count, 1, "open must not duplicate a running instance")
        XCTAssertEqual(launcher.activatedPIDs, [4242], "open must bring the running instance forward")
    }

    // MARK: Start all

    func testStartAllStartsOnlyStoppedProfiles() throws {
        try makeBundle()
        let running = try manager.addProfile(named: "Running")
        let idle = try manager.addProfile(named: "Idle")
        try manager.start(id: running.id)
        XCTAssertEqual(launcher.launches.count, 1)

        manager.startAll()
        // Default Claude + the idle profile start; the already-running one does not.
        XCTAssertEqual(launcher.launches.count, 3)
        XCTAssertTrue(manager.isRunning(id: idle.id))
        XCTAssertTrue(manager.isRunning(id: ClaudeProfile.standard.id))
    }

    func testStartAllReportsFailureWithoutStoppingOthers() throws {
        try makeBundle()
        let one = try manager.addProfile(named: "One")
        let two = try manager.addProfile(named: "Two")
        launcher.errorAfterLaunchCount = (1, ProfileManagerError.profileNotFound)

        manager.startAll()
        // Default Claude (first listed) launched; the rest reported the error.
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(manager.isRunning(id: ClaudeProfile.standard.id))
        XCTAssertFalse(manager.isRunning(id: one.id))
        XCTAssertFalse(manager.isRunning(id: two.id))
        XCTAssertNotNil(manager.lastError)
    }

    // MARK: Bundle path persistence

    func testBundlePathPersistsAcrossManagerInstances() throws {
        manager.setBundlePath("/opt/Claude.app", for: .claude)
        XCTAssertEqual(manager.bundleURL(for: .claude).path, "/opt/Claude.app")

        let reloaded = makeManagerWithoutBundleOverride()
        XCTAssertEqual(reloaded.bundleURL(for: .claude).path, "/opt/Claude.app",
                       "a chosen bundle location must survive relaunch")
    }

    func testBundlePathResetClearsPersistence() throws {
        manager.setBundlePath("/opt/Claude.app", for: .claude)
        manager.resetBundlePath(for: .claude)
        XCTAssertEqual(manager.bundleURL(for: .claude), ManagedApp.claude.defaultBundleURL)

        let reloaded = makeManagerWithoutBundleOverride()
        XCTAssertEqual(reloaded.bundleURL(for: .claude), ManagedApp.claude.defaultBundleURL)
    }

    func testBundlePathDefaultsToApplications() {
        XCTAssertEqual(makeManagerWithoutBundleOverride().bundleURL(for: .claude),
                       ManagedApp.claude.defaultBundleURL)
    }
}
