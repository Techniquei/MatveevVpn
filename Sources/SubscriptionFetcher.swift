import Foundation

/// A per-request, memory-only session. URLs and credentials never enter the HTTP disk cache.
final class SubscriptionFetcher: NSObject, URLSessionDataDelegate {
    private let maximumBytes = 4_194_304
    private var body = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?

    static func fetch(_ url: URL) async throws -> Data {
        let fetcher = SubscriptionFetcher()
        return try await fetcher.start(url)
    }

    private func start(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: url).resume()
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
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
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              response.expectedContentLength <= maximumBytes else {
            completionHandler(.cancel)
            finish(.failure(VPNError.message("The subscription server returned an error or an oversized response.")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= maximumBytes else {
            finish(.failure(VPNError.message("The subscription exceeds the 4 MB limit.")))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(.failure(VPNError.message("Could not download the subscription. Check the URL and your connection.")))
        } else {
            finish(.success(body))
        }
    }
}
