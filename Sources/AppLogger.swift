import Foundation

/// A small, user-readable event log. Every write rewrites the file atomically,
/// so the file visible on disk never exceeds `maximumBytes`.
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    static let maximumBytes = 3_000_000

    let file: URL
    private let lock = NSLock()

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/matveevVpn/matveevVpn.log")) {
        self.file = file
        trimIfNeeded()
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = Data("\(timestamp) \(message)\n".utf8)
            let previous = (try? Data(contentsOf: file)) ?? Data()
            try writeBounded(previous + entry)
        } catch {
            // Logging must never interrupt VPN control.
        }
    }

    func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func trimIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file), data.count > Self.maximumBytes else { return }
        try? writeBounded(data)
    }

    private func writeBounded(_ data: Data) throws {
        var retained = data.count <= Self.maximumBytes ? data : Data(data.suffix(Self.maximumBytes))
        if data.count > Self.maximumBytes,
           let newline = retained.firstIndex(of: 0x0A),
           newline < retained.index(before: retained.endIndex) {
            retained = Data(retained[retained.index(after: newline)...])
        }
        try retained.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
