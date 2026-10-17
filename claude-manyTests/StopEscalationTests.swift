import XCTest
@testable import claude_many

/// Stop asks the app to quit and escalates only while it keeps running:
/// quit request, then SIGTERM, then SIGKILL, then giving up on it.
@MainActor
final class StopEscalationTests: XCTestCase {
    private static let step: Duration = .milliseconds(40)
    /// Long enough that a test sees SIGTERM before SIGKILL even on a busy machine.
    private static let killDelay: Duration = .milliseconds(400)

    private var root: URL!
    private var defaultsSuiteName: String!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Claude.app/Contents/MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        defaultsSuiteName = "claude-replicant-stop-tests-\(UUID().uuidString)"
        launcher = FakeClaudeLauncher()
        manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            dataRootDirectory: root.appendingPathComponent("Profiles"),
            stopTimeline: StopTimeline(terminateAfter: Self.step, killAfter: Self.killDelay, giveUpAfter: Self.step)
        )
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func startProfile() throws -> (ClaudeProfile, FakeClaudeProcess) {
        let profile = try manager.addProfile(named: "Work")
        try manager.start(id: profile.id)
        return (profile, try XCTUnwrap(launcher.launchedHandles.last))
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testStopAsksTheAppToQuitBeforeAnySignal() throws {
        let (profile, process) = try startProfile()

        manager.stop(id: profile.id)

        XCTAssertTrue(process.terminationRequested)
        XCTAssertFalse(process.signaled)
        XCTAssertFalse(process.forceKilled)
        XCTAssertEqual(manager.state(of: profile.id), .stopping)
    }

    func testAnAppThatQuitsInTimeIsNeverSignaled() async throws {
        let (profile, process) = try startProfile()
        manager.stop(id: profile.id)
        process.simulateExit()

        // Past both SIGTERM and SIGKILL times.
        try await Task.sleep(for: Self.step * 2 + Self.killDelay)

        XCTAssertFalse(process.signaled)
        XCTAssertFalse(process.forceKilled)
        XCTAssertEqual(manager.state(of: profile.id), .stopped)
    }

    func testAnAppThatKeepsRunningGetsSIGTERMThenSIGKILL() async throws {
        let (profile, process) = try startProfile()
        manager.stop(id: profile.id)

        try await eventually("SIGTERM is sent") { process.signaled }
        XCTAssertFalse(process.forceKilled, "SIGKILL waits for its own grace period")
        try await eventually("SIGKILL is sent") { process.forceKilled }
        try await eventually("the killed instance counts as stopped") { manager.state(of: profile.id) == .stopped }
        XCTAssertNil(manager.lastError)
    }

    func testForceQuitKillsAStoppingInstanceAtOnce() throws {
        let (profile, process) = try startProfile()
        manager.stop(id: profile.id)

        manager.forceQuit(id: profile.id)

        XCTAssertTrue(process.forceKilled)
    }

    func testForceQuitLeavesARunningInstanceAlone() throws {
        let (profile, process) = try startProfile()

        manager.forceQuit(id: profile.id)

        XCTAssertFalse(process.forceKilled, "a running instance is asked to quit first")
        XCTAssertEqual(manager.state(of: profile.id), .running)
    }

    func testAProcessThatOutlivesSIGKILLCountsAsRunningAgainWithAnError() async throws {
        let (profile, process) = try startProfile()
        process.survivesKill = true
        manager.restart(id: profile.id)
        manager.forceQuit(id: profile.id)

        // Discovery would find it anyway: it still runs in the profile's folder.
        try await eventually("the entry stops waiting") { manager.state(of: profile.id) == .running }
        launcher.runningHandlesToReturn = [process]
        manager.refreshRunningProcesses()

        XCTAssertEqual(manager.state(of: profile.id), .running)
        XCTAssertEqual(launcher.launches.count, 1, "the queued restart is dropped: the old process holds the folder")
        let error = try XCTUnwrap(manager.lastError)
        XCTAssertTrue(error.contains("Work") && error.contains("\(process.processIdentifier)"), error)
    }

    func testAStuckInstanceOfADeletedProfileIsLetGo() async throws {
        let (profile, process) = try startProfile()
        process.survivesKill = true
        try manager.removeProfile(id: profile.id)
        manager.forceQuit(id: profile.id)

        try await eventually("the stop gives up") { manager.lastError != nil }

        XCTAssertEqual(manager.runningCount, 0, "no row shows it, so it must not count")
        XCTAssertEqual(manager.state(of: profile.id), .stopped)
    }

    func testARestartingInstanceStartsAgainAfterForceQuit() async throws {
        let (profile, process) = try startProfile()
        manager.restart(id: profile.id)

        manager.forceQuit(id: profile.id)
        process.simulateExit()

        try await eventually("the new instance starts") { launcher.launches.count == 2 }
        XCTAssertEqual(manager.state(of: profile.id), .running)
    }
}
