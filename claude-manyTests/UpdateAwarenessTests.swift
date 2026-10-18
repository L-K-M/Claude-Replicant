import XCTest
@testable import claude_many

/// An app updated on disk keeps old instances running the old version, and
/// Claude's updater relaunches without a profile's folder.
@MainActor
final class UpdateAwarenessTests: XCTestCase {
    private var root: URL!
    private var defaultsSuiteName: String!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-update-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "claude-replicant-update-tests-\(UUID().uuidString)"
        launcher = FakeClaudeLauncher()
        manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Installs (or replaces) Claude.app as `version`, like an update does.
    private func installClaude(version: String) throws {
        let contents = root.appendingPathComponent("Claude.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.anthropic.claudefordesktop",
                               "CFBundleShortVersionString": version],
            format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func startProfile(named name: String = "Work") throws -> (ClaudeProfile, FakeClaudeProcess) {
        let profile = try manager.addProfile(named: name)
        try manager.start(id: profile.id)
        return (profile, try XCTUnwrap(launcher.launchedHandles.last))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Restart after an update

    func testInstancesStartedBeforeAnUpdateNeedARestart() async throws {
        try installClaude(version: "1.0")
        let (work, process) = try startProfile()
        XCTAssertEqual(manager.installedVersion(of: .claude), "1.0")
        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude), [])

        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.installedVersion(of: .claude), "1.1")
        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude).map(\.id), [work.id])

        manager.restart(id: work.id)
        process.simulateExit()
        await drainMainQueue()
        XCTAssertTrue(manager.isRunning(id: work.id))
        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude), [], "the new instance runs the new version")
    }

    func testPostponingHidesTheNoticeUntilTheNextVersion() throws {
        try installClaude(version: "1.0")
        let (work, _) = try startProfile()
        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()

        manager.postponeRestart(for: .claude)
        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude), [])

        try installClaude(version: "1.2")
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude).map(\.id), [work.id])
    }

    // MARK: Quit during an update

    func testAProfileThatQuitsDuringAnUpdateIsReported() async throws {
        try installClaude(version: "1.0")
        let (work, process) = try startProfile()

        // "Restart to update" in the instance: it quits, then the bundle is replaced.
        process.simulateExit()
        await drainMainQueue()
        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.profilesClosedForUpdate.map(\.id), [work.id])

        manager.dismissClosedForUpdate(id: work.id)
        XCTAssertEqual(manager.profilesClosedForUpdate, [])
    }

    func testAQuitNoticedOnlyAfterTheUpdateIsStillReported() async throws {
        try installClaude(version: "1.0")
        let (work, process) = try startProfile()

        // The updater swaps the bundle before the quit reaches the main queue.
        process.simulateExit()
        try installClaude(version: "1.1")
        await drainMainQueue()
        manager.refreshRunningProcesses()

        XCTAssertEqual(manager.profilesClosedForUpdate.map(\.id), [work.id])
    }

    func testAnOutdatedInstanceQuittingLaterIsNotBlamedOnTheUpdate() async throws {
        try installClaude(version: "1.0")
        let (_, process) = try startProfile()
        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()

        // Quit by hand well after the update was installed.
        process.simulateExit()
        await drainMainQueue()
        manager.refreshRunningProcesses()

        XCTAssertEqual(manager.profilesClosedForUpdate, [])
    }

    func testInstancesSeenWhileTheVersionWasUnreadableAreTrackedOnceItIs() throws {
        // Mid-replacement: the bundle's identity is readable, its version not yet.
        // (A bundle with no Info.plist at all is refused as another app.)
        try TestBundle.make(at: root.appendingPathComponent("Claude.app", isDirectory: true))
        let (work, _) = try startProfile()
        try installClaude(version: "1.0")
        manager.refreshRunningProcesses()

        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()

        XCTAssertEqual(manager.instancesNeedingRestart(for: .claude).map(\.id), [work.id])
    }

    func testOpeningTheProfileAgainClearsTheReport() async throws {
        try installClaude(version: "1.0")
        let (work, process) = try startProfile()
        process.simulateExit()
        await drainMainQueue()
        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()

        manager.open(id: work.id)

        XCTAssertEqual(manager.profilesClosedForUpdate, [])
    }

    func testStoppedProfilesAndQuitsWithoutAnUpdateAreNotReported() async throws {
        try installClaude(version: "1.0")
        let (stopped, stoppedProcess) = try startProfile(named: "Stopped")
        let (quit, quitProcess) = try startProfile(named: "Quit")

        manager.stop(id: stopped.id)
        stoppedProcess.simulateExit()
        quitProcess.simulateExit()
        await drainMainQueue()
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.profilesClosedForUpdate, [], "no update happened")

        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.profilesClosedForUpdate.map(\.id), [quit.id], "a stop is not a quit for an update")
    }

    func testDeletingAProfileDropsItsReport() async throws {
        try installClaude(version: "1.0")
        let (work, process) = try startProfile()
        process.simulateExit()
        await drainMainQueue()
        try installClaude(version: "1.1")
        manager.refreshRunningProcesses()

        try manager.removeProfile(id: work.id)
        manager.restoreProfiles([work])

        XCTAssertEqual(manager.profilesClosedForUpdate, [], "a deleted profile's notice does not come back")
    }

    // MARK: Versions

    func testAnUnsupportedBuildReportsNoVersion() throws {
        let contents = root.appendingPathComponent("ChatGPT.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.openai.chat", "CFBundleShortVersionString": "1.2025"],
            format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let classicManager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            chatGPTBundleURL: root.appendingPathComponent("ChatGPT.app"),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )

        classicManager.refreshRunningProcesses()

        XCTAssertNil(classicManager.installedVersion(of: .chatGPT), "ChatGPT Classic cannot run profiles")
    }

    func testVersionsNewerThanTheCheckedOneAreFlagged() {
        XCTAssertFalse(ManagedApp.claude.isNewerThanChecked(ManagedApp.claude.checkedVersion))
        XCTAssertFalse(ManagedApp.claude.isNewerThanChecked("2.4.0"))
        XCTAssertTrue(ManagedApp.claude.isNewerThanChecked("2.31227.0"))
        XCTAssertTrue(ManagedApp.claude.isNewerThanChecked("3.0"))
        XCTAssertTrue(ManagedApp.chatGPT.isNewerThanChecked("26.1007.71327"))
    }
}
