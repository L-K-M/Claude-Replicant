import Foundation

/// What a listed entry's instance is doing, for status and controls.
enum InstanceState: Equatable, Sendable {
    case stopped
    case running
    /// Asked to quit; the old process has not exited yet.
    case stopping
    /// Stopping, and starts again as soon as the old process exits.
    case restarting
}
