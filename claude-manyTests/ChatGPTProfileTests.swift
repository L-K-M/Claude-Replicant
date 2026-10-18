import XCTest
@testable import claude_many

@MainActor
final class ChatGPTProfileTests: XCTestCase {
    private static let currentBundleIdentifier = "com.openai.codex"
    private static let classicBundleIdentifier = "com.openai.chat"

    private var root: URL!
    private var launcher: FakeClaudeLauncher!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!
    private var manager: ProfileManager!

    private var defaultChatGPT: ClaudeProfile { .builtIn(for: .chatGPT) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-chatgpt-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "claude-replicant-chatgpt-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        launcher = FakeClaudeLauncher()
        manager = makeManager()
    }

    override func tearDown() async throws {
        manager.stopAll()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> ProfileManager {
        ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            chatGPTBundleURL: root.appendingPathComponent("ChatGPT.app"),
            defaults: defaults,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
    }

    /// Only the Info.plist identity matters to the manager.
    private func makeChatGPTBundle(identifier: String) throws {
        let contents = root.appendingPathComponent("ChatGPT.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                                      format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: Listing

    func testDefaultChatGPTIsListedOnlyWhileChatGPTProfilesExist() throws {
        try makeChatGPTBundle(identifier: Self.currentBundleIdentifier)
        manager.load()
        XCTAssertEqual(manager.listedProfiles, [.standard],
                       "an installed ChatGPT alone must not join the list or Start All")

        let claude = try manager.addProfile(named: "Work")
        let chatGPT = try manager.addProfile(named: "Research", app: .chatGPT)
        XCTAssertEqual(manager.listedProfiles, [.standard, defaultChatGPT, claude, chatGPT])

        let reloaded = makeManager()
        reloaded.load()
        XCTAssertEqual(reloaded.profiles.map(\.app), [.claude, .chatGPT])
        XCTAssertEqual(reloaded.listedProfiles, manager.listedProfiles)

        try reloaded.removeProfile(id: chatGPT.id)
        XCTAssertEqual(reloaded.listedProfiles, [.standard, claude])
    }

    func testUntitledProfilesAreNamedForTheirApp() throws {
        XCTAssertEqual(try manager.addUntitledProfile(for: .chatGPT).label, "New ChatGPT Profile")
        XCTAssertEqual(try manager.addUntitledProfile(for: .chatGPT).label, "New ChatGPT Profile 2")
        XCTAssertEqual(try manager.addUntitledProfile(for: .claude).label, "New Claude Profile")
    }

    // MARK: Start

    func testStartLaunchesChatGPTForProfilesAndTheDefaultEntry() throws {
        try makeChatGPTBundle(identifier: Self.currentBundleIdentifier)
        let profile = try manager.addProfile(named: "Research", app: .chatGPT)
        try manager.start(id: profile.id)

        let record = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(record.app, .chatGPT)
        XCTAssertEqual(record.executable.path,
                       root.appendingPathComponent("ChatGPT.app/Contents/MacOS/ChatGPT").path)
        XCTAssertEqual(record.location, profile.location)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
        XCTAssertTrue(manager.isRunning(id: profile.id))

        try manager.start(id: defaultChatGPT.id)
        XCTAssertEqual(launcher.launches.last?.app, .chatGPT)
        XCTAssertEqual(launcher.launches.last?.location, .standard)
        XCTAssertTrue(manager.isRunning(id: defaultChatGPT.id))
        XCTAssertFalse(manager.isRunning(id: ClaudeProfile.standard.id))
    }

    func testMissingAndClassicChatGPTAreRefused() throws {
        let profile = try manager.addProfile(named: "Research", app: .chatGPT)
        let bundlePath = root.appendingPathComponent("ChatGPT.app").path
        XCTAssertThrowsError(try manager.start(id: profile.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .bundleMissing(app: .chatGPT, path: bundlePath))
        }

        try makeChatGPTBundle(identifier: Self.classicBundleIdentifier)
        XCTAssertEqual(manager.bundleStatus(for: .chatGPT), .unsupported)
        XCTAssertThrowsError(try manager.start(id: profile.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .unsupportedBundle(app: .chatGPT, path: bundlePath))
        }
        XCTAssertEqual(launcher.launches.count, 0, "Classic shares one login and must never start for a profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.dataDirectory.path))
    }

    func testAnotherAppChosenAsChatGPTIsNotMistakenForClassic() throws {
        try makeChatGPTBundle(identifier: "com.example.notes")
        XCTAssertEqual(manager.bundleStatus(for: .chatGPT), .otherApp)
    }

    // MARK: Discovery

    func testDiscoveryMatchesInstancesToEntriesOfTheirOwnApp() throws {
        let claude = try manager.addProfile(named: "Work")
        let chatGPT = try manager.addProfile(named: "Research", app: .chatGPT)
        // ChatGPT running in a Claude profile's folder belongs to neither entry.
        let misplaced = FakeClaudeProcess(app: .chatGPT, dataDirectory: claude.dataDirectory)
        let research = FakeClaudeProcess(app: .chatGPT, dataDirectory: chatGPT.dataDirectory)
        let normalChatGPT = FakeClaudeProcess(app: .chatGPT)
        launcher.runningHandlesToReturn = [misplaced, research, normalChatGPT]

        manager.load()
        XCTAssertFalse(manager.isRunning(id: claude.id))
        XCTAssertTrue(manager.isRunning(id: chatGPT.id))
        XCTAssertTrue(manager.isRunning(id: defaultChatGPT.id))
        XCTAssertFalse(manager.isRunning(id: ClaudeProfile.standard.id))

        manager.stop(id: defaultChatGPT.id)
        XCTAssertTrue(normalChatGPT.terminationRequested)
        XCTAssertFalse(research.terminationRequested)
        XCTAssertFalse(misplaced.terminationRequested)
    }

    func testRunningClassicIsNeverAdoptedAsDefaultChatGPT() throws {
        try makeChatGPTBundle(identifier: Self.classicBundleIdentifier)
        _ = try manager.addProfile(named: "Research", app: .chatGPT)
        let classic = FakeClaudeProcess(app: .chatGPT)
        launcher.runningHandlesToReturn = [classic]

        manager.load()
        XCTAssertFalse(manager.isRunning(id: defaultChatGPT.id))

        manager.stopAll()
        XCTAssertFalse(classic.terminationRequested, "an app that cannot be started must not be stopped either")
    }

    func testDeletingTheLastChatGPTProfileReleasesDefaultChatGPTWithoutQuittingIt() throws {
        let profile = try manager.addProfile(named: "Research", app: .chatGPT)
        let normalChatGPT = FakeClaudeProcess(app: .chatGPT)
        launcher.runningHandlesToReturn = [normalChatGPT]
        manager.load()
        XCTAssertTrue(manager.isRunning(id: defaultChatGPT.id))

        try manager.removeProfile(id: profile.id)
        XCTAssertFalse(manager.isRunning(id: defaultChatGPT.id))
        XCTAssertEqual(manager.runningCount, 0)

        manager.stopAll()
        manager.refreshRunningProcesses()
        XCTAssertFalse(normalChatGPT.terminationRequested, "hiding Default ChatGPT must leave the normal app running")
        XCTAssertFalse(manager.isRunning(id: defaultChatGPT.id), "an unlisted app is not rediscovered")

        // Undo brings the entry back, and discovery adopts the instance again.
        manager.restoreProfiles([profile])
        manager.refreshRunningProcesses()
        XCTAssertTrue(manager.isRunning(id: defaultChatGPT.id))
    }

    // MARK: Persistence

    func testProfilesSavedBeforeChatGPTSupportLoadAsClaude() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","label":"Work","dataDirectory":"/Profiles/work"}]
        """
        let profiles = try JSONDecoder().decode([ClaudeProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles.map(\.app), [.claude])
    }

    func testDefaultChatGPTCannotBeStoredRenamedOrRemoved() {
        let json = """
        [{"id":"\(defaultChatGPT.id.uuidString)","label":"Imported","app":"chatgpt","dataDirectory":"/other"}]
        """
        XCTAssertThrowsError(try JSONDecoder().decode([ClaudeProfile].self, from: Data(json.utf8)))
        XCTAssertThrowsError(try JSONEncoder().encode(defaultChatGPT))
        XCTAssertThrowsError(try manager.renameProfile(id: defaultChatGPT.id, to: "Changed")) {
            XCTAssertEqual($0 as? ProfileManagerError, .builtInProfile)
        }
        XCTAssertThrowsError(try manager.removeProfile(id: defaultChatGPT.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .builtInProfile)
        }
    }

    func testBundleLocationsArePersistedPerApp() {
        manager.setBundlePath("/opt/ChatGPT.app", for: .chatGPT)
        XCTAssertEqual(makeManagerFromDefaults().bundleURL(for: .chatGPT).path, "/opt/ChatGPT.app")
        XCTAssertEqual(makeManagerFromDefaults().bundleURL(for: .claude), ManagedApp.claude.defaultBundleURL)

        manager.resetBundlePath(for: .chatGPT)
        XCTAssertEqual(makeManagerFromDefaults().bundleURL(for: .chatGPT), ManagedApp.chatGPT.defaultBundleURL)
    }

    /// Resolves both app locations from defaults alone, like the real app.
    private func makeManagerFromDefaults() -> ProfileManager {
        ProfileManager(store: manager.store, launcher: launcher, defaults: defaults, dataRootDirectory: root)
    }
}
