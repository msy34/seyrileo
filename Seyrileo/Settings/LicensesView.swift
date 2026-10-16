import SwiftUI

/// Third-party notices. VLCKit is LGPL-2.1: users must be told it is included, where its
/// source is, and that they may replace it; the full license text is shown here.
struct LicensesView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "MobileVLCKit 3.7.4 (VLCKit / libVLC)").font(.headline)
                    Text("Used to play formats the built-in iOS player cannot (for example MKV and AVI). Licensed under the GNU Lesser General Public License, version 2.1 or later. It is included unmodified and dynamically linked, so it can be replaced with a compatible build.")
                        .font(.footnote)
                    Link(destination: URL(string: "https://code.videolan.org/videolan/VLCKit")!) {
                        Text(verbatim: "code.videolan.org/videolan/VLCKit")
                    }
                    .font(.footnote)
                }
                NavigationLink("License text (LGPL 2.1)") { LicenseText(resource: "VLCKit-LGPL-2.1") }
            } header: {
                Text(verbatim: "VLCKit")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "GRDB.swift 7.11.1").font(.headline)
                    Text("On-device database. MIT License.").font(.footnote)
                }
                NavigationLink("License text (MIT)") { LicenseText(resource: "GRDB-MIT") }
            } header: {
                Text(verbatim: "GRDB")
            }
        }
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseText: View {
    let resource: String

    var body: some View {
        ScrollView {
            Text(verbatim: Self.load(resource))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding()
        }
    }

    static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "License text missing from this build." }
        return text
    }
}
