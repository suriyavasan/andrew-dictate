import SwiftUI

/// figma's tone pad: casual to professional across, concise to expanded
/// down, a dot you drag that settles on the nearest of five steps each way.
/// the arrow keys move it a step, and VoiceOver reads it as two words.
struct TonePadView: View {
    @Binding var tone: TonePosition

    static let side: CGFloat = 168
    private static let inset: CGFloat = 18
    private static let knob: CGFloat = 14

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            axisLabel("concise")
            HStack(spacing: 6) {
                axisLabel("casual")
                    .frame(width: 58, alignment: .trailing)
                pad
                axisLabel("professional")
                    .frame(width: 58, alignment: .leading)
            }
            axisLabel("expanded")
        }
    }

    private var pad: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BrandUI.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isFocused ? BrandUI.gold.opacity(0.6) : BrandUI.hairline,
                        lineWidth: 1
                    )
                // the axes through the middle, faint: where "as said" is.
                Path { path in
                    path.move(to: CGPoint(x: size.width / 2, y: Self.inset))
                    path.addLine(to: CGPoint(x: size.width / 2, y: size.height - Self.inset))
                    path.move(to: CGPoint(x: Self.inset, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width - Self.inset, y: size.height / 2))
                }
                .stroke(BrandUI.hairline, lineWidth: 1)

                ForEach(TonePosition.steps, id: \.self) { formality in
                    ForEach(TonePosition.steps, id: \.self) { length in
                        Circle()
                            .fill(BrandUI.goldPale.opacity(0.28))
                            .frame(width: 4, height: 4)
                            .position(
                                point(
                                    for: TonePosition(formality: formality, length: length),
                                    in: size
                                )
                            )
                    }
                }

                Circle()
                    .fill(BrandUI.gold)
                    .overlay(Circle().strokeBorder(BrandUI.goldPale, lineWidth: 1.5))
                    .shadow(color: BrandUI.gold.opacity(0.55), radius: 6)
                    .frame(width: Self.knob, height: Self.knob)
                    .position(point(for: tone, in: size))
                    .animation(.snappy(duration: 0.18), value: tone)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isFocused = true
                        tone = position(at: value.location, in: size)
                    }
            )
        }
        .frame(width: Self.side, height: Self.side)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(formality: -1) }
        .onKeyPress(.rightArrow) { move(formality: 1) }
        .onKeyPress(.upArrow) { move(length: -1) }
        .onKeyPress(.downArrow) { move(length: 1) }
        .accessibilityElement()
        .accessibilityLabel("tone")
        .accessibilityValue(tone.summary)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = move(formality: 1)
            case .decrement: _ = move(formality: -1)
            @unknown default: break
            }
        }
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandUI.bodyFont.weight(.medium))
            .foregroundStyle(BrandUI.textSecondary)
            .accessibilityHidden(true)
    }

    private func move(formality: Int = 0, length: Int = 0) -> KeyPress.Result {
        tone = TonePosition(
            formality: tone.formality + formality,
            length: tone.length + length
        )
        return .handled
    }

    private func point(for tone: TonePosition, in size: CGSize) -> CGPoint {
        let span = CGFloat(TonePosition.steps.count - 1)
        let low = CGFloat(TonePosition.steps.lowerBound)
        let width = size.width - Self.inset * 2
        let height = size.height - Self.inset * 2
        return CGPoint(
            x: Self.inset + (CGFloat(tone.formality) - low) / span * width,
            y: Self.inset + (CGFloat(tone.length) - low) / span * height
        )
    }

    private func position(at location: CGPoint, in size: CGSize) -> TonePosition {
        let span = CGFloat(TonePosition.steps.count - 1)
        let low = CGFloat(TonePosition.steps.lowerBound)
        let width = size.width - Self.inset * 2
        let height = size.height - Self.inset * 2
        let x = ((location.x - Self.inset) / width * span + low).rounded()
        let y = ((location.y - Self.inset) / height * span + low).rounded()
        return TonePosition(formality: Int(x), length: Int(y))
    }
}
