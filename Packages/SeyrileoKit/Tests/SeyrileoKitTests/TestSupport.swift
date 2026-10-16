import Foundation
import Testing
@testable import SeyrileoKit

enum TestFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

/// Scripted transport: returns queued results in order and records requested URLs.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<HTTPResponse, XtreamError>]
    private(set) var requests: [URL] = []

    init(_ results: [Result<HTTPResponse, XtreamError>]) {
        self.results = results
    }

    static func json(_ text: String, status: Int = 200) -> StubTransport {
        StubTransport([.success(HTTPResponse(statusCode: status, contentType: "application/json", body: Data(text.utf8)))])
    }

    static func body(_ data: Data, status: Int = 200, contentType: String? = "application/json") -> StubTransport {
        StubTransport([.success(HTTPResponse(statusCode: status, contentType: contentType, body: data))])
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func get(_ url: URL, maxBytes: Int) async throws -> HTTPResponse {
        let result = lock.withLock { () -> Result<HTTPResponse, XtreamError> in
            requests.append(url)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }
}

/// Records requested delays and returns immediately: retries are tested without sleeping.
final class RecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [Duration] = []

    var sleeper: Sleeper {
        { [self] duration in
            lock.withLock { delays.append(duration) }
            try Task.checkCancellation()
        }
    }

    var recorded: [Duration] { lock.withLock { delays } }
}

extension XtreamClient {
    static func stub(
        _ transport: HTTPTransport, credentials: XtreamCredentials = XtreamCredentials(username: "user", password: "secret-pass"),
        retry: RetryPolicy = .none, sleeper: @escaping Sleeper = { _ in }
    ) throws -> XtreamClient {
        XtreamClient(
            providerID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            endpoint: try XtreamEndpoint(serverAddress: "https://provider.example:8443/base"),
            credentials: credentials, transport: transport, retryPolicy: retry, sleeper: sleeper)
    }
}

/// Suspends waiters until opened. Lets a test control exactly when a "sleep" completes.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
