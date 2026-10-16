import SwiftUI

/// Seyrileo's look, taken from the owner's app icon: a midnight-navy night sky with a
/// deep-blue glow, the teal play button and its cream triangle.
/// (Colours come from the asset catalogue: `Color.brandNavy`, `.brandGlow`, `.brandTeal`, `.brandCream`.)

/// The app icon itself, with iOS-style continuous corners and the icon's teal glow.
struct BrandMark: View {
    var size: CGFloat = 96
    var glows = true

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, size / 160))
            }
            .shadow(color: glows ? Color.brandGlow.opacity(0.9) : .clear, radius: size * 0.22, y: size * 0.06)
            .shadow(color: glows ? Color.accent.opacity(0.25) : .clear, radius: size * 0.45)
            .accessibilityHidden(true)
    }
}

/// The icon's background as a full-screen backdrop: navy edges, a blue glow rising from below.
struct BrandBackdrop: View {
    var body: some View {
        ZStack {
            Color.brandNavy
            RadialGradient(
                colors: [Color.brandGlow.opacity(0.85), Color.brandNavy.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.95), startRadius: 10, endRadius: 520)
            RadialGradient(
                colors: [Color.brandTeal.opacity(0.35), .clear],
                center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 260)
        }
        .ignoresSafeArea()
    }
}

/// Top of "Your Space": the icon, a greeting for the time of day and the active source.
struct BrandGreetingHeader: View {
    let sourceName: String
    @State private var now = Date()

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Good night"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            BrandMark(size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.brandCream)
                Text(verbatim: sourceName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.brandNavy, Color.brandGlow.opacity(0.9)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.accent.opacity(0.18))
                        .frame(width: 140, height: 140)
                        .blur(radius: 30)
                        .offset(x: 30, y: -40)
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .task {
            // Keep the greeting right if the app stays open across a boundary.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                now = Date()
            }
        }
    }
}
