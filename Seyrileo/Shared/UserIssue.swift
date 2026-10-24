import Foundation
import SeyrileoKit

/// A user-facing explanation of a failure. States what is known, says when the cause is not
/// known, and lists steps the user can actually take.
struct UserIssue: Equatable {
    var title: LocalizedStringResource
    var detail: LocalizedStringResource
    var suggestions: [LocalizedStringResource] = []
    var technical: String? = nil
    var canRetry: Bool = true
}

extension UserIssue {
    init(_ error: Error) {
        switch error {
        case let error as XtreamError: self.init(xtream: error)
        case let error as XtreamEndpoint.ValidationError: self.init(xtream: .invalidServerAddress(error))
        case let error as LibraryPlaybackError:
            switch error {
            case .unknownContainer:
                self.init(
                    title: "This title can't be opened",
                    detail: "The provider did not say which file format this title uses, so its address is unknown.",
                    suggestions: ["Try again later, or ask your provider."], canRetry: false)
            case .providerReturnedNoMedia:
                self.init(
                    title: "The provider has no video for this title",
                    detail: "The provider's server answered with an empty page instead of the video file. The file is probably missing on their side; this is not a format or app problem.",
                    suggestions: ["Try another episode or season.", "Report this title to your provider."], canRetry: true)
            }
        case is LibraryLookupError:
            self.init(
                title: "No longer offered",
                detail: "This source no longer lists this title.",
                suggestions: ["Update the library in Settings."], canRetry: false)
        case is SourceAccessError:
            self.init(
                title: "Saved sign-in details are missing",
                detail: "The details for this source could not be read from this device's Keychain.",
                suggestions: ["Remove the source and add it again."], canRetry: false)
        case let error as OrganizationError:
            switch error {
            case .emptyName:
                self.init(title: "Enter a name", detail: "The name can't be empty.", canRetry: false)
            case .nameTooLong:
                self.init(title: "Name too long", detail: "Use at most \(OrganizationStore.maxNameLength) characters.", canRetry: false)
            case .collectionNotFound:
                self.init(title: "Collection not found", detail: "This collection was deleted or belongs to another source.", canRetry: false)
            }
        case let error as ReminderError:
            switch error {
            case .alreadyStarted:
                self.init(title: "This programme has already started", detail: "Reminders can only be set for programmes that haven't started yet.", canRetry: false)
            case .tooMany(let limit):
                self.init(
                    title: "Too many reminders", detail: "You can keep up to \(limit) reminders at a time.",
                    suggestions: ["Remove a reminder you no longer need."], canRetry: false)
            }
        case is CancellationError:
            self.init(title: "Cancelled", detail: "The request was cancelled.", canRetry: true)
        default:
            self.init(
                title: "Something went wrong",
                detail: "The exact cause is not known.",
                suggestions: ["Try again."],
                technical: String(describing: type(of: error)))
        }
    }

