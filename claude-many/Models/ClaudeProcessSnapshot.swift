import Foundation

/// Decode macOS KERN_PROCARGS2 without trusting incomplete argument lists.
struct ClaudeProcessSnapshot {
    let executablePath: String
    let arguments: [String]
    /// Launch-time `NAME=value` entries. The kernel's trailing apple[] strings,
    /// such as `executable_path=`, are included; no app variable uses those names.
    private let environment: [String]

    init?(buffer: [UInt8]) {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count >= headerSize else { return nil }

        let argumentCount = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount > 0, argumentCount <= buffer.count - headerSize else { return nil }

        var index = headerSize
        guard let executableEnd = buffer[index...].firstIndex(of: 0), executableEnd > index,
              let executablePath = String(bytes: buffer[index..<executableEnd], encoding: .utf8) else {
            return nil
        }

        // The kernel pads between the executable path and argv[0]. Empty later args are retained.
        index = executableEnd + 1
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard index < buffer.count, let end = buffer[index...].firstIndex(of: 0),
                  let argument = String(bytes: buffer[index..<end], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            index = end + 1
        }

        self.executablePath = executablePath
        self.arguments = arguments
        environment = buffer[index...].split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Every value of `name`, in order. Callers decide how duplicates resolve.
    func environmentValues(named name: String) -> [String] {
        let prefix = name + "="
        return environment.compactMap { entry in
            guard entry.hasPrefix(prefix) else { return nil }
            return String(entry.dropFirst(prefix.count))
        }
    }
}
