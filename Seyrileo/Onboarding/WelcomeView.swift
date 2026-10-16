import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var showSetup = false
    @State private var startingSample = false
    @State private var sampleIssue: UserIssue?

    var body: some View {
        ZStack {
            BrandBackdrop()
            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 36)
                    VStack(spacing: 18) {
                        BrandMark(size: 136)
                        VStack(spacing: 6) {
                            Text(verbatim: "Seyrileo")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Your streams. Your space.")
                                .font(.title3)
                                .foregroundStyle(Color.brandCream.opacity(0.85))
                        }
                    }
                    .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        FeatureChip(symbol: "dot.radiowaves.left.and.right", title: "Live")
                        FeatureChip(symbol: "film", title: "Movies")
                        FeatureChip(symbol: "play.square.stack", title: "Series")
                        FeatureChip(symbol: "calendar", title: "Guide")
                    }

                    Text("Seyrileo is a player. It doesn't sell or include any channels. Add a source you're authorized to use.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)

                    VStack(spacing: 12) {
                        Button {
                            showSetup = true
                        } label: {
                            Label("Add your source", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accent)
                        .foregroundStyle(Color.brandNavy)
                        .controlSize(.large)

                        Button {
                            Task { await startSample() }
                        } label: {
                            HStack {
                                if startingSample { ProgressView().tint(.white) }
                                Text("Try the sample experience")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .controlSize(.large)
                        .disabled(startingSample)

                        Text("The sample uses synthetic test patterns served from this device. No real channels.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 420)

                    if let sampleIssue {
                        IssueView(issue: sampleIssue) { Task { await startSample() } }
                            .frame(maxWidth: 420)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showSetup) {
            SourceSetupView()
        }
    }

    private func startSample() async {
        startingSample = true
        sampleIssue = nil
        defer { startingSample = false }
        do {
            try await app.addFixtureSource()
        } catch {
            sampleIssue = UserIssue(error)
        }
    }
}

private struct FeatureChip: View {
    let symbol: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
