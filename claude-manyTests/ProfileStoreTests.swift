import XCTest
@testable import claude_many

final class ProfileStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-store-\(UUID().uuidString)", isDirectory: true)
        storeURL = tempDir.appendingPathComponent("profiles.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadMissingFileReturnsEmpty() throws {
        let store = ProfileStore(fileURL: storeURL)
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = tempDir.appendingPathComponent("Profiles/one", isDirectory: true)
        let original = [
            ClaudeProfile(label: "One", dataDirectory: dir),
            ClaudeProfile(label: "Two", dataDirectory: tempDir.appendingPathComponent("Profiles/two", isDirectory: true)),
        ]
        let store = ProfileStore(fileURL: storeURL)
        try store.save(original)

        let loaded = try ProfileStore(fileURL: storeURL).load()
        XCTAssertEqual(loaded, original)
    }

    func testLoadPreservesDataDirectoryPathsExactly() throws {
        let path = "/tmp/custom place/with space/Profiles/工作"
        let profile = ClaudeProfile(label: "Work", dataDirectory: URL(fileURLWithPath: path, isDirectory: true))
        let store = ProfileStore(fileURL: storeURL)
        try store.save([profile])

        let loaded = try ProfileStore(fileURL: storeURL).load()
        XCTAssertEqual(loaded.first?.dataDirectory.path, path)
    }

    func testLoadThrowsOnCorruptData() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: storeURL.path, contents: Data("not json {".utf8))
        let store = ProfileStore(fileURL: storeURL)
        XCTAssertThrowsError(try store.load())
    }

    func testMixedListsLoadStrictlyOrEntryByEntry() throws {
        let readable = ClaudeProfile(label: "Work", dataDirectory: tempDir.appendingPathComponent("work", isDirectory: true))
        let store = ProfileStore(fileURL: storeURL)
        try store.save([readable])
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [Any])
        entries.append(NSNull())
        entries.append(["label": "No id"])
        try JSONSerialization.data(withJSONObject: entries).write(to: storeURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.loadReadable(), ProfileStore.Contents(profiles: [readable], unreadableCount: 2))
    }

    func testAJSONObjectIsNotAProfileList() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data(#"{"label":"Work"}"#.utf8).write(to: storeURL)
        XCTAssertThrowsError(try ProfileStore(fileURL: storeURL).loadReadable())
    }

    func testSetAsideNeverOverwritesAnEarlierCopy() throws {
        let store = ProfileStore(fileURL: storeURL)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        try Data("first".utf8).write(to: storeURL)
        let first = try store.setAsideUnreadableFile(at: moment)
        try Data("second".utf8).write(to: storeURL)
        let second = try store.setAsideUnreadableFile(at: moment)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.json"))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testSaveOverwritesPreviousContents() throws {
        let store = ProfileStore(fileURL: storeURL)
        try store.save([ClaudeProfile(label: "A", dataDirectory: tempDir.appendingPathComponent("a"))])
        try store.save([ClaudeProfile(label: "B", dataDirectory: tempDir.appendingPathComponent("b"))])
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.label), ["B"])
    }
}
