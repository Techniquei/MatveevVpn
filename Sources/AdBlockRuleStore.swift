import Foundation

struct AdBlockRuleStore: Sendable {
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt")!
    static let refreshInterval: TimeInterval = 8 * 60 * 60
    static let stagedFileName = "ad-block-domains.txt"

    private let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/matveevVpn/ad-block", isDirectory: true)) {
        self.directory = directory
    }

    private var cacheFile: URL { directory.appendingPathComponent("hagezi-pro-mini.txt") }

    var needsRefresh: Bool {
        guard let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return true
        }
        return Date().timeIntervalSince(modified) >= Self.refreshInterval
    }

    func materialize(in stage: URL, bundledFile: URL) throws {
        let selected: URL
        if let data = try? Data(contentsOf: cacheFile), Self.validDomains(in: data) != nil {
            selected = cacheFile
        } else {
            let data = try Data(contentsOf: bundledFile)
            guard Self.validDomains(in: data) != nil else {
                throw VPNError.message("The bundled advertising rules are invalid.")
            }
            selected = bundledFile
        }
        try privateWrite(Data(contentsOf: selected), to: stage.appendingPathComponent(Self.stagedFileName))
    }

    func refresh() async throws -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: Self.sourceURL)
        request.setValue("matveevVpn/1.3.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VPNError.message("The advertising-rule source returned an unexpected response.")
        }
        guard data.count <= 5_000_000, Self.validDomains(in: data) != nil else {
            throw VPNError.message("The downloaded advertising rules failed validation.")
        }

        let previous = try? Data(contentsOf: cacheFile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try privateWrite(data, to: cacheFile)
        return previous != data
    }

    static func validDomains(in data: Data) -> [String]? {
        guard data.count >= 100_000, let text = String(data: data, encoding: .utf8) else { return nil }
        var domains: [String] = []
        domains.reserveCapacity(60_000)
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let value = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty || value.hasPrefix("#") { continue }
            guard value.count <= 253 else { return nil }
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy({ label in
                guard let first = label.first, let last = label.last,
                      first.isASCII && last.isASCII,
                      first.isLetter || first.isNumber,
                      last.isLetter || last.isNumber,
                      label.count <= 63 else { return false }
                return label.allSatisfy { character in
                    character.isASCII && (character.isLetter || character.isNumber || character == "-")
                }
            }) else { return nil }
            domains.append(value)
        }
        return domains.count >= 20_000 ? domains : nil
    }
}
