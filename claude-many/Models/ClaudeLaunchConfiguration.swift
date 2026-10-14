import Foundation

/// Select an app's normal locations or keep isolated app and CLI state together.
///
///     <profile>/            Electron userData (--user-data-dir)
///     <profile>/.claude/    Claude Code: CLAUDE_CONFIG_DIR, CLAUDE_SECURESTORAGE_CONFIG_DIR
///     <profile>/.codex/     ChatGPT's Codex: CODEX_HOME
struct ClaudeLaunchConfiguration {
    let app: ManagedApp
    let location: ClaudeInstanceLocation

    private static let userDataArguments = ["--user-data-dir", "-user-data-dir"]
    private static let legacyUserDataEnvironment = "CLAUDE_USER_DATA_DIR"
    private static let codeConfigEnvironment = "CLAUDE_CONFIG_DIR"
    private static let secureStorageEnvironment = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    // Packaged ChatGPT overrides --user-data-dir with this variable and honors
    // CODEX_HOME only while it is set.
    private static let chatGPTUserDataEnvironment = "CODEX_ELECTRON_USER_DATA_PATH"
    private static let codexHomeEnvironment = "CODEX_HOME"

    init(app: ManagedApp = .claude, dataDirectory: URL) {
        self.app = app
        location = .isolated(dataDirectory: dataDirectory)
    }

    init(app: ManagedApp = .claude, location: ClaudeInstanceLocation) {
        self.app = app
        self.location = location
    }

    /// The profile's CLI state: Claude Code's `.claude/` or Codex's `.codex/`.
    var codeConfigurationDirectory: URL? {
        let folder: String
        switch app {
        case .claude: folder = ".claude"
        case .chatGPT: folder = ".codex"
        }
        return location.dataDirectory?.appendingPathComponent(folder, isDirectory: true)
    }

    /// ChatGPT reads its storage from the environment; argv repeats it so
    /// discovery can identify the instance for either app.
    var arguments: [String] {
        guard let directory = location.dataDirectory else { return [] }
        return ["\(Self.userDataArguments[0])=\(directory.path)"]
    }

    func environment(inheriting inherited: [String: String]) -> [String: String] {
        var environment = inherited
        for name in Self.locationEnvironment(for: app) {
            environment.removeValue(forKey: name)
        }

        guard let directory = location.dataDirectory, let configuration = codeConfigurationDirectory else {
            return environment
        }

        switch app {
        case .claude:
            environment[Self.codeConfigEnvironment] = configuration.path
            environment[Self.secureStorageEnvironment] = configuration.path
        case .chatGPT:
            environment[Self.chatGPTUserDataEnvironment] = directory.path
            environment[Self.codexHomeEnvironment] = configuration.path
        }
        return environment
    }

    /// Inherited variables that would move storage; standard launches drop them.
    private static func locationEnvironment(for app: ManagedApp) -> [String] {
        switch app {
        case .claude:
            return [legacyUserDataEnvironment, codeConfigEnvironment, secureStorageEnvironment]
        case .chatGPT:
            return [chatGPTUserDataEnvironment, codexHomeEnvironment]
        }
    }

    static func dataDirectory(in arguments: [String]) -> URL? {
        location(in: arguments)?.dataDirectory
    }

    static func location(in arguments: [String]) -> ClaudeInstanceLocation? {
        var path: String?

        // Chromium requires '='; a following argv entry is not a switch value.
        for argument in arguments {
            if argument == "--" { break }

            if userDataArguments.contains(argument) {
                path = ""
                continue
            }

            guard let name = userDataArguments.first(where: { argument.hasPrefix($0 + "=") }) else { continue }
            let prefix = name + "="
            path = String(argument.dropFirst(prefix.count))
        }

        guard let path else { return .standard }
        guard path.hasPrefix("/") else { return nil }
        return .isolated(dataDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Where a running process keeps its data, or nil when argv and the
    /// environment could disagree about it. Ambiguous instances are never
    /// adopted, so Stop cannot signal a process another tool relocated.
    static func location(of snapshot: ClaudeProcessSnapshot, app: ManagedApp) -> ClaudeInstanceLocation? {
        guard let location = location(in: snapshot.arguments) else { return nil }

        switch app {
        case .claude:
            // A legacy hint may belong to an older Claude that relocates
            // storage, so it cannot identify a default instance either.
            let hinted = snapshot.environmentValues(named: legacyUserDataEnvironment).contains { !$0.isEmpty }
            return hinted ? nil : location

        case .chatGPT:
            // ChatGPT trims the variable and treats an empty value as unset.
            let selected = snapshot.environmentValues(named: chatGPTUserDataEnvironment)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let directory = location.dataDirectory else {
                return selected.isEmpty ? .standard : nil
            }

            let expected = directory.standardizedFileURL.path
            let agrees = !selected.isEmpty && selected.allSatisfy {
                $0.hasPrefix("/") && URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path == expected
            }
            return agrees ? location : nil
        }
    }
}
