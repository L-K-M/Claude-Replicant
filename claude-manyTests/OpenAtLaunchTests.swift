import XCTest
@testable import claude_many

/// Entries marked "Open at Launch" start once when Claude Replicant starts.
@MainActor
final class OpenAtLaunchTests: XCTestCase {
    private var root: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-launch-\(UUID().uuidString)", isDirectory: true)
        try TestBundle.make(at: root.appendingPathComponent("Claude.app", isDirectory: true))
        defaultsSuiteName = "claude-replicant-launch-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        launcher = FakeClaudeLauncher()
        manager = makeManager()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            // Never the Mac's own ChatGPT: tests rely on it being missing.
            chatGPTBundleURL: root.appendingPathComponent("ChatGPT.app"),
            defaults: defaults,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
    }

    func testMarkedEntriesOpenOnceAtLaunch() throws {
        let work = try manager.addProfile(named: "Work")
        let personal = try manager.addProfile(named: "Personal")
        manager.setOpensAtLaunch(true, id: work.id)
        manager.setOpensAtLaunch(true, id: ClaudeProfile.standard.id)

        let relaunched = makeManager()
        relaunched.load()
        XCTAssertTrue(relaunched.opensAtLaunch(id: work.id), "the choice is remembered")
        XCTAssertFalse(relaunched.opensAtLaunch(id: personal.id))

        relaunched.openProfilesMarkedForLaunch()
        XCTAssertEqual(Set(launcher.launches.map(\.location)), [work.location, .standard])
        XCTAssertFalse(relaunched.isRunning(id: personal.id))

        // The window reopening later must not start them again.
        relaunched.stopAll()
        launcher.launchedHandles.forEach { $0.simulateExit() }
        relaunched.refreshRunningProcesses()
        XCTAssertFalse(relaunched.isRunning(id: work.id))
        relaunched.openProfilesMarkedForLaunch()
        XCTAssertEqual(launcher.launches.count, 2)
    }

    func testRunningEntriesAreLeftAsTheyAre() throws {
        let work = try manager.addProfile(named: "Work")
        manager.setOpensAtLaunch(true, id: work.id)
        launcher.runningHandlesToReturn = [FakeClaudeProcess(dataDirectory: work.dataDirectory)]
        manager.load()

        manager.openProfilesMarkedForLaunch()

        XCTAssertEqual(launcher.launches, [], "no second instance")
        XCTAssertEqual(launcher.activatedPIDs, [], "a login launch must not pull windows forward")
    }

    func testOneFailingEntryDoesNotKeepTheOthersFromOpening() throws {
        let work = try manager.addProfile(named: "Work")
        _ = try manager.addProfile(named: "Research", app: .chatGPT)
        manager.setOpensAtLaunch(true, id: ClaudeProfile.builtIn(for: .chatGPT).id)
        manager.setOpensAtLaunch(true, id: work.id)

        // Listed before Work, Default ChatGPT fails: ChatGPT.app is missing.
        manager.openProfilesMarkedForLaunch()

        XCTAssertEqual(launcher.launches.map(\.location), [work.location], "Work still opens")
        XCTAssertNotNil(manager.lastError, "a failure is reported though a later entry started")
    }

    func testALoadErrorSurvivesTheLaunch() throws {
        manager.setOpensAtLaunch(true, id: ClaudeProfile.standard.id)
        try Data("not json".utf8).write(to: root.appendingPathComponent("profiles.json"))
        manager.load()
        let loadError = try XCTUnwrap(manager.lastError)

        manager.openProfilesMarkedForLaunch()

        XCTAssertEqual(launcher.launches.count, 1, "Default Claude still opens")
        XCTAssertEqual(manager.lastError, loadError, "the user must still learn why the list is empty")
    }

    func testUndoingADeleteKeepsTheChoice() throws {
        let work = try manager.addProfile(named: "Work")
        manager.setOpensAtLaunch(true, id: work.id)
        let before = manager.profiles
        try manager.removeProfile(id: work.id)

        manager.restoreProfiles(before)

        XCTAssertTrue(manager.opensAtLaunch(id: work.id))
    }

    func testUnmarkingAndDeletingStopOpeningAtLaunch() throws {
        let work = try manager.addProfile(named: "Work")
        let personal = try manager.addProfile(named: "Personal")
        manager.setOpensAtLaunch(true, id: work.id)
        manager.setOpensAtLaunch(true, id: personal.id)
        manager.setOpensAtLaunch(false, id: work.id)
        try manager.removeProfile(id: personal.id)

        manager.openProfilesMarkedForLaunch()

        XCTAssertEqual(launcher.launches, [])
    }
}