    init(xtream error: XtreamError) {
        switch error {
        case .invalidServerAddress(let reason):
            let detail: LocalizedStringResource = switch reason {
            case .empty: "Enter the server address from your provider."
            case .unsupportedScheme: "The address must start with http:// or https://."
            case .missingHost: "The address has no host name."
            case .containsUserInfo: "Remove the username and password from the address and use the separate fields."
            case .malformed: "The address could not be read."
            }
            self.init(title: "Check the server address", detail: detail, canRetry: false)
        case .transport(let failure):
            self.init(transport: failure)
        case .httpStatus(let status):
            switch status {
            case 401:
                self.init(
                    title: "The provider refused the sign-in",
                    detail: "The server answered 401 (unauthorized).",
                    suggestions: ["Check the username and password.", "Confirm your subscription is active with your provider."],
                    technical: "HTTP 401", canRetry: false)
            case 403:
                self.init(
                    title: "The provider denied access",
                    detail: "The server answered 403 (forbidden). It did not say why. Possible reasons include an inactive account, a blocked region or network, or a connection limit.",
                    suggestions: ["Check your account status with your provider.", "If another device is watching, stop it and try again."],
                    technical: "HTTP 403")
            case 404:
                self.init(
                    title: "Provider address not found",
                    detail: "The server answered 404. The server address or its path may be wrong.",
                    suggestions: ["Check the address, including any port or path your provider gave you."],
                    technical: "HTTP 404", canRetry: false)
            case 429:
                self.init(
                    title: "Too many requests",
                    detail: "The provider is limiting requests right now.",
                    suggestions: ["Wait a minute and try again."], technical: "HTTP 429")
            default:
                self.init(
                    title: "The provider returned an error",
                    detail: "The server answered with HTTP status \(status).",
                    suggestions: ["Try again later."], technical: "HTTP \(status)")
            }
        case .unsafeRedirectBlocked:
            self.init(
                title: "Redirect blocked",
                detail: "The provider tried to redirect to a different address or from HTTPS to HTTP. Seyrileo did not follow it so your sign-in details are not sent elsewhere.",
                suggestions: ["Ask your provider for the correct server address."], canRetry: false)
        case .responseTooLarge:
            self.init(
                title: "Response too large",
                detail: "The provider sent more data than Seyrileo accepts in one response.",
                suggestions: ["Try a smaller category."])
        case .htmlInsteadOfJSON:
            self.init(
                title: "This doesn't look like an Xtream-compatible server",
                detail: "The server answered with a web page instead of data. The address may point to a website or an error page.",
                suggestions: ["Check the server address and port."], canRetry: false)
        case .emptyResponse:
            self.init(title: "Empty response", detail: "The provider answered with no data.", suggestions: ["Try again."])
        case .malformedJSON, .unexpectedShape:
            self.init(
                title: "Unreadable provider response",
                detail: "The provider's answer could not be read. It may be incompatible or temporarily broken.",
                suggestions: ["Try again later."], technical: "\(error)")
        case .authenticationRejected:
            self.init(
                title: "Username or password not accepted",
                detail: "The provider answered and rejected these sign-in details.",
                suggestions: ["Check the username and password.", "Confirm your subscription is active with your provider."],
                canRetry: false)
        case .cancelled:
            self.init(title: "Cancelled", detail: "The request was cancelled.")
        }
    }

    init(transport failure: TransportFailure) {
        switch failure {
        case .offline:
            self.init(
                title: "You're offline",
                detail: "This device has no internet connection.",
                suggestions: ["Check Wi-Fi or mobile data and try again."])
        case .timedOut:
            self.init(
                title: "The provider did not respond in time",
                detail: "The connection timed out.",
                suggestions: ["Try again.", "Check whether the provider is having problems."])
        case .hostNotFound:
            self.init(
                title: "Server not found",
                detail: "The server name could not be found.",
                suggestions: ["Check the address for typos."], canRetry: false)
        case .cannotConnect, .connectionLost:
            self.init(
                title: "Can't reach the source",
                detail: "The server could not be reached or the connection dropped.",
                suggestions: ["Check the address and port.", "Try again in a moment."])
        case .tlsFailure:
            self.init(
                title: "Secure connection failed",
                detail: "The server's HTTPS certificate could not be verified. Seyrileo does not bypass certificate checks.",
                suggestions: ["Ask your provider for a valid HTTPS address."], canRetry: false)
        case .insecureHTTPBlocked:
            self.init(
                title: "iOS blocked an unencrypted connection",
                detail: "App Transport Security refused a plain-HTTP connection. This is not expected with the current app configuration.",
                suggestions: ["Ask your provider for an HTTPS address.", "Share a redacted diagnostics report with support."], canRetry: false)
        case .cancelled:
            self.init(title: "Cancelled", detail: "The request was cancelled.")
        case .other(let code):
            self.init(
                title: "Network error",
                detail: "The connection failed. The exact cause is not known.",
                suggestions: ["Try again."], technical: "NSURLErrorDomain \(code)")
        }
    }

