import Foundation

/// Transport-level failure, classified from URLSession errors without keeping the raw
/// (credential-bearing) `NSError` around.
public enum TransportFailure: Equatable, Sendable {
    case offline
    case timedOut
    case hostNotFound
    case cannotConnect
    case connectionLost
    case tlsFailure
    /// App Transport Security refused a plaintext HTTP connection.
    case insecureHTTPBlocked
    case cancelled
    case other(code: Int)

    public init(urlErrorCode code: Int) {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            self = .offline
        case NSURLErrorTimedOut: self = .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: self = .hostNotFound
        case NSURLErrorCannotConnectToHost: self = .cannotConnect
        case NSURLErrorNetworkConnectionLost: self = .connectionLost
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired:
            self = .tlsFailure
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: self = .insecureHTTPBlocked
        case NSURLErrorCancelled: self = .cancelled
        default: self = .other(code: code)
        }
    }

    public var isTransient: Bool {
        switch self {
        case .timedOut, .cannotConnect, .connectionLost: true
        case .offline, .hostNotFound, .tlsFailure, .insecureHTTPBlocked, .cancelled, .other: false
        }
    }
}

public enum XtreamError: Error, Equatable, Sendable {
    case invalidServerAddress(XtreamEndpoint.ValidationError)
    case transport(TransportFailure)
    case httpStatus(Int)
    /// The provider redirected to another host or downgraded HTTPS; not followed so the
    /// credential-bearing request is not forwarded.
    case unsafeRedirectBlocked
    case responseTooLarge(limitBytes: Int)
    case htmlInsteadOfJSON
    case emptyResponse
    case malformedJSON
    case unexpectedShape(String)
    /// The provider answered and explicitly rejected the credentials (`auth: 0`).
    case authenticationRejected
    case cancelled

    public var isTransient: Bool {
        switch self {
        case .transport(let failure): failure.isTransient
        case .httpStatus(let code): code == 429 || code == 502 || code == 503 || code == 504
        default: false
        }
    }
}
