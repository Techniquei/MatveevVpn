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
        try await checkIPCDeadlineAndFailureContext()
        print("system service: startup states and delayed reload acknowledgement passed")
    }

    static func checkIPCDeadlineAndFailureContext() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/mvipc-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let ipc = root.appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: false)
        let marker = root.appendingPathComponent("ready")
        let fixture = """
        import json, socket, sys, time
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sys.argv[1])
        server.listen(8)
        open(sys.argv[2], 'w').close()
        while True:
            conn, _ = server.accept()
            data = b''
            while b'\\n' not in data:
                data += conn.recv(16384)
            request = json.loads(data)
            if request['action'] == 'GetStatus' and sys.argv[3] == 'stall':
                time.sleep(5)
            status = {'runtimeState': 'waiting-network', 'acceptedRevision': 2,
                      'phase': 'physical-dns-probe', 'error': 'physical_dns_probe_failed',
                      'diagnostics': ['state=waiting-network phase=physical-dns-probe error=physical_dns_probe_failed']}
            try:
                conn.sendall(json.dumps({'success': True, 'status': status}).encode() + b'\\n')
            except BrokenPipeError:
                pass
            conn.close()
        """
        for mode in ["stall", "waiting"] {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: ipc.appendingPathComponent("service.sock"))
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-c", fixture, ipc.appendingPathComponent("service.sock").path, marker.path, mode]
            try server.run()
            defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(FileManager.default.fileExists(atPath: marker.path))
            let service = SystemService(baseDirectory: root, connectionTimeout: 0.2)
            let started = Date()
            do {
                try await service.send(mode == "stall" ? "reload" : "on", until: started.addingTimeInterval(0.2))
                fatalError("The failing service did not fail")
            } catch {
                if mode == "stall" {
                    precondition(Date().timeIntervalSince(started) < 0.6, "An unresponsive socket exceeded its deadline")
                } else {
                    guard case let VPNError.diagnostic(_, details) = error else { fatalError("Startup lost its diagnostic context") }
                    precondition(details.contains("phase=physical-dns-probe") && details.contains("physical_dns_probe_failed"))
                }
            }
            server.terminate()
            server.waitUntilExit()
        }
    }
}
