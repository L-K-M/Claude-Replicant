import Foundation

/// Desktop apps that can run isolated profiles. Each case knows where its app
/// normally lives and which build can isolate storage per instance.
enum ManagedApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case chatGPT = "chatgpt"

    var id: Self { self }

    /// Short name for labels, e.g. "Default ChatGPT".
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        }
    }

    /// Product name for help text.
    var productName: String {
        switch self {
        case .claude: return "Claude Desktop"
        case .chatGPT: return "ChatGPT"
        }
    }

    var bundleName: String { "\(name).app" }

    var newProfileTitle: String { "New \(name) Profile" }

    var defaultBundleURL: URL {
        URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
    }

    /// Main executable inside the bundle. Helper processes live elsewhere.
    var executablePath: String {
        switch self {
        case .claude: return "Contents/MacOS/Claude"
        case .chatGPT: return "Contents/MacOS/ChatGPT"
        }
    }

    /// UserDefaults key for a relocated bundle. Claude keeps its original key.
    var bundlePathDefaultsKey: String {
        switch self {
        case .claude: return "claudeBundlePath"
        case .chatGPT: return "chatGPTBundlePath"
        }
    }

    /// ChatGPT Classic (com.openai.chat) uses the same executable name but
    /// shares one keychain login per Mac user. Only the Electron ChatGPT app
    /// (com.openai.codex) can relocate its storage.
    private var requiredBundleIdentifier: String? {
        switch self {
        case .claude: return nil
        case .chatGPT: return "com.openai.codex"
        }
    }

    /// Default Claude predates ChatGPT support and is always listed. Default
    /// ChatGPT appears with the first ChatGPT profile, so an installed
    /// ChatGPT is never added to Start All on its own.
    var listsDefaultWithoutProfiles: Bool { self == .claude }

    /// The app's normal data folder: shown and revealed, never written.
    var standardDataDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        switch self {
        case .claude:
            return applicationSupport.appendingPathComponent("Claude", isDirectory: true)
        case .chatGPT:
            // The ChatGPT app grew out of Codex and keeps its folder name.
            return applicationSupport.appendingPathComponent("Codex", isDirectory: true)
        }
    }

    func bundleStatus(at bundle: URL) -> AppBundleStatus {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return .missing }
        guard let requiredBundleIdentifier else { return .available }

        // Read Info.plist directly: Bundle(url:) caches and would miss an app
        // replaced in place, such as Classic upgraded to the current ChatGPT.
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == requiredBundleIdentifier else {
            return .unsupported
        }
        return .available
    }
}

enum AppBundleStatus: Equatable, Sendable {
    case available
    case missing
    /// Installed, but a build that cannot isolate profiles (ChatGPT Classic).
    case unsupported
}
