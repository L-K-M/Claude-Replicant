import AppKit
import UniformTypeIdentifiers

/// Small AppKit helpers: the app is SwiftUI, but choosing bundles, revealing
/// folders, and copying paths are AppKit services.
enum MacPlatform {
    /// Asks for an .app bundle with a real Open panel, sheeted to the key
    /// window when one exists. Returns nil when the user cancels.
    @MainActor
    static func chooseApplicationBundle(
        named bundleName: String,
        startingAt directory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        completion: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.message = "Choose \(bundleName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = directory
        panel.treatsFilePackagesAsDirectories = false

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// Selects the URLs in Finder. URLs that do not exist yet (a profile that
    /// was never started has no data directory) fall back to the nearest
    /// existing ancestor so the menu item is never dead.
    static func revealInFinder(_ urls: [URL]) {
        let existing = urls.map(existingAncestor(of:))
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    static func revealInFinder(_ url: URL) {
        revealInFinder([url])
    }

    private static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return candidate
    }

    /// The app's Finder icon, or the generic application icon while it is missing.
    static func applicationIcon(at url: URL) -> NSImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func copyPathToPasteboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// `~/Library/...` instead of `/Users/name/Library/...`: shorter and the
    /// way Mac users expect home-relative paths to read.
    static func homeRelativePath(of url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
