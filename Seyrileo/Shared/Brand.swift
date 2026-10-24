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

extension Color {
    /// The cat's fur and its shadow, and its amber eyes (live "now" progress).
    static let brandFur = Color(red: 0.85, green: 0.66, blue: 0.47)
    static let brandFurShade = Color(red: 0.66, green: 0.47, blue: 0.29)
    static let brandAmber = Color(red: 0.94, green: 0.65, blue: 0.23)
    /// List rows: a glassy lift over the navy backdrop instead of the system grey.
    static let brandRow = Color.white.opacity(0.065)
}

/// A `List` on the icon's night backdrop with glassy rows. Rows may still set their own
/// `listRowBackground` (the innermost one wins).
struct BrandList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            Group { content }
                .listRowBackground(Color.brandRow)
        }
        .scrollContentBackground(.hidden)
        .background { BrandBackdrop() }
    }
}

/// A curled-up, sleeping cat for empty lists.
struct SleepingCat: View {
    var width: CGFloat = 140

    var body: some View {
        Canvas { context, size in
            let s = size.width / 120
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var tail = Path()
            tail.move(to: p(92, 54))
            tail.addCurve(to: p(104, 32), control1: p(114, 54), control2: p(118, 38))
            context.stroke(tail, with: .color(.brandFurShade), style: StrokeStyle(lineWidth: 8 * s, lineCap: .round))
            var body = Path()
            body.move(to: p(14, 50))
            body.addCurve(to: p(58, 20), control1: p(14, 30), control2: p(34, 20))
            body.addCurve(to: p(106, 46), control1: p(82, 20), control2: p(104, 28))
            body.addCurve(to: p(92, 56), control1: p(107, 54), control2: p(100, 56))
            body.addLine(to: p(24, 56))
            body.addCurve(to: p(14, 50), control1: p(18, 56), control2: p(14, 54))
            body.closeSubpath()
            var ears = Path()
            ears.move(to: p(21, 32)); ears.addLine(to: p(25, 13)); ears.addLine(to: p(37, 24)); ears.closeSubpath()
            ears.move(to: p(43, 23)); ears.addLine(to: p(52, 9)); ears.addLine(to: p(57, 22)); ears.closeSubpath()
            let fur = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(red: 0.93, green: 0.78, blue: 0.61), .brandFur]),
                startPoint: p(40, 10), endPoint: p(60, 56))
            context.fill(ears, with: fur)
            context.fill(body, with: fur)
            var eyes = Path()
            eyes.move(to: p(26, 40)); eyes.addQuadCurve(to: p(36, 40), control: p(31, 44))
            eyes.move(to: p(44, 40)); eyes.addQuadCurve(to: p(54, 40), control: p(49, 44))
            context.stroke(eyes, with: .color(Color(red: 0.35, green: 0.23, blue: 0.11)), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
            context.draw(Text(verbatim: "z").font(.system(size: 13 * s, weight: .heavy, design: .rounded)).foregroundStyle(Color.accent), at: p(80, 12))
            context.draw(Text(verbatim: "z").font(.system(size: 9 * s, weight: .heavy, design: .rounded)).foregroundStyle(Color.accent.opacity(0.7)), at: p(90, 4))
        }
        .frame(width: width, height: width * 60 / 120)
        .accessibilityHidden(true)
    }
}

/// An empty list: the sleeping cat over a short hint.
struct CatEmptyState: View {
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            SleepingCat(width: 120)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
        HStack(spacing: 12) {
            BrandMark(size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.brandCream)
                Text(verbatim: sourceName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
