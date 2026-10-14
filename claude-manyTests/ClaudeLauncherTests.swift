import XCTest
@testable import claude_many

@MainActor
final class ClaudeLauncherTests: XCTestCase {
    func testStartPassesIsolatedDesktopAndCodePathsToTheProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (bundle, executable) = try makeRecordingExecutable(root: root)

        let manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: RealClaudeLauncher(),
            claudeBundleURL: bundle,
            dataRootDirectory: root.appendingPathComponent("Profiles With Spaces")
        )
        defer { manager.stopAll() }

        let profile = try manager.addProfile(named: "Work")
        try manager.start(id: profile.id)

        try await waitForRecording(executable: executable)

        let codeDirectory = profile.dataDirectory.appendingPathComponent(".claude", isDirectory: true)
        XCTAssertEqual(try output("arguments", executable: executable),
                       "--user-data-dir=\(profile.dataDirectory.path)\n")
        XCTAssertEqual(try output("code-config", executable: executable), codeDirectory.path)
        XCTAssertEqual(try output("secure-storage", executable: executable), codeDirectory.path)
        XCTAssertEqual(try output("legacy-data", executable: executable), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codeDirectory.path))
    }

    func testStandardStartUsesNoDirectoryOverridesOrPrivateFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-normal-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bundle, executable) = try makeRecordingExecutable(root: root)
        let manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: RealClaudeLauncher(),
            claudeBundleURL: bundle,
            dataRootDirectory: root.appendingPathComponent("Profiles")
        )
        defer { manager.stopAll() }

        try manager.start(id: ClaudeProfile.standard.id)
        try await waitForRecording(executable: executable)
        XCTAssertEqual(try output("arguments", executable: executable), "\n")
        XCTAssertEqual(try output("code-config", executable: executable), "")
        XCTAssertEqual(try output("secure-storage", executable: executable), "")
        XCTAssertEqual(try output("legacy-data", executable: executable), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.dataRootDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.store.fileURL.path))
    }

    func testDiscoveryAndStopIgnoreLegacyEnvironmentOnlyProcesses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-many-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = try makeWaitingExecutable(named: "Claude", root: root)

        let directory = root.appendingPathComponent("Work Account", isDirectory: true)
        let isolated = Process()
        isolated.executableURL = executable
        isolated.arguments = ["--user-data-dir=\(directory.path)"]
        isolated.environment = [:]
        let other = Process()
        other.executableURL = executable
        other.arguments = ["--user-data-dir=\(root.appendingPathComponent("Personal").path)"]
        other.environment = [:]
        let legacy = Process()
        legacy.executableURL = executable
        legacy.environment = ["CLAUDE_USER_DATA_DIR": directory.path]
        let standard = Process()
        standard.executableURL = executable
        standard.environment = [:]
        defer {
            for process in [isolated, other, legacy, standard] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        try isolated.run()
        try other.run()
        try legacy.run()
        try standard.run()
        let handles = RealClaudeLauncher().runningHandles(app: .claude, executable: executable)
        XCTAssertEqual(Set(handles.map(\.processIdentifier)),
                       [isolated.processIdentifier, other.processIdentifier, standard.processIdentifier])
        let standardHandle = handles.first { $0.processIdentifier == standard.processIdentifier }
        XCTAssertNotNil(standardHandle, "the ordinary Claude instance must be visible without a directory override")
        XCTAssertNil(standardHandle?.dataDirectory)
        let workHandle = try XCTUnwrap(handles.first { $0.processIdentifier == isolated.processIdentifier })
        XCTAssertEqual(workHandle.dataDirectory?.path, directory.path)

        workHandle.terminate()
        isolated.waitUntilExit()
        XCTAssertFalse(workHandle.isRunning)
        XCTAssertTrue(other.isRunning, "stopping an adopted profile must leave other profiles alive")
        XCTAssertTrue(legacy.isRunning, "legacy env-only instances must not be adopted or stopped")
        XCTAssertTrue(standard.isRunning, "stopping an isolated profile must leave the default instance alive")

        let defaultHandle = try XCTUnwrap(standardHandle)
        defaultHandle.terminate()
        standard.waitUntilExit()
        XCTAssertFalse(defaultHandle.isRunning)
        XCTAssertTrue(other.isRunning, "stopping default Claude must not stop an isolated instance")
        XCTAssertTrue(legacy.isRunning, "stopping default Claude must not signal ambiguous legacy instances")
    }

    func testChatGPTStartPassesIsolatedStorageThroughEnvironmentAndArgv() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-chatgpt-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bundle, executable) = try makeChatGPTRecordingExecutable(root: root)
        let manager = ProfileManager(
            store: ProfileStore(fileURL: root.appendingPathComponent("profiles.json")),
            launcher: RealClaudeLauncher(),
            // Default Claude is always scanned; a scratch path keeps stopAll
            // away from a Claude Desktop the developer is running.
            claudeBundleURL: root.appendingPathComponent("Claude.app"),
            chatGPTBundleURL: bundle,
            dataRootDirectory: root.appendingPathComponent("Profiles With Spaces")
        )
        defer { manager.stopAll() }

        let profile = try manager.addProfile(named: "Research", app: .chatGPT)
        try manager.start(id: profile.id)
        try await waitForRecording(executable: executable)

        let codexHome = profile.dataDirectory.appendingPathComponent(".codex", isDirectory: true)
        XCTAssertEqual(try output("arguments", executable: executable),
                       "--user-data-dir=\(profile.dataDirectory.path)\n")
        XCTAssertEqual(try output("user-data", executable: executable), profile.dataDirectory.path)
        XCTAssertEqual(try output("codex-home", executable: executable), codexHome.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.path), "Codex refuses a missing CODEX_HOME")

        try FileManager.default.removeItem(at: URL(fileURLWithPath: executable.path + ".ready"))
        try manager.start(id: ClaudeProfile.builtIn(for: .chatGPT).id)
        try await waitForRecording(executable: executable)
        XCTAssertEqual(try output("arguments", executable: executable), "\n")
        XCTAssertEqual(try output("user-data", executable: executable), "")
        XCTAssertEqual(try output("codex-home", executable: executable), "")
    }

    func testChatGPTDiscoveryAdoptsOnlyInstancesWhoseEnvironmentMatchesArgv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-replicant-chatgpt-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeWaitingExecutable(named: "ChatGPT", root: root)
        let directory = root.appendingPathComponent("Research Account", isDirectory: true)

        func makeProcess(arguments: [String], userData: String?) -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = userData.map { ["CODEX_ELECTRON_USER_DATA_PATH": $0] } ?? [:]
            return process
        }
        let isolated = makeProcess(arguments: ["--user-data-dir=\(directory.path)"], userData: directory.path)
        let argvOnly = makeProcess(arguments: ["--user-data-dir=\(root.appendingPathComponent("Other").path)"], userData: nil)
        let environmentOnly = makeProcess(arguments: [], userData: directory.path)
        let standard = makeProcess(arguments: [], userData: nil)
        let all = [isolated, argvOnly, environmentOnly, standard]
        defer {
            for process in all where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        for process in all {
            try process.run()
        }

        let handles = RealClaudeLauncher().runningHandles(app: .chatGPT, executable: executable)
        XCTAssertEqual(Set(handles.map(\.processIdentifier)),
                       [isolated.processIdentifier, standard.processIdentifier])
        let isolatedHandle = try XCTUnwrap(handles.first { $0.processIdentifier == isolated.processIdentifier })
        XCTAssertEqual(isolatedHandle.dataDirectory?.path, directory.path)
        XCTAssertNil(handles.first { $0.processIdentifier == standard.processIdentifier }?.dataDirectory)

        isolatedHandle.terminate()
        isolated.waitUntilExit()
        XCTAssertTrue(argvOnly.isRunning, "an instance ChatGPT may have relocated elsewhere must not be stopped")
        XCTAssertTrue(environmentOnly.isRunning, "an environment-only instance must not be stopped")
        XCTAssertTrue(standard.isRunning, "stopping a profile must leave the normal ChatGPT running")
    }

    /// Use a native executable so the kernel reports its path, not a shell interpreter's.
    private func makeWaitingExecutable(named name: String, root: URL) throws -> URL {
        let source = root.appendingPathComponent("wait.c")
        let executable = root.appendingPathComponent(name)
        try Data("#include <unistd.h>\nint main(void) { alarm(30); for (;;) pause(); }\n".utf8).write(to: source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        return executable
    }

    /// A ChatGPT bundle whose executable records its storage selection.
    private func makeChatGPTRecordingExecutable(root: URL) throws -> (URL, URL) {
        let bundle = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/ChatGPT")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.openai.codex"],
                                                      format: .xml, options: 0)
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$0.arguments"
        printf '%s' "${CODEX_ELECTRON_USER_DATA_PATH-}" > "$0.user-data"
        printf '%s' "${CODEX_HOME-}" > "$0.codex-home"
        : > "$0.ready"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (bundle, executable)
    }

    private func makeRecordingExecutable(root: URL) throws -> (URL, URL) {
        let bundle = root.appendingPathComponent("Claude.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Claude")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Record the real subprocess boundary without opening Claude or writing its normal data.
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$0.arguments"
        printf '%s' "${CLAUDE_CONFIG_DIR-}" > "$0.code-config"
        printf '%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR-}" > "$0.secure-storage"
        printf '%s' "${CLAUDE_USER_DATA_DIR-}" > "$0.legacy-data"
        : > "$0.ready"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (bundle, executable)
    }

    private func waitForRecording(executable: URL) async throws {
        let ready = URL(fileURLWithPath: executable.path + ".ready")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
    }

    private func output(_ name: String, executable: URL) throws -> String {
        try String(contentsOfFile: executable.path + "." + name, encoding: .utf8)
    }
}
