import AppKit
import SwiftUI

/// the small pieces the meetings window is made of, shared by its panes:
/// one set of spacings, the speaker colours, a copy button, a spinner, a
/// shimmer. kept in one place so the sidebar, the panes and the bar cannot
/// drift into three ideas of the same 8.
enum MW {
    /// the spacing ladder. nothing in the window uses a gap off it.
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24

    static let recordingRed = Color(red: 1, green: 0.271, blue: 0.227)

    /// the motion that moves things in and out of the bar and the panes.
    static let barSpring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let morphSpring = Animation.spring(response: 0.35, dampingFraction: 0.7)

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// who said it: `you` is the brand gold, everyone else cycles four colours
/// that sit well on the dark glass.
enum SpeakerInk {
    static let others: [Color] = [
        Color(red: 0.498, green: 0.714, blue: 1),
        Color(red: 0.616, green: 0.878, blue: 0.659),
        Color(red: 1, green: 0.620, blue: 0.541),
        Color(red: 0.788, green: 0.655, blue: 1),
    ]

    static func color(_ colour: Int?) -> Color {
        guard let colour else { return BrandUI.gold }
        return others[colour % others.count]
    }
}

// MARK: - buttons

/// a 28pt square icon button: quiet until the pointer is on it.
struct MWIconButton: View {
    let symbol: String
    let help: String
    var isDisabled = false
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            MWIconLabel(symbol: symbol, isHovering: isHovering && !isDisabled, tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct MWIconLabel: View {
    let symbol: String
    var isHovering = false
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? (isHovering ? BrandUI.textPrimary : BrandUI.textSecondary))
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// copy, then a gold check for a moment: the one sign it worked.
struct MWCopyButton: View {
    let help: String
    var isDisabled = false
    let text: () -> String

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        MWIconButton(
            symbol: copied ? "checkmark" : "doc.on.doc", help: help, isDisabled: isDisabled,
            tint: copied ? BrandUI.gold : nil
        ) {
            MW.copy(text())
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { copied = false }
            }
        }
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeOut(duration: 0.2), value: copied)
    }
}

/// the one loud button: a gold capsule.
struct MWGoldButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(BrandUI.windowBg)
            .padding(.horizontal, MW.s16)
            .frame(height: 32)
            .background {
                Capsule().fill(isHovering ? BrandUI.goldPale : BrandUI.gold)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - motion

/// an arc going round: working on it, and no promise how long.
struct MWSpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var color: Color = BrandUI.gold

    @State private var angle = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .accessibilityLabel("working")
    }
}

/// a light band sliding over placeholder bars while something is being
/// written. still, when the mac is asked for less motion.
struct MWShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.13), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: max(width * 0.5, 1))
                        .offset(x: -width * 0.5 + phase * width * 1.5)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func mwShimmer() -> some View { modifier(MWShimmer()) }

    /// comes in out of a soft blur, as the notes do when they arrive.
    func mwBlurFade() -> some View {
        transition(.opacity.combined(with: .modifier(
            active: MWBlur(radius: 6), identity: MWBlur(radius: 0))))
    }
}

private struct MWBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// grey bars where the notes will be: three sections of a heading and three
/// lines.
struct MWSkeleton: View {
    private static let lines: [[CGFloat]] = [[1, 0.88, 0.62], [0.94, 0.7, 0.8], [1, 0.76, 0.5]]

    var body: some View {
        VStack(alignment: .leading, spacing: MW.s24) {
            ForEach(0..<3, id: \.self) { section in
                VStack(alignment: .leading, spacing: MW.s12) {
                    bar(width: 0.28, height: 10).opacity(0.7)
                    ForEach(0..<3, id: \.self) { line in
                        bar(width: Self.lines[section][line], height: 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mwShimmer()
        .accessibilityElement()
        .accessibilityLabel("writing the notes")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: proxy.size.width * width, height: height)
        }
        .frame(height: height)
    }
}

/// a card with the window's own hairline, for the pane states.
struct MWCard<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(MW.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? BrandUI.cardBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.map { $0.opacity(0.35) } ?? BrandUI.hairline, lineWidth: 1)
            }
    }
}

/// the header row of a pane: its name, what it offers on the right.
struct MWPaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: MW.s8) {
            BrandSectionHeader(title)
            Spacer(minLength: MW.s8)
            trailing
        }
        .padding(.horizontal, MW.s16)
        .frame(height: 40)
    }
}

/// attributes set by their key types: the key-path spelling
/// (`text.foregroundColor = …`) trips strict concurrency, because the
/// scopes' key paths are not `Sendable`.
extension AttributedString {
    typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes

    mutating func paint(_ range: Range<Index>, background: Color) {
        self[range][SwiftUIKeys.BackgroundColorAttribute.self] = background
    }

    mutating func paint(_ range: Range<Index>, foreground: Color) {
        self[range][SwiftUIKeys.ForegroundColorAttribute.self] = foreground
    }

    mutating func underline(_ range: Range<Index>) {
        self[range][SwiftUIKeys.UnderlineStyleAttribute.self] = .single
    }

    mutating func setFont(_ range: Range<Index>, _ font: Font) {
        self[range][SwiftUIKeys.FontAttribute.self] = font
    }
}
