import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    public init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

/// Minimal GET transport so the provider adapter can be tested without the network.
/// Implementations throw `XtreamError` only.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, maxBytes: Int) async throws -> HTTPResponse
}

/// URLSession transport for provider metadata.
///
/// - Ephemeral session: no disk cache, cookies or credential storage, so secret-bearing
///   request URLs are not persisted.
/// - Response bodies are capped while streaming, including chunked responses with no length.
/// - Redirects are followed only on the same host and never from HTTPS to HTTP.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 90) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func get(_ url: URL, maxBytes: Int) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        let collector = BodyCollector(originalURL: url, maxBytes: maxBytes)
        let task = session.dataTask(with: request)
        task.delegate = collector
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(task: task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class BodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let originalURL: URL
    private let maxBytes: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var pendingError: XtreamError?

    init(originalURL: URL, maxBytes: Int) {
        self.originalURL = originalURL
        self.maxBytes = maxBytes
    }

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<HTTPResponse, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, Self.isSafeRedirect(from: originalURL, to: target) else {
            lock.withLock { pendingError = .unsafeRedirectBlocked }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    static func isSafeRedirect(from original: URL, to target: URL) -> Bool {
        guard let fromHost = original.host?.lowercased(), let toHost = target.host?.lowercased(),
              fromHost == toHost
        else { return false }
        if original.scheme == "https" && target.scheme != "https" { return false }
        return target.scheme == "https" || target.scheme == "http"
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maxBytes) {
            lock.withLock { pendingError = .responseTooLarge(limitBytes: maxBytes) }
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let exceeded = lock.withLock { () -> Bool in
            data.append(chunk)
            if data.count > maxBytes {
                pendingError = .responseTooLarge(limitBytes: maxBytes)
                return true
            }
            return false
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result): (CheckedContinuation<HTTPResponse, Error>?, Result<HTTPResponse, Error>) =
            lock.withLock {
                let continuation = self.continuation
                self.continuation = nil
                if let pendingError { return (continuation, .failure(pendingError)) }
                if let error {
                    let code = (error as NSError).domain == NSURLErrorDomain ? (error as NSError).code : NSURLErrorUnknown
                    let failure = TransportFailure(urlErrorCode: code)
                    return (continuation, .failure(failure == .cancelled ? XtreamError.cancelled : XtreamError.transport(failure)))
                }
                guard let response else { return (continuation, .failure(XtreamError.transport(.other(code: NSURLErrorBadServerResponse)))) }
                return (continuation, .success(HTTPResponse(
                    statusCode: response.statusCode,
                    contentType: response.value(forHTTPHeaderField: "Content-Type"),
                    body: data)))
            }
        continuation?.resume(with: result)
    }
}
