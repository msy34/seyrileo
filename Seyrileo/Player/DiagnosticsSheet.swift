import SeyrileoKit
import SwiftUI

/// Local, redacted connection diagnostics. Nothing leaves the device unless the user
/// explicitly shares the report.
struct DiagnosticsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let catalog: SourceCatalogModel
    var airPlayStatus: ExternalPlaybackMonitor.Status = .local

    private var playback: PlaybackCoordinator { app.playback }
    private var account: AccountInfo? { catalog.account }

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    LabeledContent("State", value: playback.state.diagnosticName)
                    if let item = playback.currentItem {
                        LabeledContent("Channel", value: item.title)
                        LabeledContent("Stream host", value: Redactor.describe(item.url))
                    }
                    LabeledContent("Requested format", value: catalog.preferredFormat.rawValue.uppercased())
                    LabeledContent("AirPlay", value: airPlayStatus.diagnosticName)
                }
                if let capabilities = playback.capabilities {
                    Section {
                        LabeledContent("Engine", value: capabilities.engineName)
                        CapabilityRow(title: "HLS", status: capabilities.hls)
                        CapabilityRow(title: "Live MPEG-TS (.ts)", status: capabilities.liveMPEGTS)
                        CapabilityRow(title: "Picture in Picture", status: capabilities.pictureInPicture)
                        CapabilityRow(title: "AirPlay", status: capabilities.airPlay)
                        CapabilityRow(title: "Audio & subtitle selection", status: capabilities.trackSelection)
                    } header: {
                        Text("Player engine")
                    } footer: {
                        Text("“Not verified” means the engine can do this in principle, but it has not been tested on a physical device yet.")
                    }
                }
                Section {
                    LabeledContent("Source", value: catalog.source.name)
                    LabeledContent("Server", value: Redactor.describe(catalog.source.serverURL))
                    if let account {
                        LabeledContent("Account status", value: account.status.localizedName)
                        LabeledContent("Expires", value: account.expiresAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? String(localized: "Unknown"))
                        LabeledContent("Connections", value: Self.connections(account))
                        LabeledContent(
                            "Output formats",
                            value: account.allowedOutputFormats.isEmpty ? String(localized: "Not reported") : account.allowedOutputFormats.joined(separator: ", "))
                    } else {
                        LabeledContent("Account status", value: String(localized: "Unknown"))
                    }
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Account details come from the provider and may be incomplete.")
                }
                Section("Event log") {
                    if playback.events.isEmpty {
                        Text("No events yet.").foregroundStyle(.secondary)
                    }
                    ForEach(playback.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(verbatim: event.message).font(.caption.monospaced())
                        }
                    }
                }
                Section {
                    ShareLink(item: report) {
                        Label("Share redacted report", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("The report leaves out passwords, usernames and stream addresses. Nothing is sent unless you share it.")
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static func connections(_ account: AccountInfo) -> String {
        let active = account.activeConnections.map(String.init) ?? "?"
        let max = account.maxConnections.map(String.init) ?? "?"
        return "\(active) / \(max)"
    }

    private var report: String {
        var lines = [
            "Seyrileo diagnostics",
            "App: \(Bundle.main.shortVersion)",
            "Source kind: \(catalog.source.kind.rawValue)",
            "Server: \(Redactor.describe(catalog.source.serverURL))",
            "State: \(playback.state.diagnosticName)",
            "Format: \(catalog.preferredFormat.rawValue)",
            "AirPlay: \(airPlayStatus.diagnosticName)",
        ]
        if let capabilities = playback.capabilities {
            lines.append("Engine: \(capabilities.engineName)")
        }
        if let account {
            lines.append("Account: \(account.status) connections=\(Self.connections(account)) formats=\(account.allowedOutputFormats)")
        }
        lines.append("Events:")
        lines += playback.events.map { "\($0.date.ISO8601Format()) \($0.message)" }
        // Second pass: the coordinator already redacts, but the report is re-scrubbed with the
        // current item's secrets in case any text slipped through.
        let redactor = playback.currentItem?.redactor ?? Redactor()
        return redactor.redact(lines.joined(separator: "\n"))
    }
}

private struct CapabilityRow: View {
    let title: LocalizedStringKey
    let status: CapabilityStatus

    var body: some View {
        LabeledContent(title) {
            switch status {
            case .verified: Text("Verified on device")
            case .unverified: Text("Not verified")
            case .notEnabled: Text("Not enabled in this build")
            case .unsupported: Text("Not supported")
            }
        }
    }
}

extension PlaybackState {
    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .buffering: "buffering"
        case .retrying(let attempt, let total): "retrying \(attempt)/\(total)"
        case .failed(let failure): "failed: \(failure)"
        case .ended: "ended"
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension ExternalPlaybackMonitor.Status {
    var diagnosticName: String {
        switch self {
        case .local: String(localized: "Not in use")
        case .routeSelected(let name): String(localized: "Device selected, not playing: \(name ?? "?")")
        case .active(let name): String(localized: "Playing on \(name ?? "?")")
        }
    }
}
