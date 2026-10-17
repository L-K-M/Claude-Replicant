import XCTest
@testable import claude_many

@MainActor
final class DefaultClaudeTests: XCTestCase {
    private var root: URL!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-default-\(UUID().uuidString)", isDirectory: true)
        launcher = FakeClaudeLauncher()
        manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
        try TestBundle.make(at: manager.bundleURL(for: .claude))
    }

    override func tearDown() async throws {
        manager.stopAll()
        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultEntryIsAlwaysFirstAndNeverPersisted() throws {
        manager.load()
        XCTAssertEqual(manager.listedProfiles, [.standard])
        XCTAssertEqual(manager.profiles, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.store.fileURL.path))

        let profile = try manager.addProfile(named: "Work")
        XCTAssertEqual(manager.listedProfiles, [.standard, profile])
        XCTAssertEqual(try manager.store.load(), [profile])
        manager.load()
        XCTAssertEqual(manager.listedProfiles, [.standard, profile])
    }

    func testDefaultStartUsesStandardLocationWithoutCreatingPrivateDirectories() throws {
        try manager.start(id: ClaudeProfile.standard.id)
        XCTAssertEqual(launcher.launches.first?.location, .standard)
        XCTAssertTrue(manager.isRunning(id: ClaudeProfile.standard.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.dataRootDirectory.path))
        try manager.start(id: ClaudeProfile.standard.id)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testDefaultCannotBeRenamedRemovedOrEncoded() throws {
        try manager.start(id: ClaudeProfile.standard.id)
        XCTAssertThrowsError(try manager.renameProfile(id: ClaudeProfile.standard.id, to: "Changed")) {
            XCTAssertEqual($0 as? ProfileManagerError, .builtInProfile)
        }
        XCTAssertThrowsError(try manager.removeProfile(id: ClaudeProfile.standard.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .builtInProfile)
        }
        XCTAssertThrowsError(try JSONEncoder().encode(ClaudeProfile.standard))
        XCTAssertEqual(manager.listedProfiles.first, .standard)
        XCTAssertFalse(launcher.launchedHandles[0].terminationRequested)
    }

    func testStoredProfilesCannotImpersonateTheBuiltInEntry() {
        let json = """
        [{"id":"\(ClaudeProfile.standard.id.uuidString)","label":"Imported","dataDirectory":"/other"}]
        """
        XCTAssertThrowsError(try JSONDecoder().decode([ClaudeProfile].self, from: Data(json.utf8)))
    }

    func testExternallyStartedDefaultIsAdoptedBeforeStartAndOnRefresh() throws {
        manager.load()
        let external = FakeClaudeProcess()
        launcher.runningHandlesToReturn = [external]

        try manager.start(id: ClaudeProfile.standard.id)
        XCTAssertEqual(launcher.launches.count, 0, "an already-open normal Claude must not be duplicated")
        XCTAssertTrue(manager.isRunning(id: ClaudeProfile.standard.id))

        external.simulateExit()
        manager.refreshRunningProcesses()
        XCTAssertFalse(manager.isRunning(id: ClaudeProfile.standard.id))

        let replacement = FakeClaudeProcess()
        launcher.runningHandlesToReturn = [replacement]
        manager.refreshRunningProcesses()
        XCTAssertTrue(manager.isRunning(id: ClaudeProfile.standard.id))
        manager.stop(id: ClaudeProfile.standard.id)
        XCTAssertTrue(replacement.terminationRequested)
    }

    func testStoppingDefaultDoesNotStopAnIsolatedProfile() throws {
        let profile = try manager.addProfile(named: "Work")
        let standard = FakeClaudeProcess()
        let isolated = FakeClaudeProcess(dataDirectory: profile.dataDirectory)
        launcher.runningHandlesToReturn = [standard, isolated]
        manager.load()

        manager.stop(id: ClaudeProfile.standard.id)
        XCTAssertTrue(standard.terminationRequested)
        XCTAssertFalse(isolated.terminationRequested)
        XCTAssertTrue(manager.isRunning(id: profile.id))
        XCTAssertThrowsError(try manager.start(id: ClaudeProfile.standard.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .stopInProgress)
        }
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func testDefaultIsPresentWhenTheIsolatedStoreIsCorrupt() throws {
        try Data("invalid".utf8).write(to: manager.store.fileURL)
        manager.load()
        XCTAssertEqual(manager.listedProfiles, [.standard])
        XCTAssertNotNil(manager.lastError)
    }

    func testMultipleWindowsShareDiscoveryAndHandOffOnCancellation() async throws {
        let manager = try XCTUnwrap(manager)
        let first = Task { await manager.monitorRunningProcesses() }
        defer { first.cancel() }
        let startupDeadline = Date().addingTimeInterval(2)
        while launcher.discoveryCalls == 0, Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(launcher.discoveryCalls, 1)
        let second = Task { await manager.monitorRunningProcesses() }
        defer { second.cancel() }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(launcher.discoveryCalls, 1, "two windows must not perform duplicate process sweeps")

        first.cancel()
        await first.value
        let deadline = Date().addingTimeInterval(4)
        while launcher.discoveryCalls < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(launcher.discoveryCalls, 2, "the remaining window must continue refreshing")

        second.cancel()
        await second.value
        let calls = launcher.discoveryCalls
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(launcher.discoveryCalls, calls, "closing every window must stop discovery")
    }
}
