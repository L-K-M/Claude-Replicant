import Foundation

/// Persists the profile list as a small JSON file. This is the only thing
/// claude-many stores about profiles; all real account data lives in each
/// profile's private data directory and is created by Claude at runtime.
struct ProfileStore: Sendable {
    let fileURL: URL

    /// The decodable profiles, and how many stored entries were not.
    struct Contents: Equatable, Sendable {
        var profiles: [ClaudeProfile] = []
        var unreadableCount = 0
    }

    private static let unreadablePrefix = "profiles-unreadable-"

    /// Whether the original stays in place after it is set aside.
    enum SetAside {
        /// Nothing will be written over it: start the next launch clean.
        case move
        /// It is about to be rewritten; keep it until the atomic save
        /// replaces it, so a failed save loses nothing.
        case copy
    }

    /// Returns the stored profiles, or an empty list when no file exists yet.
    /// Throws when any entry cannot be decoded.
    func load() throws -> [ClaudeProfile] {
        let contents = try loadReadable()
        guard contents.unreadableCount == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "\(contents.unreadableCount) stored profiles cannot be decoded."))
        }
        return contents.profiles
    }

    /// Decodes entry by entry, so one unknown entry (say, from a newer
    /// version) does not hide the rest. Throws only when the file is not a
    /// JSON array at all.
    func loadReadable() throws -> Contents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Contents() }
        let data = try Data(contentsOf: fileURL)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let profiles = entries.compactMap(\.profile)
        return Contents(profiles: profiles, unreadableCount: entries.count - profiles.count)
    }

    func save(_ profiles: [ClaudeProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Keeps a list that could not be fully decoded next to itself, e.g.
    /// `profiles-unreadable-20261017-085100.json`, so the next save cannot
    /// overwrite the only copy. Returns the kept copy's location.
    func setAsideUnreadableFile(_ method: SetAside = .move, at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = Self.unreadablePrefix + formatter.string(from: date)
        let directory = fileURL.deletingLastPathComponent()

        var destination = directory.appendingPathComponent(base + ".json")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(counter).json")
            counter += 1
        }
        switch method {
        case .move: try FileManager.default.moveItem(at: fileURL, to: destination)
        case .copy: try FileManager.default.copyItem(at: fileURL, to: destination)
        }
        return destination
    }

    /// One array element; nil when it does not decode as a profile.
    private struct Entry: Decodable {
        let profile: ClaudeProfile?

        init(from decoder: Decoder) throws {
            profile = try? ClaudeProfile(from: decoder)
        }
    }
}
