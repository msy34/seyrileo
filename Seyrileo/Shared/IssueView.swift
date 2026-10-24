import SwiftUI

struct IssueView: View {
    let issue: UserIssue
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(app: issue.title).font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Text(app: issue.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !issue.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issue.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        Label { Text(app: suggestion) } icon: { Image(systemName: "arrow.right.circle") }
                            .font(.footnote)
                    }
                }
            }
            if let technical = issue.technical {
                Text(verbatim: technical)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if let retry, issue.canRetry {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
