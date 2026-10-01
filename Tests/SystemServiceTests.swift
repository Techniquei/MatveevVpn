import Foundation

@main struct SystemServiceTests {
    static func main() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = root.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let service = SystemService(baseDirectory: root)
        let runtime = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try privateWrite(Data("previous failure".utf8), to: control.appendingPathComponent("last-error.log"))
        try privateWrite(Data("runtime launch: duration_ms=123".utf8), to: runtime.appendingPathComponent("vpn.error.log"))
        let diagnostics = service.recentRuntimeErrors()
        precondition(diagnostics.contains("previous failure") && diagnostics.contains("duration_ms=123"), "A captured failure must not hide current runtime timings from exported diagnostics")
        for status in ["starting", "waiting for network"] {
            try privateWrite(Data(status.utf8), to: control.appendingPathComponent("runtime-status"))
            precondition(service.isConnecting && !service.running)
        }
        try privateWrite(Data("waiting to retry".utf8), to: control.appendingPathComponent("runtime-status"))
        precondition(!service.isConnecting && !service.running)

        let response = Task {
            let command = control.appendingPathComponent("command")
            for _ in 0..<300 {
                if let text = try? String(contentsOf: command, encoding: .utf8) {
                    let fields = text.split(separator: " ")
                    precondition(fields.count == 3 && fields[0] == "reload")
                    precondition(Int64(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
                    let token = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    // Failure cleanup is part of the same fifteen-second operation.
                    try await Task.sleep(nanoseconds: 11_000_000_000)
                    try privateWrite(Data("ok\n".utf8), to: control.appendingPathComponent("response-" + token))
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("The client did not submit its reload command")
        }
        defer { response.cancel() }
        try await service.send("reload")
        try await response.value
        let remaining = try FileManager.default.contentsOfDirectory(atPath: control.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix("response-") })
        let started = Date()
        do {
            try await service.send("reload", until: started.addingTimeInterval(0.2))
            fatalError("An expired operation received a new response budget")
        } catch { precondition(error.localizedDescription.contains("15-second limit")) }
        precondition(Date().timeIntervalSince(started) < 0.5)
        let processStarted = Date()
        let timedOut = await Command.run("/bin/sleep", ["5"], timeout: 0.1)
        precondition(timedOut.status != 0 && Date().timeIntervalSince(processStarted) < 0.5,
                     "Configuration tools must not outlive their remaining operation budget")
        print("system service: startup states and delayed reload acknowledgement passed")
    }
}
