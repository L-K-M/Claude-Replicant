import XCTest
@testable import claude_many

@MainActor
final class ProfileIdentityTests: XCTestCase {
    private var root: URL!
    private var manager: ProfileManager!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-identity-\(UUID().uuidString)", isDirectory: true)
        manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: FakeClaudeLauncher(),
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMonogramsUseTheFirstLettersOfTheFirstTwoWords() {
        func monogram(_ label: String) -> String {
            ClaudeProfile(label: label, dataDirectory: root).monogram
        }
        XCTAssertEqual(monogram("Work"), "W")
        XCTAssertEqual(monogram("personal account"), "PA")
        XCTAssertEqual(monogram("  Client   Alpha Beta "), "CA")
        XCTAssertEqual(monogram("🏢 Office"), "🏢O")
        XCTAssertEqual(monogram("ärger"), "Ä")
    }

    func testAutomaticColorsAreStableAndAChosenColorPersists() throws {
        let profile = try manager.addProfile(named: "Work")
        XCTAssertNil(profile.color)
        let reloaded = try XCTUnwrap(try manager.store.load().first)
        XCTAssertEqual(reloaded.displayColor, profile.displayColor, "the automatic color must not change between launches")

        try manager.setColor(.purple, forProfile: profile.id)
        XCTAssertEqual(manager.profiles.first?.displayColor, .purple)
        XCTAssertEqual(try manager.store.load().first?.color, .purple)

        try manager.setColor(nil, forProfile: profile.id)
        XCTAssertNil(try manager.store.load().first?.color)
    }

    func testAutomaticColorsSpreadAcrossThePalette() {
        let colors = (0..<64).map { _ in ClaudeProfile(label: "P", dataDirectory: root).displayColor }
        XCTAssertGreaterThan(Set(colors).count, ProfileColor.allCases.count / 2)
    }

    func testProfilesSavedWithoutAColorLoad() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","label":"Work","app":"claude","dataDirectory":"/Profiles/work"}]
        """
        let profiles = try JSONDecoder().decode([ClaudeProfile].self, from: Data(json.utf8))
        XCTAssertEqual(profiles.map(\.color), [nil])
    }

    func testDefaultEntriesHaveNoEditableColor() {
        XCTAssertThrowsError(try manager.setColor(.red, forProfile: ClaudeProfile.standard.id)) {
            XCTAssertEqual($0 as? ProfileManagerError, .builtInProfile)
        }
    }
}
