import XCTest
@testable import claude_many

final class ClaudeLaunchConfigurationTests: XCTestCase {
    func testStandardLaunchHasNoDirectoryOverrides() {
        let configuration = ClaudeLaunchConfiguration(location: .standard)
        let inherited = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/example",
            "CLAUDE_USER_DATA_DIR": "/legacy", "CLAUDE_CONFIG_DIR": "/private-code",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/private-keychain"
        ]
        let environment = configuration.environment(inheriting: inherited)

        XCTAssertEqual(configuration.arguments, [])
        XCTAssertNil(configuration.codeConfigurationDirectory)
        XCTAssertNil(environment["CLAUDE_USER_DATA_DIR"])
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        XCTAssertEqual(environment["HOME"], inherited["HOME"])
        XCTAssertEqual(environment["PATH"], inherited["PATH"])
    }

    func testStandardAndAmbiguousDirectoryArgumentsAreDistinct() {
        XCTAssertEqual(ClaudeLaunchConfiguration.location(in: ["/Applications/Claude", "--some-option"]), .standard)
        XCTAssertEqual(ClaudeLaunchConfiguration.location(in: ["--", "--user-data-dir=/ignored"]), .standard)
        for arguments in [["--user-data-dir"], ["--user-data-dir="], ["--user-data-dir=relative"]] {
            XCTAssertNil(ClaudeLaunchConfiguration.location(in: arguments))
        }
        XCTAssertEqual(ClaudeLaunchConfiguration.location(in: ["-user-data-dir=/private"]),
                       .isolated(dataDirectory: URL(fileURLWithPath: "/private", isDirectory: true)))
    }

    func testProfilesKeepSeparateCodeStateAndReplaceInheritedPaths() {
        let work = ClaudeLaunchConfiguration(dataDirectory: URL(fileURLWithPath: "/Profiles/Work Account"))
        let personal = ClaudeLaunchConfiguration(dataDirectory: URL(fileURLWithPath: "/Profiles/Personal"))
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "CLAUDE_USER_DATA_DIR": "/legacy-profile",
            "CLAUDE_CONFIG_DIR": "/shared-code-config",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/shared-keychain-namespace"
        ]

        let environment = work.environment(inheriting: inherited)
        XCTAssertEqual(environment["PATH"], inherited["PATH"])
        XCTAssertNil(environment["CLAUDE_USER_DATA_DIR"])
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/Profiles/Work Account/.claude")
        XCTAssertEqual(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNotEqual(work.codeConfigurationDirectory, personal.codeConfigurationDirectory)
        XCTAssertNotEqual(environment["CLAUDE_CONFIG_DIR"],
                          personal.environment(inheriting: inherited)["CLAUDE_CONFIG_DIR"])
    }

    func testDataDirectoryPreservesSpaces() {
        let path = "/Profiles/Work Account/Ötzi"
        XCTAssertEqual(ClaudeLaunchConfiguration.dataDirectory(in: ["--user-data-dir=\(path)"])?.path, path)
    }

    func testLastDirectorySwitchWins() {
        XCTAssertEqual(ClaudeLaunchConfiguration.dataDirectory(in: [
            "--user-data-dir=/first", "--user-data-dir=/last"
        ])?.path, "/last")
        XCTAssertNil(ClaudeLaunchConfiguration.dataDirectory(in: [
            "--user-data-dir=/first", "--user-data-dir="
        ]))
        XCTAssertNil(ClaudeLaunchConfiguration.dataDirectory(in: [
            "--user-data-dir=/first", "--user-data-dir", "/not-a-switch-value"
        ]))
    }

    func testIgnoresArgumentsAfterTerminator() {
        XCTAssertNil(ClaudeLaunchConfiguration.dataDirectory(in: ["--", "--user-data-dir=/ignored"]))
        XCTAssertEqual(ClaudeLaunchConfiguration.dataDirectory(in: [
            "--user-data-dir=/profile", "--", "--user-data-dir=/ignored"
        ])?.path, "/profile")
    }

    func testMissingRelativeAndUnrelatedPathsAreNotProfiles() {
        for arguments in [
            [], ["--user-data-dir"], ["--user-data-dir="], ["--user-data-dir=relative"],
            ["--user-data-dir", "/not-a-switch-value"],
            ["--user-data-dir", "--other-switch"], ["--user-data-directory=/other"],
            ["CLAUDE_USER_DATA_DIR=/legacy"], ["--title=--user-data-dir=/other"]
        ] {
            XCTAssertNil(ClaudeLaunchConfiguration.dataDirectory(in: arguments), "\(arguments)")
        }
    }

    // MARK: ChatGPT

    func testChatGPTProfilesSelectStorageThroughEnvironmentAndArgv() {
        let configuration = ClaudeLaunchConfiguration(app: .chatGPT,
                                                      dataDirectory: URL(fileURLWithPath: "/Profiles/Work Account"))
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "CODEX_HOME": "/Users/example/.codex",
            "CODEX_ELECTRON_USER_DATA_PATH": "/elsewhere"
        ]
        let environment = configuration.environment(inheriting: inherited)

        XCTAssertEqual(configuration.arguments, ["--user-data-dir=/Profiles/Work Account"])
        XCTAssertEqual(configuration.codeConfigurationDirectory?.path, "/Profiles/Work Account/.codex")
        XCTAssertEqual(environment["CODEX_ELECTRON_USER_DATA_PATH"], "/Profiles/Work Account")
        XCTAssertEqual(environment["CODEX_HOME"], "/Profiles/Work Account/.codex")
        XCTAssertEqual(environment["PATH"], inherited["PATH"])
    }

    func testStandardChatGPTDropsInheritedLocationOverrides() {
        let configuration = ClaudeLaunchConfiguration(app: .chatGPT, location: .standard)
        let environment = configuration.environment(inheriting: [
            "HOME": "/Users/example",
            "CODEX_HOME": "/private-codex",
            "CODEX_ELECTRON_USER_DATA_PATH": "/private-data"
        ])

        XCTAssertEqual(configuration.arguments, [])
        XCTAssertNil(configuration.codeConfigurationDirectory)
        XCTAssertNil(environment["CODEX_HOME"])
        XCTAssertNil(environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertEqual(environment["HOME"], "/Users/example")
    }

    func testChatGPTDiscoveryRequiresEnvironmentAndArgvToAgree() throws {
        let profileSwitch = "--user-data-dir=/Profiles/Work Account"
        let profile = ClaudeInstanceLocation.isolated(
            dataDirectory: URL(fileURLWithPath: "/Profiles/Work Account", isDirectory: true))
        let variable = "CODEX_ELECTRON_USER_DATA_PATH="
        let cases: [(arguments: [String], environment: [String], expected: ClaudeInstanceLocation?)] = [
            ([], [], .standard),
            ([], [variable + "  "], .standard),
            ([profileSwitch], [variable + "/Profiles/Work Account"], profile),
            ([profileSwitch], [variable + " /Profiles/Work Account/ "], profile),
            // Packaged ChatGPT ignores the switch without the variable.
            ([profileSwitch], [], nil),
            ([], [variable + "/Profiles/Work Account"], nil),
            ([profileSwitch], [variable + "/Profiles/Other"], nil),
            ([profileSwitch], [variable + "Work Account"], nil),
            ([profileSwitch], [variable + "/Profiles/Work Account", variable + "/Profiles/Other"], nil)
        ]

        for (arguments, environment, expected) in cases {
            let snapshot = try XCTUnwrap(snapshot(arguments: ["/ChatGPT"] + arguments, environment: environment))
            XCTAssertEqual(ClaudeLaunchConfiguration.location(of: snapshot, app: .chatGPT), expected,
                           "\(arguments) \(environment)")
        }
    }

    /// Lays out a KERN_PROCARGS2 buffer: argc, executable path, padding, argv, environment.
    private func snapshot(arguments: [String], environment: [String]) -> ClaudeProcessSnapshot? {
        var buffer = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        buffer += Array(arguments[0].utf8) + [0, 0]
        for entry in arguments + environment {
            buffer += Array(entry.utf8) + [0]
        }
        return ClaudeProcessSnapshot(buffer: buffer)
    }
}
