import Foundation

/// A folder under the profiles root that no listed profile uses: a deleted
/// profile's data, or every profile's after the list itself was lost. It
/// still holds that account's sign-in and history.
struct UnlistedProfileData: Identifiable, Equatable, Sendable {
    let directory: URL
    /// Recognized by the app's Code configuration folder inside
    /// (`.codex` for ChatGPT); Claude otherwise.
    let app: ManagedApp
    let modified: Date?

    var id: URL { directory }

    /// A name for the restored profile from the folder's: "work-2" becomes
    /// "Work 2".
    var suggestedLabel: String {
        let label = directory.lastPathComponent
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? Self.fallbackLabel : label
    }

    private static let fallbackLabel = "Restored Profile"
}

/// Moves items to the Trash, returning where they went. Injected so tests
/// never touch the real Trash.
struct FileTrash: Sendable {
    let moveToTrash: @Sendable (URL) throws -> URL

    init(_ moveToTrash: @escaping @Sendable (URL) throws -> URL) {
        self.moveToTrash = moveToTrash
    }

    static let system = FileTrash { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }
}