    /// While AirPlay is active the receiver fetches and decodes the stream itself, so a
    /// failure may come from the receiver's network access, format support or the source's
    /// redirects rather than from this app. The cause is stated as unknown unless reported.
    init(playback failure: PlaybackFailure, isExternal: Bool, isFixture: Bool, onDemandContainer: String? = nil) {
        self.init(playback: failure)
        if let container = onDemandContainer, failure == .unsupportedFormat || failure == .serverIncompatible {
            let type = container.isEmpty ? String(app: "file") : container.uppercased()
            detail = "This title is a \(type) file. Neither the built-in iOS player nor VLC could play it."
            suggestions = ["Try another title."]
            technical = technical ?? type
        } else if onDemandContainer != nil {
            suggestions = suggestions.map { $0 == "Try another channel." ? "Try another title." : $0 }
        }
        guard isExternal else { return }
        suggestions.insert(
            isFixture
                ? "Sample streams are served from this phone only; an AirPlay receiver cannot reach them."
                : "This happened during AirPlay. The receiver loads the stream itself and may not reach the source or support its format. Try playing on this device to compare.",
            at: 0)
    }

    init(playback failure: PlaybackFailure) {
        switch failure {
        case .offline:
            self.init(transport: .offline)
        case .timedOut:
            self.init(transport: .timedOut)
        case .hostUnreachable:
            self.init(
                title: "Can't reach the stream",
                detail: "The stream server could not be reached.",
                suggestions: ["Try again in a moment."])
        case .insecureConnectionBlocked:
            self.init(transport: .insecureHTTPBlocked)
        case .streamNotFound:
            self.init(
                title: "Stream unavailable",
                detail: "The provider says this stream does not exist right now (404). The channel may be offline.",
                suggestions: ["Try another channel.", "Try again later."], technical: "HTTP 404")
        case .accessDenied(let status):
            let detail: LocalizedStringResource = if let status {
                "The stream server answered \(status). It did not say why. Possible reasons include an inactive account, a connection limit or a regional restriction."
            } else {
                "The stream server refused access. It did not say why. Possible reasons include an inactive account, a connection limit or a regional restriction."
            }
            self.init(
                title: "The provider denied this stream",
                detail: detail,
                suggestions: ["If another device is watching, stop it and try again.", "Check your account status with your provider."],
                technical: status.map { "HTTP \($0)" })
        case .serverError(let status):
            self.init(
                title: "The stream server had a problem",
                detail: "The stream server answered with HTTP status \(status).",
                suggestions: ["Try again later."], technical: "HTTP \(status)")
        case .unsupportedFormat:
            self.init(
                title: "This format isn't supported by this player",
                detail: "Neither the built-in iOS player nor VLC could decode this stream.",
                suggestions: ["Try another channel."],
                canRetry: false)
        case .serverIncompatible:
            self.init(
                title: "This stream type isn't supported by this player",
                detail: "The stream server delivers media in a way neither the built-in iOS player nor VLC could use.",
                suggestions: ["If your provider offers HLS (m3u8) output, use it.", "Try another channel."],
                technical: "AVFoundation -11850", canRetry: false)
        case .startupTimedOut:
            self.init(
                title: "The stream didn't start",
                detail: "No picture arrived in time and the player reported no error. The source may be slow, or the stream may not contain media this player can decode.",
                suggestions: ["Try again.", "Try another channel."])
        case .stalled:
            self.init(
                title: "The stream keeps stalling",
                detail: "Not enough data arrived to keep playing.",
                suggestions: ["Check your connection.", "Try again."])
        case .unknown(let sanitized):
            self.init(
                title: "Playback failed",
                detail: "The player reported an error and the exact cause is not known.",
                suggestions: ["Try again.", "Try another channel."],
                technical: sanitized?.identifier)
        }
    }
}
