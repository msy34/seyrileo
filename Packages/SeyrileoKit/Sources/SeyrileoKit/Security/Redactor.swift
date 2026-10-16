import Foundation

/// Removes credentials from text before it is shown in diagnostics, logged or exported.
///
/// Two layers:
/// 1. Every URL-looking substring is reduced to `scheme://host[:port]/[redacted]`. Xtream
///    stream URLs carry the password in the *path*, so stripping only the query is not enough.
/// 2. Known secret values are replaced in their raw and encoded spellings, catching secrets
///    that appear outside URLs (for example inside server messages).
public struct Redactor: Sendable {
    public static let placeholder = "[redacted]"
    /// Secrets shorter than this are not substring-replaced (it would mangle unrelated text);
    /// URL-level redaction still covers their usual location.
    static let minimumSecretLength = 3

    private let variants: [String]
    private let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets
        var variants = Set<String>()
        for secret in secrets where secret.count >= Self.minimumSecretLength {
            variants.insert(secret)
            variants.insert(XtreamEndpoint.encode(secret))
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { variants.insert(encoded) }
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { variants.insert(encoded) }
            variants.insert(secret.replacingOccurrences(of: " ", with: "+"))
        }
        // Longest first so a secret containing another secret is fully replaced.
        self.variants = variants.sorted { $0.count > $1.count }
    }

    /// A redactor that also hides `more` (e.g. a host name in a shareable report).
    public func adding(_ more: [String]) -> Redactor {
        Redactor(secrets: secrets + more)
    }

    public func redact(_ text: String) -> String {
        var result = Self.redactURLs(in: text)
        for variant in variants {
            result = result.replacingOccurrences(of: variant, with: Self.placeholder, options: [.caseInsensitive])
        }
        return result
    }

    /// `scheme://host[:port]` plus a placeholder; user info, path, query and fragment removed.
    public static func describe(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return placeholder }
        let port = url.port.map { ":\($0)" } ?? ""
        let hasMore = !url.path.isEmpty && url.path != "/" || url.query != nil || url.fragment != nil
        return "\(scheme)://\(host)\(port)" + (hasMore ? "/\(placeholder)" : "")
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>\(\)\[\]]+"#)

    static func redactURLs(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = urlPattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let candidate = String(result[swiftRange])
            // Already-redacted output ("scheme://host/[redacted]") stays as is (idempotent).
            if candidate.hasSuffix("/"), result[swiftRange.upperBound...].hasPrefix(placeholder),
               URL(string: candidate).map({ $0.path == "/" && $0.query == nil }) == true {
                continue
            }
            let replacement = URL(string: candidate).map(describe) ?? placeholder
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }
}

/// A loggable, credential-free summary of an arbitrary error. Raw `NSError.userInfo`
/// (which often contains the failing URL) is never retained.
public struct SanitizedError: Equatable, Sendable, CustomStringConvertible {
    public let domain: String
    public let code: Int
    public let message: String
    public let underlying: [String]

    public init(_ error: Error, redactor: Redactor) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        message = redactor.redact(nsError.localizedDescription)
        var chain: [String] = []
        var next = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = next, chain.count < 4 {
            chain.append("\(current.domain)#\(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        underlying = chain
    }

    public var identifier: String { "\(domain)#\(code)" }

    public var description: String {
        ([identifier + " " + message] + underlying.map { "← \($0)" }).joined(separator: " ")
    }
}
