import SwiftUI

/// the bar at the bottom of the window, over whatever is open: record, or
/// stop, and what the meeting is doing. it reflects `MeetingPhase` and
/// nothing of its own — a click calls the coordinator, whose guards and
/// pills stay the truth, and the bar follows what comes back.
struct MeetingRecordBar: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// what the bar is showing, coarser than the phase: the problem's own
    /// words do not make a new face.
    fileprivate enum Face: Equatable {
        case idle, gettingReady, recording, problem, writingOut
    }

    private var face: Face {
        switch state.phase {
        case .idle: .idle
        case .gettingReady: .gettingReady
        case .recording: .recording
        case .problem: .problem
        case .writingOut: .writingOut
        }
    }

    var body: some View {
        HStack(spacing: MW.s16) {
            RecordStopButton(face: face, glows: library.hasLoaded && library.entries.isEmpty) {
                switch face {
                case .idle: state.record()
                case .recording, .problem: state.stop()
                case .gettingReady, .writingOut: break
                }
            }
            controls
        }
        .padding(.horizontal, MW.s16)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .overlay {
            // a faint red along the top edge while the mic is open.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [MW.recordingRed.opacity(0.08), .clear],
                    startPoint: .top, endPoint: .center))
                .opacity(face == .recording || face == .problem ? 1 : 0)
                .allowsHitTesting(false)
        }
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BrandUI.gold.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, MW.s12)
        .padding(.bottom, MW.s12)
        .animation(MW.animation(MW.barSpring, reduceMotion: reduceMotion), value: face)
    }

    // MARK: what sits beside the button

    @ViewBuilder
    private var controls: some View {
        switch face {
        case .idle:
            HStack(spacing: MW.s16) {
                RecordIntoMenu(state: state, library: library)
                    .mwAppear(0)
                if state.target == .new {
                    TitleField(state: state).mwAppear(1)
                }
                Spacer(minLength: 0)
                trailingNote.mwAppear(2)
            }
            .transition(.asymmetric(insertion: .identity, removal: .identity))
        case .gettingReady:
            HStack(spacing: MW.s16) {
                Text("getting ready…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BrandUI.textSecondary)
                    .mwAppear(0)
                Spacer(minLength: 0)
            }
        case .recording, .problem:
            HStack(spacing: MW.s16) {
                PulsingRecordDot(size: 10).frame(width: 10, height: 10).mwAppear(0)
                RecordingClock(state: state, color: BrandUI.textPrimary).mwAppear(1)
                if case let .problem(problem) = state.phase {
                    Text(MeetingEvent.problemBegan(problem).hudText ?? "something is wrong")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BrandUI.attention)
                        .lineLimit(2)
                        .layoutPriority(2)
                        .mwAppear(2)
                } else {
                    LevelMeter(feed: state.coordinator.meetingLevels).mwAppear(2)
                }
                intoChip.mwAppear(3)
                Spacer(minLength: 0)
                liveToggle.mwAppear(4)
            }
        case .writingOut:
            HStack(spacing: MW.s16) {
                RecordingClock(state: state, color: BrandUI.goldPale).mwAppear(0)
                Text("writing it out…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandUI.textSecondary)
                    .mwAppear(1)
                Spacer(minLength: 0)
            }
        }
    }

    /// after a save, while the notes are being written; otherwise what the
    /// meeting will hear.
    @ViewBuilder
    private var trailingNote: some View {
        if let saved = state.lastSaved, summaries.state(for: saved) == .summarizing {
            HStack(spacing: 6) {
                MWSpinner(size: 12, lineWidth: 1.5)
                Text("summarizing…")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandUI.gold)
            }
            .fixedSize()
        } else {
            HStack(spacing: MW.s8) {
                SourceChip(symbol: "mic.fill", label: "mic", isWrong: false)
                SourceChip(
                    symbol: "speaker.wave.2.fill", label: "mac audio",
                    isWrong: state.cannotHearTheMac)
            }
            .fixedSize()
        }
    }

    /// "into stand-up": which meeting this adds to, or the name given to a
    /// new one.
    @ViewBuilder
    private var intoChip: some View {
        if let text = chipText {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandUI.goldPale)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(BrandUI.gold.opacity(0.14)))
                .frame(maxWidth: 220)
        }
    }

    private var chipText: String? {
        if let into = state.recordingInto {
            return "into \(library.entry(for: into)?.title ?? "this meeting")"
        }
        return state.recordingTitle
    }

    private var liveToggle: some View {
        Button {
            state.toggleLiveTranscript()
        } label: {
            Image(systemName: "text.bubble")
                .symbolVariant(state.isLiveTranscriptShown ? .fill : .none)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.isLiveTranscriptShown ? BrandUI.gold : BrandUI.textSecondary)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(Color.white.opacity(state.isLiveTranscriptShown ? 0.10 : 0.05))
                }
        }
        .buttonStyle(.plain)
        .help(state.isLiveTranscriptShown ? "hide the live transcript window" : "show the live transcript window")
        .accessibilityLabel("live transcript window")
        .accessibilityValue(state.isLiveTranscriptShown ? "shown" : "hidden")
        .accessibilityAddTraits(state.isLiveTranscriptShown ? .isSelected : [])
    }
}

// MARK: - the button

/// one shape that is the record button, the stop button and the end of
/// both: a red core that is a circle when idle and a rounded square when
/// recording, inside a ring that is white at rest and a gold arc going round
/// while the mic warms up or the file is written.
private struct RecordStopButton: View {
    let face: MeetingRecordBar.Face
    let glows: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false
    @State private var isHovering = false

