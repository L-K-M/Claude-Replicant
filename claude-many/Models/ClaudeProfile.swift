import Foundation

/// A list entry for an app's standard instance or an isolated account. Only isolated entries are stored.
struct ClaudeProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var label: String
    let app: ManagedApp
    private(set) var location: ClaudeInstanceLocation

    static let standard = builtIn(for: .claude)

    /// The pinned "Default <app>" entry for the app's normal instance.
    static func builtIn(for app: ManagedApp) -> ClaudeProfile {
        ClaudeProfile(id: builtInID(for: app), label: "Default \(app.name)", app: app, location: .standard)
    }

    static func isBuiltIn(id: UUID) -> Bool {
        ManagedApp.allCases.contains { builtInID(for: $0) == id }
    }

    // Reserved v5 identities for the built-in entries; user-created profiles use random v4 IDs.
    private static func builtInID(for app: ManagedApp) -> UUID {
        switch app {
        case .claude: return UUID(uuidString: "3C95B705-75C5-53EA-9A4D-1413412D918E")!
        case .chatGPT: return UUID(uuidString: "ED86D2BB-5616-5717-ADA6-5D7186C2531C")!
        }
    }

    var isDefault: Bool { location == .standard }

    /// The standard path is display metadata, never a directory the manager creates or copies.
    var dataDirectory: URL {
        location.dataDirectory ?? app.standardDataDirectory
    }

    init(id: UUID = UUID(), label: String, app: ManagedApp = .claude, dataDirectory: URL) {
        self.id = id
        self.label = label
        self.app = app
        location = .isolated(dataDirectory: dataDirectory)
    }

    /// The same profile, everything else unchanged, with its data in `directory`.
    func withDataDirectory(_ directory: URL) -> ClaudeProfile {
        var profile = self
        profile.location = .isolated(dataDirectory: directory)
        return profile
    }

    private init(id: UUID, label: String, app: ManagedApp, location: ClaudeInstanceLocation) {
        self.id = id
        self.label = label
        self.app = app
        self.location = location
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case app
        case dataDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        guard !Self.isBuiltIn(id: id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container,
                                                  debugDescription: "A built-in default entry cannot be stored as an isolated profile.")
        }
        label = try container.decode(String.self, forKey: .label)
        // Profiles saved before ChatGPT support have no app and are Claude profiles.
        app = try container.decodeIfPresent(ManagedApp.self, forKey: .app) ?? .claude
        let path = try container.decode(String.self, forKey: .dataDirectory)
        location = .isolated(dataDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    func encode(to encoder: Encoder) throws {
        guard !isDefault else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                        debugDescription: "Built-in default entries are not persisted."))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(app, forKey: .app)
        try container.encode(dataDirectory.path, forKey: .dataDirectory)
    }
}
