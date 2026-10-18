import XCTest
@testable import claude_many

/// Folders under the profiles root that no profile uses (a deleted
/// profile's, or every profile's after the list was lost) can be listed
/// again or moved to the Trash, never deleted outright.
@MainActor
final class UnlistedDataTests: XCTestCase {
    private var root: URL!
    private var trash: URL!
    private var defaultsSuiteName: String!
    private var launcher: FakeClaudeLauncher!
    private var manager: ProfileManager!

    private var profilesRoot: URL { root.appendingPathComponent("Profiles", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-unlisted-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try TestBundle.make(at: root.appendingPathComponent("Claude.app", isDirectory: true))
        defaultsSuiteName = "claude-replicant-unlisted-tests-\(UUID().uuidString)"
        launcher = FakeClaudeLauncher()
        manager = makeManager()
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager() -> ProfileManager {
        let trash = trash!
        return ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: launcher,
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!,
            dataRootDirectory: profilesRoot,
            trash: FileTrash { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        )
    }

    private func makeFolder(_ name: String, containing marker: String? = nil) throws -> URL {
        let folder = profilesRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let marker {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(marker, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        return folder
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Listing

    func testADeletedProfilesFolderCanBeListedAgain() async throws {
        let work = try manager.addProfile(named: "Work Account")
        try manager.start(id: work.id)
        manager.stop(id: work.id)
        launcher.launchedHandles.last?.simulateExit()
        await drainMainQueue()
        try manager.removeProfile(id: work.id)

        let unlisted = try XCTUnwrap(manager.unlistedData.first)
        XCTAssertEqual(manager.unlistedData.count, 1)
        XCTAssertEqual(unlisted.directory.lastPathComponent, work.dataDirectory.lastPathComponent)
        XCTAssertEqual(unlisted.app, .claude)
        XCTAssertEqual(unlisted.suggestedLabel, "Work Account")

        let restored = try manager.restoreUnlistedData(at: unlisted.directory)
        XCTAssertEqual(restored.label, "Work Account")
        XCTAssertEqual(restored.app, .claude)
        XCTAssertEqual(restored.dataDirectory.standardizedFileURL, unlisted.directory.standardizedFileURL,
                       "the folder is used as is, so the login comes back")
        XCTAssertEqual(try manager.store.load(), manager.profiles)
        XCTAssertEqual(manager.unlistedData, [])
    }

    func testTheAppIsRecognizedFromItsConfigurationFolder() throws {
        _ = try makeFolder("research", containing: ".codex")
        _ = try makeFolder("work", containing: ".claude")
        _ = try makeFolder("empty")

        manager.load()

        let apps = Dictionary(uniqueKeysWithValues: manager.unlistedData.map { ($0.directory.lastPathComponent, $0.app) })
        XCTAssertEqual(apps, ["research": .chatGPT, "work": .claude, "empty": .claude])
    }

    func testFoldersInUseFilesAndHiddenFoldersAreNotListed() throws {
        let work = try manager.addProfile(named: "Work")
        try manager.start(id: work.id)
        _ = try makeFolder(".hidden")
        try Data("x".utf8).write(to: profilesRoot.appendingPathComponent("notes.txt"))
        // The same folder on a case-insensitive volume, so it is kept out.
        let loud = try manager.addProfile(named: "Loud")
        _ = try makeFolder(loud.dataDirectory.lastPathComponent.uppercased())

        manager.load()

        XCTAssertEqual(manager.unlistedData, [])
    }

    func testAFolderStaysOffTheListWhileAnInstanceStillQuitsInIt() async throws {
        let work = try manager.addProfile(named: "Work")
        try manager.start(id: work.id)
        let process = try XCTUnwrap(launcher.launchedHandles.last)
        launcher.runningHandlesToReturn = [process]
        try manager.removeProfile(id: work.id)
        XCTAssertEqual(manager.unlistedData, [], "the deleted profile's instance is still quitting")

        launcher.runningHandlesToReturn = []
        process.simulateExit()
        await drainMainQueue()
        XCTAssertEqual(manager.unlistedData.map(\.directory.lastPathComponent), [work.dataDirectory.lastPathComponent])
    }

    func testFoldersStayRestorableWhenTheListCannotBeRead() throws {
        let folder = try makeFolder("work", containing: ".claude")
        try Data("not json".utf8).write(to: manager.store.fileURL)

        manager.load()
        XCTAssertNotNil(manager.lastError, "the unreadable list is reported and set aside")
        XCTAssertEqual(manager.unlistedData.map(\.directory.lastPathComponent), ["work"])

        let restored = try manager.restoreUnlistedData(at: folder)
        XCTAssertEqual(manager.profiles, [restored])
    }

    // MARK: Restore

    func testRestoreIsRefusedWhileTheListCannotBeSaved() throws {
        let folder = try makeFolder("work")
        try FileManager.default.createDirectory(at: manager.store.fileURL, withIntermediateDirectories: true)
        manager.load()

        XCTAssertThrowsError(try manager.restoreUnlistedData(at: folder))
        XCTAssertEqual(manager.profiles, [])
    }

    func testNothingIsOfferedWhileTheListCannotBeOpened() throws {
        // A profile's folder, but the list naming it cannot be read now.
        let folder = try makeFolder("work", containing: ".claude")
        try FileManager.default.createDirectory(at: manager.store.fileURL, withIntermediateDirectories: true)
        manager.load()

        XCTAssertEqual(manager.unlistedData, [], "which folders are used is unknown")
        XCTAssertThrowsError(try manager.trashUnlistedData(at: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFoldersAnUntrackedInstanceRunsInAreOfferedOnceItQuits() throws {
        // Left running by a profile deleted before Claude Replicant relaunched.
        let folder = try makeFolder("work")
        launcher.runningHandlesToReturn = [FakeClaudeProcess(dataDirectory: folder)]

        manager.load()
        XCTAssertEqual(manager.unlistedData, [])

        launcher.runningHandlesToReturn = []
        manager.refreshRunningProcesses()
        XCTAssertEqual(manager.unlistedData.map(\.directory.lastPathComponent), ["work"])
    }

    func testFoldersNamedOnlyWithSeparatorsGetAName() throws {
        _ = try makeFolder("---")
        _ = try makeFolder(" -")
        manager.load()

        XCTAssertEqual(manager.unlistedData.map(\.suggestedLabel), ["Restored Profile", "Restored Profile"])
    }

    func testRestoringAFolderAnInstanceStartedInSaysItIsInUse() throws {
        let folder = try makeFolder("work")
        manager.load()
        // Started outside Claude Replicant after the list was scanned.
        launcher.runningHandlesToReturn = [FakeClaudeProcess(dataDirectory: folder)]

        XCTAssertThrowsError(try manager.restoreUnlistedData(at: folder)) {
            XCTAssertEqual($0 as? ProfileManagerError, .dataInUse(name: "work"))
        }
    }

    func testAFailedSaveLeavesTheFolderUnlisted() throws {
        let folder = try makeFolder("work")
        manager.load()
        // The list's folder becomes read-only, so saving fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try manager.restoreUnlistedData(at: folder))

        XCTAssertEqual(manager.profiles, [])
        XCTAssertEqual(manager.unlistedData.map(\.directory.lastPathComponent), ["work"])
    }

    func testAFolderTheSavedListStillNamesIsNeverOffered() async throws {
        let work = try manager.addProfile(named: "Work")
        try manager.start(id: work.id)
        manager.stop(id: work.id)
        launcher.launchedHandles.last?.simulateExit()
        await drainMainQueue()
        // Deleting fails to save, so profiles.json still lists Work.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        XCTAssertThrowsError(try manager.removeProfile(id: work.id))

        XCTAssertEqual(manager.unlistedData, [], "trashing it would strand the profile on disk")
    }

    func testOnlyUnlistedFoldersCanBeRestored() throws {
        let work = try manager.addProfile(named: "Work")
        try manager.start(id: work.id)

        XCTAssertThrowsError(try manager.restoreUnlistedData(at: work.dataDirectory)) {
            XCTAssertEqual($0 as? ProfileManagerError, .unlistedDataUnavailable)
        }
        XCTAssertEqual(manager.profiles.count, 1, "never two profiles in one folder")
    }

    // MARK: Trash

    func testTrashMovesTheFolderAwayAndPutBackReturnsIt() throws {
        let folder = try makeFolder("work", containing: ".claude")
        manager.load()

        let trashed = try manager.trashUnlistedData(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(manager.unlistedData, [])

        try manager.putBackTrashedData(from: trashed, to: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude").path))
        XCTAssertEqual(manager.unlistedData.map(\.directory.lastPathComponent), ["work"])
    }

    func testTrashIsRefusedWhileAnInstanceRunsInTheFolder() throws {
        let folder = try makeFolder("work")
        launcher.runningHandlesToReturn = [FakeClaudeProcess(dataDirectory: folder)]
        manager.load()

        XCTAssertThrowsError(try manager.trashUnlistedData(at: folder)) {
            XCTAssertEqual($0 as? ProfileManagerError, .dataInUse(name: "work"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testListedFoldersAreNeverTrashed() throws {
        let work = try manager.addProfile(named: "Work")
        try manager.start(id: work.id)
        manager.stop(id: work.id)

        XCTAssertThrowsError(try manager.trashUnlistedData(at: work.dataDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.dataDirectory.path))
    }
}
