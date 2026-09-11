import Foundation

/// A per-request, memory-only session. URLs and credentials never enter the HTTP disk cache.
final class SubscriptionFetcher: NSObject, URLSessionDataDelegate {
    enum ClientIdentity {
        case matveevVpn
        case happ

        var userAgent: String {
            switch self {
            case .matveevVpn: return "matveevVpn/1.2.2"
            case .happ: return "Happ/4.2.1"
            }
        }
    }

    private static let timeout: TimeInterval = 10
    private let maximumBytes = 4_194_304
    private var body = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var timeoutWorkItem: DispatchWorkItem?
    private var responseSummary = "No HTTP response was received."
    private var userAgent = ClientIdentity.matveevVpn.userAgent
    private var deviceID: String?
    private let stateLock = NSLock()

    static func fetch(_ url: URL, as client: ClientIdentity = .matveevVpn, deviceID: String? = nil) async throws -> Data {
        let fetcher = SubscriptionFetcher()
        return try await fetcher.start(url, as: client, deviceID: deviceID)
    }

    private func start(_ url: URL, as client: ClientIdentity, deviceID: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.userAgent = client.userAgent
            self.deviceID = deviceID
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url, timeoutInterval: Self.timeout)
            request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/octet-stream;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
            if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-HWID") }
            session.dataTask(with: request).resume()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(.failure(VPNError.diagnostic(
                    "The subscription server did not respond within 10 seconds.",
                    self.currentResponseSummary()
                )))
            }
            timeoutWorkItem = timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        stateLock.lock()
        guard let continuation else { stateLock.unlock(); return }
        self.continuation = nil
        let timeout = timeoutWorkItem
        timeoutWorkItem = nil
        let activeSession = session
        session = nil
        stateLock.unlock()
        timeout?.cancel()
        activeSession?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    private func currentResponseSummary() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return responseSummary
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            completionHandler(nil)
            finish(.failure(VPNError.message("The subscription redirected to an insecure URL.")))
            return
        }
        var redirected = request
        redirected.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        redirected.setValue("text/plain, application/octet-stream;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let deviceID { redirected.setValue(deviceID, forHTTPHeaderField: "X-HWID") }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let hwidUnsupported = http?.value(forHTTPHeaderField: "X-HWID-Not-Supported")?.lowercased() == "true"
        let maximumDevicesReached = http?.value(forHTTPHeaderField: "X-HWID-Max-Devices-Reached")?.lowercased() == "true"
        let summary = "HTTP status: \(http?.statusCode.description ?? "unavailable")\nContent type: \(response.mimeType ?? "unavailable")\nExpected bytes: \(response.expectedContentLength)\nHWID accepted: \(hwidUnsupported ? "no" : "not rejected")\nDevice limit reached: \(maximumDevicesReached ? "yes" : "no")"
        stateLock.lock()
        responseSummary = summary
        stateLock.unlock()
        guard let http, (200...299).contains(http.statusCode), response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(VPNError.diagnostic("The subscription server returned an error or an oversized response.", summary)))
            return
        }
        if maximumDevicesReached {
            completionHandler(.cancel)
            finish(.failure(VPNError.diagnostic("The subscription provider's device limit has been reached.", summary)))
            return
        }
        if deviceID != nil && hwidUnsupported {
            completionHandler(.cancel)
            finish(.failure(VPNError.diagnostic("The subscription provider did not accept this app's device identifier.", summary)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= maximumBytes else {
            finish(.failure(VPNError.diagnostic("The subscription exceeds the 4 MB limit.", currentResponseSummary() + "\nReceived bytes: \(body.count + data.count)")))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            finish(.failure(VPNError.diagnostic(
                "Could not download the subscription. Check the URL and your connection.",
                currentResponseSummary() + "\nNetwork error: \(error.domain) (\(error.code))"
            )))
        } else {
            finish(.success(body))
        }
    }
}
