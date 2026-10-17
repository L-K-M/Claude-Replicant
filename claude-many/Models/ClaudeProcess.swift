import Foundation
import Darwin
import AppKit

/// Handle to a running Claude instance, abstracted behind a protocol so unit
/// tests can verify state transitions without launching the real app.
protocol ClaudeProcessHandle: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// The argv-selected isolated directory, or nil for a known standard instance.
    var dataDirectory: URL? { get }
    /// Called (on an arbitrary queue) when the process exits on its own.
    var terminationHandler: (@Sendable () -> Void)? { get set }
    /// Ask the process to exit cleanly (SIGTERM).
    func terminate()
    /// Kill the process outright (SIGKILL).
    func terminateForcefully()
}

extension ClaudeProcessHandle {
    var location: ClaudeInstanceLocation {
        guard let dataDirectory else { return .standard }
        return .isolated(dataDirectory: dataDirectory)
    }
}

/// Spawns `Process` instances. Injected into `ProfileManager`; tests replace
/// this with a fake that records launches.
protocol ClaudeLauncher: Sendable {
    func launch(app: ManagedApp, executable: URL, location: ClaudeInstanceLocation) throws -> ClaudeProcessHandle
    /// Current-user standard and isolated instances of `app` running `executable`.
    func runningHandles(app: ManagedApp, executable: URL) -> [ClaudeProcessHandle]
    /// Brings the process's windows to the front (double-click "Open").
    func activate(handle: ClaudeProcessHandle)
}

/// Real launcher backed by Foundation's `Process`.
struct RealClaudeLauncher: ClaudeLauncher {
    func launch(app: ManagedApp, executable: URL, location: ClaudeInstanceLocation) throws -> ClaudeProcessHandle {
        let configuration = ClaudeLaunchConfiguration(app: app, location: location)
        if let directory = configuration.codeConfigurationDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment(inheriting: ProcessInfo.processInfo.environment)

        // Claude's output is not ours; keep it off the console.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        return RealClaudeProcess(
            process: process,
            dataDirectory: location.dataDirectory
        )
    }

    /// Ambiguous launches are excluded; see `ClaudeLaunchConfiguration.location(of:app:)`.
    func runningHandles(app: ManagedApp, executable: URL) -> [ClaudeProcessHandle] {
        let target = executable.resolvingSymlinksInPath().path
        let commandName = Self.commandName(forExecutable: target)
        var result: [ClaudeProcessHandle] = []
        for (pid, startTime, command) in Self.allProcesses() {
            // Runs every 2 s on the main actor: the kernel's command name rules
            // out nearly every process without a syscall, and only the few
            // candidates get their path, argv, and environment read.
            guard command == commandName else { continue }
            if let path = Self.executablePath(for: pid), !Self.executableMatches(path, target: target) {
                continue
            }
            guard let info = Self.processInfo(for: pid),
                   Self.executableMatches(info.executablePath, target: target),
                  let location = ClaudeLaunchConfiguration.location(of: info, app: app) else {
                continue
            }
            result.append(AttachedClaudeProcess(
                pid: pid,
                startTime: startTime,
                dataDirectory: location.dataDirectory
            ))
        }
        return result
    }

    func activate(handle: ClaudeProcessHandle) {
        NSRunningApplication(processIdentifier: pid_t(handle.processIdentifier))?
            .activate(options: [])
    }

    // MARK: Process introspection

    private static let processTableReadAttempts = 3
    // libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN; Swift does not import that macro.
    private static let processPathBufferCapacity = 4 * Int(MAXPATHLEN)

    private static func executablePath(for pid: Int32) -> String? {
        let capacity = UInt32(Self.processPathBufferCapacity)
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let length = proc_pidpath(pid, &buffer, capacity)
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The kernel records the executable's file name, cut to MAXCOMLEN
    /// bytes, as the command name (`kp_proc.p_comm`) at exec time.
    private static func commandName(forExecutable path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return String(decoding: name.utf8.prefix(Int(MAXCOMLEN)), as: UTF8.self)
    }

    private static func commandName(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func allProcesses() -> [(pid: Int32, startTime: timeval, command: String)] {
        // The process table can grow between sizing and reading. Retry that race.
        for _ in 0..<processTableReadAttempts {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let count = size / MemoryLayout<kinfo_proc>.size
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else {
                if errno == ENOMEM { continue }
                return []
            }

            let populatedCount = size / MemoryLayout<kinfo_proc>.size
            return procs.prefix(populatedCount)
                .filter { $0.kp_eproc.e_ucred.cr_uid == geteuid() }
                .map { ($0.kp_proc.p_pid, $0.kp_proc.p_un.__p_starttime, commandName(of: $0)) }
        }
        return []
    }

    /// The kernel-reported start time of a PID, or nil if no such process
    /// exists. Together with the PID it uniquely identifies a process instance.
    static func processStartTime(for pid: Int32) -> timeval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.size
        var proc = kinfo_proc()
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0,
              size > 0 else { return nil }
        return proc.kp_proc.p_un.__p_starttime
    }

    /// Reads argv as null-terminated entries, preserving spaces in profile paths.
    private static func processInfo(for pid: Int32) -> ClaudeProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        return ClaudeProcessSnapshot(buffer: Array(buffer.prefix(size)))
    }

    /// The kernel appends " (deleted)" to the path of a binary that was
    /// replaced on disk while running (e.g. a Claude auto-update).
    private static func executableMatches(_ path: String, target: String) -> Bool {
        if path == target { return true }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved == target { return true }
        return resolved.hasPrefix(target) && resolved.hasSuffix(" (deleted)")
    }
}

