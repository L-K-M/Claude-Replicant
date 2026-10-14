import XCTest
@testable import claude_many

final class ClaudeProcessSnapshotTests: XCTestCase {
    func testLegacyOverrideIsOnlyAReasonToExcludeAmbiguousProcesses() throws {
        let prefix = header(argumentCount: 1) + Array("/Claude\0\0/Claude\0".utf8)
        let legacy = try XCTUnwrap(ClaudeProcessSnapshot(buffer: prefix + Array("CLAUDE_USER_DATA_DIR=/old\0".utf8)))
        let empty = try XCTUnwrap(ClaudeProcessSnapshot(buffer: prefix + Array("CLAUDE_USER_DATA_DIR=\0".utf8)))
        let unrelated = try XCTUnwrap(ClaudeProcessSnapshot(buffer: prefix + Array("OTHER=CLAUDE_USER_DATA_DIR=/old\0".utf8)))
        XCTAssertNil(ClaudeLaunchConfiguration.location(of: legacy, app: .claude))
        XCTAssertEqual(ClaudeLaunchConfiguration.location(of: empty, app: .claude), .standard)
        XCTAssertEqual(ClaudeLaunchConfiguration.location(of: unrelated, app: .claude), .standard)
        XCTAssertEqual(legacy.arguments, ["/Claude"])
        XCTAssertEqual(unrelated.environmentValues(named: "CLAUDE_USER_DATA_DIR"), [])
        XCTAssertEqual(legacy.environmentValues(named: "CLAUDE_USER_DATA_DIR"), ["/old"])
    }

    func testKernelPaddingSpacesAndEmptyArgumentsArePreserved() throws {
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let arguments = [executable, "", "--user-data-dir=/Profiles/Work Account/Ötzi"]
        var buffer = header(argumentCount: Int32(arguments.count))
        buffer += Array(executable.utf8) + [0, 0, 0]
        for argument in arguments { buffer += Array(argument.utf8) + [0] }
        buffer += Array("CLAUDE_USER_DATA_DIR=/legacy".utf8) + [0]

        let snapshot = try XCTUnwrap(ClaudeProcessSnapshot(buffer: buffer))
        XCTAssertEqual(snapshot.executablePath, executable)
        XCTAssertEqual(snapshot.arguments, arguments)
        XCTAssertEqual(ClaudeLaunchConfiguration.dataDirectory(in: snapshot.arguments)?.path,
                       "/Profiles/Work Account/Ötzi")
    }

    func testEnvironmentIsNeverTreatedAsAnArgument() throws {
        let buffer = header(argumentCount: 1) + Array("/Claude\0\0/Claude\0".utf8)
            + Array("CLAUDE_USER_DATA_DIR=/legacy\0--user-data-dir=/not-an-argument\0".utf8)
        let snapshot = try XCTUnwrap(ClaudeProcessSnapshot(buffer: buffer))
        XCTAssertEqual(snapshot.arguments, ["/Claude"])
        XCTAssertNil(ClaudeLaunchConfiguration.dataDirectory(in: snapshot.arguments))
    }

    func testMalformedOrTruncatedSnapshotsAreRejected() {
        let validPrefix = header(argumentCount: 2) + Array("/Claude\0\0/Claude\0".utf8)
        for buffer in [
            [], [0], [0, 0, 0],
            header(argumentCount: 0), header(argumentCount: -1), header(argumentCount: .max),
            header(argumentCount: 1) + Array("/missing-terminator".utf8),
            validPrefix, validPrefix + Array("--user-data-dir=/unterminated".utf8),
            header(argumentCount: 1) + [0xff, 0]
        ] {
            XCTAssertNil(ClaudeProcessSnapshot(buffer: buffer))
        }
    }

    private func header(argumentCount: Int32) -> [UInt8] {
        withUnsafeBytes(of: argumentCount) { Array($0) }
    }
}