    private var side: CGFloat {
        switch face {
        case .idle, .gettingReady: 22
        case .recording, .problem: 18
        case .writingOut: 0
        }
    }

    private var radius: CGFloat {
        switch face {
        case .idle, .gettingReady: 11
        case .recording, .problem: 6
        case .writingOut: 0
        }
    }

    private var isWorking: Bool { face == .gettingReady || face == .writingOut }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .opacity(isWorking ? 0.18 : 1)
                if isWorking {
                    MWSpinner(size: 44, lineWidth: 2.5)
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(MW.recordingRed)
                    .frame(width: side, height: side)
                    .opacity(face == .gettingReady ? 0.45 : 1)
                    .shadow(color: MW.recordingRed.opacity(glows && face == .idle ? (glow ? 0.35 : 0.15) : 0),
                            radius: 10)
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isHovering && !isWorking ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(isWorking)
        .onHover { isHovering = $0 }
        .animation(MW.animation(MW.morphSpring, reduceMotion: reduceMotion), value: face)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onAppear {
            guard glows, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { glow = true }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        switch face {
        case .idle: "record a meeting"
        case .gettingReady: "getting ready"
        case .recording, .problem: "stop recording"
        case .writingOut: "writing it out"
        }
    }

    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - the clock and the meter

/// mm:ss, then h:mm:ss after an hour, ticking in place.
private struct RecordingClock: View {
    let state: MeetingsWindowState
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let clock = state.coordinator.meetings.elapsed.runningClock
            Text(clock)
                .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: clock)
                .fixedSize()
                .accessibilityLabel("recording time")
                .accessibilityValue(clock)
        }
    }
}

/// 24 bars, newest on the right, each as loud as the room was a moment
/// ago: the louder of the two sides, since it is the meeting that is loud.
private struct LevelMeter: View {
    let feed: MeetingLevelsFeed

    private static let count = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history = Array(repeating: Float(0), count: LevelMeter.count)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.count, id: \.self) { index in
                let level = CGFloat(history[index])
                Capsule()
                    .fill(BrandUI.gold.mix(with: BrandUI.goldPale, by: Double(level)))
                    .frame(width: 3, height: 4 + level * 24)
            }
        }
        .frame(width: CGFloat(Self.count) * 3 + CGFloat(Self.count - 1) * 2, height: 28)
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.6),
            value: history)
        .task {
            // read on a beat, not on each change: a quiet room publishes
            // nothing, and the bars should still walk across.
            let beat: Duration = reduceMotion ? .milliseconds(100) : .milliseconds(66)
            while !Task.isCancelled {
                let levels = feed.levels
                history.removeFirst()
                history.append(max(levels.you, levels.them))
                try? await Task.sleep(for: beat)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - idle controls

/// which meeting the next recording goes into.
private struct RecordIntoMenu: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel

    private var selected: MeetingsLibraryModel.Entry? {
        if case let .meeting(url)? = library.selection { library.entry(for: url) } else { nil }
    }

    private var targetName: String {
        if case let .meeting(url) = state.target, let entry = library.entry(for: url) {
            return entry.title
        }
        return "new meeting"
    }

    var body: some View {
        Menu {
            Button {
                state.target = .new
            } label: {
                if state.target == .new {
                    Label("new meeting", systemImage: "checkmark")
                } else {
                    Text("new meeting")
                }
            }
            if let selected {
                Divider()
                choice(selected)
            }
            let recent = library.entries.filter { $0.id != selected?.id }.prefix(6)
            if !recent.isEmpty {
                Divider()
                Menu("recent meetings") {
                    ForEach(Array(recent)) { entry in choice(entry) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("record into")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandUI.textSecondary)
                Text(targetName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BrandUI.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .padding(.horizontal, MW.s12)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("where the recording goes")
    }

    private func choice(_ entry: MeetingsLibraryModel.Entry) -> some View {
        Button {
            state.target = .meeting(entry.id)
        } label: {
            if state.target == .meeting(entry.id) {
                Label(entry.title, systemImage: "checkmark")
            } else {
                Text(entry.title)
            }
        }
    }
}

/// a name for the new meeting, if you want one.
private struct TitleField: View {
    @ObservedObject var state: MeetingsWindowState
    @FocusState private var focused: Bool

    var body: some View {
        TextField("name it (optional)", text: $state.newTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(BrandUI.textPrimary)
            .focused($focused)
            .onSubmit { state.record() }
            .padding(.horizontal, MW.s12)
            .frame(height: 32)
            .frame(minWidth: 140, maxWidth: 260)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .overlay(Capsule().stroke(BrandUI.gold.opacity(focused ? 0.45 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// what the meeting hears: the mic, and the mac. red-orange when the mac
/// could not be heard last time.
private struct SourceChip: View {
    let symbol: String
    let label: String
    let isWrong: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(isWrong ? BrandUI.attention : BrandUI.textSecondary)
        .padding(.horizontal, MW.s8)
        .frame(height: 24)
        .overlay(Capsule().stroke(isWrong ? BrandUI.attention.opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1))
        .help(isWrong ? "the mac could not be heard last time" : "heard while recording")
        // the colour says it to the eye; this says it to voiceover.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isWrong ? "could not be heard last time" : "")
    }
}

// MARK: - appearing

/// a control coming in as the bar changes: fades up from 90%, a beat
/// after the one before it.
private struct Appear: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.9)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(MW.barSpring.delay(Double(index) * 0.04)) { shown = true }
                }
            }
    }
}

private extension View {
    func mwAppear(_ index: Int) -> some View { modifier(Appear(index: index)) }
}
