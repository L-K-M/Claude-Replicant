import Foundation

/// A profile's identity color, from the Finder tag palette. Stored by name
/// so the palette can be restyled without migrating profiles.json.
enum ProfileColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    var id: Self { self }

    var name: String { rawValue.capitalized }
}