/// Wraps a Foundation `Process`. Only touched from the main actor in practice;
/// the termination callback is the sole cross-thread surface, and it is
/// designed to hop back to the main actor before touching app state.
final class RealClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    private let process: Process
    let dataDirectory: URL?
    private var storedTerminationHandler: (@Sendable () -> Void)?

    init(process: Process, dataDirectory: URL? = nil) {
        self.process = process
        self.dataDirectory = dataDirectory
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    var terminationHandler: (@Sendable () -> Void)? {
        get { storedTerminationHandler }
        set {
            storedTerminationHandler = newValue
            process.terminationHandler = { [weak self] _ in
                self?.storedTerminationHandler?()
            }
        }
    }

    func terminate() {
        process.terminate() // SIGTERM; Electron apps shut down gracefully
    }

    func terminateForcefully() {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Handle for a Claude instance that was discovered on the system rather than
/// spawned by this app run (e.g. left over from before a relaunch). There is
/// no Foundation `Process` to observe, so termination is detected by polling.
final class AttachedClaudeProcess: ClaudeProcessHandle, @unchecked Sendable {
    let processIdentifier: Int32
    let dataDirectory: URL?
    /// The process's kernel start time, captured at adoption. The PID plus
    /// this value identify one specific process instance even if the OS
    /// recycles PIDs, so a later unrelated process can never be mistaken for
    /// (or signaled as) the adopted one.
    private let startTime: timeval
    private var storedTerminationHandler: (@Sendable () -> Void)?
    private var monitorTask: Task<Void, Never>?

    init(pid: Int32, startTime: timeval, dataDirectory: URL?) {
        self.processIdentifier = pid
        self.startTime = startTime
        self.dataDirectory = dataDirectory
    }

    /// True only while the PID still refers to the adopted process instance.
    private var sameProcessExists: Bool {
        guard let current = RealClaudeLauncher.processStartTime(for: processIdentifier) else {
            return false
        }
        return current.tv_sec == startTime.tv_sec && current.tv_usec == startTime.tv_usec
    }

    var isRunning: Bool {
        guard sameProcessExists else { return false }
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    var terminationHandler: (@Sendable () -> Void)? {
        get { storedTerminationHandler }
        set {
            storedTerminationHandler = newValue
            if newValue != nil {
                startMonitoring()
            } else {
                monitorTask?.cancel()
                monitorTask = nil
            }
        }
    }

    func terminate() {
        guard sameProcessExists else { return }
        kill(processIdentifier, SIGTERM)
    }

    func terminateForcefully() {
        guard sameProcessExists else { return }
        kill(processIdentifier, SIGKILL)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !self.isRunning {
                    self.storedTerminationHandler?()
                    return
                }
            }
        }
    }
}
