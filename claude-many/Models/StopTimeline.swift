import Foundation

/// How long Stop lets an app take to quit before escalating. Each delay
/// counts from the previous step, and a process that exits ends it early:
///
///     quit request (like ⌘Q) ──10 s──▶ SIGTERM ──20 s──▶ SIGKILL ──5 s──▶ give up
///
/// The quit request lets the app save its state. SIGTERM covers an app
/// that missed it, SIGKILL one that hangs, and giving up one that not even
/// SIGKILL ends (stuck in the kernel), so its entry does not stay
/// "Stopping…" forever.
struct StopTimeline: Sendable {
    enum Step: Sendable {
        case quitRequested
        case terminated
        case killed
    }

    var terminateAfter: Duration
    var killAfter: Duration
    var abandonAfter: Duration

    static let standard = StopTimeline(terminateAfter: .seconds(10), killAfter: .seconds(20), abandonAfter: .seconds(5))

    /// The wait before the step that follows `step`.
    func delay(after step: Step) -> Duration {
        switch step {
        case .quitRequested: return terminateAfter
        case .terminated: return killAfter
        case .killed: return abandonAfter
        }
    }
}
