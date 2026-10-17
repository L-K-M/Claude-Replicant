import XCTest
import AppKit
@testable import claude_many

/// The bridge recognizes the Profiles menu's items by their titles, not
/// their positions, and its enabled states must stick: AppKit ignores
/// `isEnabled` while a menu auto-enables its items.
@MainActor
final class ProfilesMenuBridgeTests: XCTestCase {
    /// nil adds a separator.
    private func makeMenu(_ items: [ProfilesMenu.Item?]) -> NSMenu {
        let menu = NSMenu(title: ProfilesMenu.title)
        for item in items {
            menu.addItem(item.map { NSMenuItem(title: $0.title, action: nil, keyEquivalent: "") } ?? .separator())
        }
        return menu
    }

    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title }, "no item titled \(title)")
    }

    func testItemsFollowTheContextWhateverTheirOrder() throws {
        let menu = makeMenu([.stopAll, nil, .rename, .open, .delete])
        var context = ProfileCommandContext()
        context.canOpen = true
        context.openTitle = "Open “Work”"
        context.canDelete = true
        context.deleteTitle = "Delete “Work”…"

        ProfilesMenuBridge().sync(menu, with: context)

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertTrue(try item("Open “Work”", in: menu).isEnabled)
        XCTAssertTrue(try item("Delete “Work”…", in: menu).isEnabled)
        XCTAssertFalse(try item(ProfilesMenu.Item.rename.title, in: menu).isEnabled)
        XCTAssertFalse(try item(ProfilesMenu.Item.stopAll.title, in: menu).isEnabled)
    }

    func testRetitledItemsAreStillRecognized() throws {
        let menu = makeMenu([.open])
        let bridge = ProfilesMenuBridge()
        var context = ProfileCommandContext()
        context.canOpen = true
        context.openTitle = "Open “Work”"
        bridge.sync(menu, with: context)

        context.canOpen = false
        context.openTitle = "Open 0 Profiles"
        bridge.sync(menu, with: context)

        XCTAssertEqual(menu.items[0].title, "Open 0 Profiles")
        XCTAssertFalse(menu.items[0].isEnabled)
    }

    func testItemsTheBridgeDoesNotKnowAreLeftAlone() throws {
        let menu = makeMenu([.open])
        menu.addItem(NSMenuItem(title: "Something Else", action: nil, keyEquivalent: ""))

        ProfilesMenuBridge().sync(menu, with: ProfileCommandContext())

        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(try item("Something Else", in: menu).isEnabled)
    }
}
