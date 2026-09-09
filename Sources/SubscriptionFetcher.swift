import Foundation

/// A per-request, memory-only session. URLs and credentials never enter the HTTP disk cache.
final class SubscriptionFetcher: NSObject, URLSessionDataDelegate {
    private static let timeout: TimeInterval = 10
    private let maximumBytes = 4_194_304
    private var body = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var timeoutWorkItem: DispatchWorkItem?
    private var responseSummary = "No HTTP response was received."
    private let stateLock = NSLock()

    static func fetch(_ url: URL) async throws -> Data {
        let fetcher = SubscriptionFetcher()
        return try await fetcher.start(url)
    }

    private func start(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url, timeoutInterval: Self.timeout)
            request.setValue("matveevVpn/1.2.0", forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain, application/octet-stream;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
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
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let summary = "HTTP status: \(http?.statusCode.description ?? "unavailable")\nContent type: \(response.mimeType ?? "unavailable")\nExpected bytes: \(response.expectedContentLength)"
        stateLock.lock()
        responseSummary = summary
        stateLock.unlock()
        guard let http, (200...299).contains(http.statusCode), response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(VPNError.diagnostic("The subscription server returned an error or an oversized response.", summary)))
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
