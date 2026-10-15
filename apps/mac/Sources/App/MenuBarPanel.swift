import AppKit
import SwiftUI

/// the badge's panel: control center's shape, the app's words. a header
/// that says whether you can talk, the meeting while one runs, two tiles
/// for what you reach for, a list of what needs you that is empty when
/// nothing does, and the app's own lines at the foot.
///
/// the rows are the menu's (ADR 0030): nothing here is configuration
/// that belongs in settings. a tile that switches something (the rewrite,
/// the live transcript) leaves the panel up, like control center's; one
/// that goes somewhere closes it.
struct MenuBarPanel: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var rewrite: RewriteSettings
    @ObservedObject var updates: DailyUpdateCheck
    @ObservedObject var updateHandOff: UpdateHandOff

    @Environment(\.openSettings) private var openSettings
    @State private var window: NSWindow?

    static let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 10) {
            header
            if showsMeetingModule {
                meetingModule
            } else {
                recordTile
            }
            HStack(spacing: 10) {
                rewriteTile
                fixAWordTile
            }
            if !notices.isEmpty {
                noticesModule
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .background(PanelWindowReader { window = $0 })
    }

    /// the panel goes the way a menu goes once something is chosen.
    private func close() {
        window?.close()
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("andrew dictate")
                        .font(.system(size: 13, weight: .semibold))
                    // two badges that look the same is a bad time; the
                    // logo is the logo (ADR 0013), so the mark is here.
                    if Capabilities.current.announcesItself {
                        Text("dev")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .help("dev build — \(AppIdentity.bundleID)")
                    }
                }
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        coordinator.needsAttention ? BrandUI.attention : .secondary
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CircleIconButton(symbol: "gearshape", label: "settings") {
                close()
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    /// whether you can talk. "ready" alone is furniture, so it says how.
    private var statusLine: String {
        if coordinator.needsAttention {
            return "setup isn't finished"
        }
        if coordinator.state != .idle {
            return coordinator.state.displayName
        }
        return "ready · hold \(settings.dictationHotkey.displayName) to talk"
    }

    // MARK: - meetings

    /// a meeting owns the panel's first module while it runs (ADR 0023),
    /// getting ready and writing out included.
    private var showsMeetingModule: Bool {
        coordinator.meetings.isRecording
            || coordinator.meetings.phase.menuLine(elapsed: .zero) != nil
    }

    private var meetingModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RecordingDot(isLive: coordinator.meetings.isRecording)
                // the clock reads the coordinator each second; the menu was
                // drawn once per open, the panel stays up and must tick.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(
                        coordinator.meetings.phase.menuLine(
                            elapsed: coordinator.meetings.elapsed
                        ) ?? "recording"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if coordinator.meetings.isRecording {
                HStack(spacing: 8) {
                    PillButton(
                        coordinator.isLiveTranscriptShown
                            ? "hide live transcript"
                            : "live transcript",
                        symbol: "text.bubble",
                        isOn: coordinator.isLiveTranscriptShown
                    ) {
                        coordinator.toggleLiveTranscript()
                    }
                    Spacer(minLength: 0)
                    PillButton("stop", symbol: "stop.fill", tint: .red) {
                        close()
                        coordinator.stopMeeting()
                    }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelModule()
    }

    /// nothing starts a recording but you (ADR 0023, 0047). a call nobody
    /// records leads the tile's second line for as long as it lasts; the
    /// other meeting models on this mac are behind its chevron.
    private var recordTile: some View {
        HStack(spacing: 0) {
            TileButton(
                symbol: "record.circle",
                title: "record a meeting",
                subtitle: coordinator.unrecordedCall.map {
                    "call in \($0) · not recording"
                } ?? "hears the whole mac",
                isOn: false,
                tint: .red,
                emphasised: coordinator.unrecordedCall != nil
            ) {
                close()
                coordinator.startMeeting()
            }
            let others = coordinator.recordWithChoices
            if !others.isEmpty {
                Menu {
                    Section("record with") {
                        ForEach(others, id: \.model) { choice in
                            Button(choice.title) {
                                close()
                                coordinator.startMeeting(model: choice.model)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 52)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("record with another model")
            }
        }
        .panelModule()
    }

    // MARK: - tiles

    /// a switch, like control center's: the panel stays up.
    private var rewriteTile: some View {
        let modifier = settings.dictationHotkey.rewriteModifier(
            preferring: rewrite.modifier
        )
        return TileButton(
            symbol: "wand.and.sparkles",
            title: "rewrite",
            subtitle: rewrite.isEnabled
                ? "on · \(settings.dictationHotkey.displayName)+\(modifier.symbol)"
                : "off",
            isOn: rewrite.isEnabled,
            tint: BrandUI.gold,
            stacked: true
        ) {
            rewrite.isEnabled.toggle()
        }
        .panelModule()
        .accessibilityValue(rewrite.isEnabled ? "on" : "off")
    }

    /// the one time-sensitive action (ADR 0030): you just watched it
    /// mishear a name.
    private var fixAWordTile: some View {
        TileButton(
            symbol: "character.cursor.ibeam",
            title: "fix a word",
            subtitle: coordinator.lastHeard == nil
                ? "after your first dictation"
                : "teach it a misheard word",
            isOn: false,
            tint: BrandUI.gold,
            stacked: true
        ) {
            close()
            coordinator.openWordFixer()
        }
        .disabled(coordinator.lastHeard == nil)
        .panelModule()
    }

    // MARK: - what needs you

    private struct Notice: Identifiable {
        let id: String
        let symbol: String
        let text: String
        let action: String
        var isAttention = false
        var isEnabled = true
        let perform: () -> Void
    }

    /// zero rows when everything works. each one goes on its own when it
    /// is no longer true, as the menu's rows did.
    private var notices: [Notice] {
        var notices: [Notice] = []
        if coordinator.needsAttention {
            notices.append(Notice(
                id: "setup", symbol: "exclamationmark.triangle.fill",
                text: "setup isn't finished", action: "finish",
                isAttention: true
            ) { [coordinator] in
                coordinator.runOnboardingAgain()
            })
        }
        if !coordinator.meetings.isRecording, coordinator.meetingsNeedAttention {
            notices.append(Notice(
                id: "systemAudio", symbol: "speaker.slash.fill",
                text: "meetings can't hear the mac", action: "fix…",
                isAttention: true
            ) { [coordinator] in
                coordinator.runOnboardingAgain(
                    scope: .meetingsOnly, openAt: .permissions)
            })
        }
        if !coordinator.meetings.isRecording, coordinator.canRetryLastFailure {
            notices.append(Notice(
                id: "retry", symbol: "arrow.clockwise",
                text: "the last take didn't land", action: "try again"
            ) { [coordinator] in
                coordinator.retryLastFailure()
            })
        }
        if !coordinator.meetings.isRecording,
           let learned = coordinator.undoableLearning {
            notices.append(Notice(
                id: "learned", symbol: "book.closed",
                text: "learned \(learned.right)", action: "undo"
            ) { [coordinator] in
                coordinator.undoLearning()
            })
        }
        if !coordinator.meetings.isRecording, coordinator.showsLastMeetingRow {
            notices.append(Notice(
                id: "lastMeeting", symbol: "doc.text",
                text: "the meeting is saved", action: "show in finder"
            ) { [coordinator] in
                coordinator.revealLastMeeting()
            })
        }
        // a newer version is a line and nothing else (ADR 0043), and waits
        // for a meeting to end.
        if !coordinator.meetings.isRecording,
           let line = updateHandOff.state(offering: updates.line) {
            notices.append(Notice(
                id: "update", symbol: "arrow.down.circle",
                text: line.title, action: Self.updateAction(line),
                isEnabled: line.isEnabled
            ) { [updateHandOff, updates] in
                updateHandOff.click(offering: updates.line)
            })
        }
        return notices
    }

    private static func updateAction(_ line: UpdateOffer.LineState) -> String {
        switch line {
        case .available: "update"
        case .updating: "updating…"
        case .restartToFinish: "restart"
        case .failedCopied: "try again"
        }
    }

    private var noticesModule: some View {
        VStack(spacing: 0) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                if index > 0 {
                    Divider().padding(.leading, 40)
                }
                HStack(spacing: 10) {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(notice.isAttention ? BrandUI.attention : .secondary)
                        .frame(width: 20)
                    Text(notice.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    PillButton(notice.action, isEnabled: notice.isEnabled) {
                        close()
                        notice.perform()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 2)
        .panelModule()
    }

    // MARK: - foot

    private var footer: some View {
        VStack(spacing: 6) {
            if hasDevRow {
                HStack(spacing: 4) {
                    if Capabilities.current.canResetInPlace {
                        FooterButton("reset & relaunch") {
                            close()
                            coordinator.resetInPlaceForDevelopment()
                        }
                    }
                    #if DEBUG
                    if Capabilities.current.hasLampLab {
                        FooterButton("lamp lab") {
                            close()
                            coordinator.openLampLab()
                        }
                        FooterButton("rehearse the lamp") {
                            close()
                            coordinator.rehearseHUDForDevelopment()
                        }
                    }
                    #endif
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 4) {
                FooterButton("about") {
                    close()
                    coordinator.openAbout()
                }
                // what a friend sends instead of a story: the last fifty
                // presses and how each ended, never a word of what was said.
                FooterButton("copy diagnostics") {
                    close()
                    coordinator.copyDiagnostics()
                }
                Spacer(minLength: 0)
                FooterButton("quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(.top, 2)
    }

    private var hasDevRow: Bool {
        #if DEBUG
        Capabilities.current.canResetInPlace || Capabilities.current.hasLampLab
        #else
        Capabilities.current.canResetInPlace
        #endif
    }
}

// MARK: - the pieces

/// a control center module: a rounded, faintly lit surface.
private struct PanelModule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension View {
    func panelModule() -> some View {
        modifier(PanelModule())
    }
}

/// control center's tile: a round glyph, lit in the tint when on, and a
/// title with a line under it. `stacked` puts the glyph above the words,
/// for the half-width tiles.
private struct TileButton: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let tint: Color
    var emphasised = false
    var stacked = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 8) {
                        glyph
                        words
                    }
                } else {
                    HStack(spacing: 10) {
                        glyph
                        words
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.primary.opacity(isHovered && isEnabled ? 0.06 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOn ? Color.black.opacity(0.85) : (emphasised ? tint : .primary))
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.10)))
            )
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(emphasised ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }
}

/// a small capsule: the action at the end of a row, or a meeting's stop.
private struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color?
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    init(
        _ title: String,
        symbol: String? = nil,
        tint: Color? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.action = action
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }

    private var foreground: AnyShapeStyle {
        if tint != nil || isOn {
            return AnyShapeStyle(Color.white)
        }
        return AnyShapeStyle(.primary)
    }

    private var background: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint.opacity(isHovered ? 1 : 0.85))
        }
        if isOn {
            return AnyShapeStyle(BrandUI.goldDeep)
        }
        return AnyShapeStyle(.primary.opacity(isHovered ? 0.16 : 0.10))
    }
}

/// the header's round button: settings.
private struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.primary.opacity(isHovered ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// the foot's quiet lines, lit on hover like a menu row.
private struct FooterButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// a meeting's red dot, breathing while it records.
private struct RecordingDot: View {
    let isLive: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isLive ? Color.red : Color.secondary)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.35 : 1)
            .animation(
                isLive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { dim = isLive }
            .onChange(of: isLive) { dim = isLive }
            .accessibilityHidden(true)
    }
}

/// the window the panel is drawn in, for closing it the way a menu
/// closes: `MenuBarExtra` has no dismiss of its own.
private struct PanelWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            found(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in
            found(view.window)
        }
    }
}
