import SwiftUI

/// what was said, on the right: a paragraph to a row, who said it, when,
/// with a find field over it. while the meeting is being recorded it
/// follows the talk and stays at the bottom, unless you have scrolled up to
/// read, in which case a pill offers the way back.
struct MeetingTranscriptPane: View {
    /// the file, or nil for a meeting that has none yet.
    let document: MeetingDocument?
    /// the streaming pass, while the meeting is being recorded.
    let live: LiveTranscriptModel?

    var body: some View {
        if let live {
            LiveBody(document: document, live: live)
        } else if let document {
            PaneBody(items: MeetingTranscriptBlocks.items(for: document), document: document, isLive: false)
        } else {
            EmptyView()
        }
    }

    /// the live model is watched here and only here: the lines change as
    /// often as people talk.
    private struct LiveBody: View {
        let document: MeetingDocument?
        @ObservedObject var live: LiveTranscriptModel

        var body: some View {
            let known = document?.speakers ?? []
            let before = document.map(MeetingTranscriptBlocks.items(for:)) ?? []
            // a meeting recorded into again gets its new session announced.
            let marker: [MeetingTranscriptBlocks.Item] = document == nil || live.lines.isEmpty
                ? [] : [.init(id: "session-live", kind: .session("now"))]
            PaneBody(
                items: before + marker
                    + MeetingTranscriptBlocks.items(live: live.lines, knownSpeakers: known),
                document: document, isLive: true)
        }
    }

    private struct PaneBody: View {
        let items: [MeetingTranscriptBlocks.Item]
        let document: MeetingDocument?
        let isLive: Bool

        @State private var query = ""
        @State private var current = 0
        @State private var followsLive = true
        @FocusState private var findFocused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var matches: [MeetingTranscriptFind.Match] {
            MeetingTranscriptFind.matches(in: items, for: query)
        }

        var body: some View {
            let found = matches
            VStack(spacing: 0) {
                MWPaneHeader(title: "transcript") {
                    findField(count: found.count)
                    MWCopyButton(
                        help: "copy the transcript", isDisabled: document?.hasWords != true
                    ) {
                        document?.transcriptText ?? ""
                    }
                }
                transcript(found)
            }
            .background {
                // ⌘F: the find field.
                Button("") { findFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }

        // MARK: find

        private func findField(count: Int) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BrandUI.textSecondary)
                TextField("find", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(BrandUI.textPrimary)
                    .focused($findFocused)
                    .onSubmit { step(1, of: count) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        step(-1, of: count)
                        return .handled
                    }
                    .onExitCommand {
                        query = ""
                        findFocused = false
                    }
                if !query.isEmpty {
                    Text(count == 0 ? "none" : "\(min(current, count - 1) + 1) of \(count)")
                        .font(BrandUI.machineFont(size: 10))
                        .foregroundStyle(BrandUI.textSecondary)
                        .fixedSize()
                    Button {
                        step(-1, of: count)
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
                    .disabled(count == 0)
                    .accessibilityLabel("previous match")
                    Button {
                        step(1, of: count)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
                    .disabled(count == 0)
                    .accessibilityLabel("next match")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(minWidth: 96, maxWidth: 240)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(BrandUI.gold.opacity(findFocused ? 0.45 : 0), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.15), value: findFocused)
        }

        private func step(_ delta: Int, of count: Int) {
            guard count > 0 else { return }
            current = MeetingTranscriptFind.step(min(current, count - 1), by: delta, of: count)
        }

        // MARK: rows

        @ViewBuilder
        private func transcript(_ found: [MeetingTranscriptFind.Match]) -> some View {
            if items.isEmpty {
                Text(isLive ? "listening…" : "nobody said anything.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scroller(found)
            }
        }

        private func scroller(_ found: [MeetingTranscriptFind.Match]) -> some View {
            let active = found.isEmpty ? nil : found[min(current, found.count - 1)]
            return ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TranscriptRow(
                                item: item, isFirst: index == 0, query: query,
                                activeOccurrence: active?.itemID == item.id ? active?.occurrence : nil)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, MW.s16)
                    .padding(.top, MW.s8)
                    .padding(.bottom, MW.s24)
                    .textSelection(.enabled)
                    .animation(
                        MW.animation(.spring(response: 0.35, dampingFraction: 0.85), reduceMotion: reduceMotion),
                        value: items.count)
                }
                .scrollIndicators(.automatic)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 32
                } action: { _, atBottom in
                    followsLive = atBottom
                }
                .onChange(of: items.last?.id) { _, _ in
                    guard isLive, followsLive else { return }
                    scrollToEnd(proxy)
                }
                .onChange(of: current) { _, _ in scrollToActive(active: active, proxy: proxy) }
                .onChange(of: query) { _, _ in
                    current = 0
                    let first = MeetingTranscriptFind.matches(in: items, for: query).first
                    if let first {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(first.itemID, anchor: .center) }
                    }
                }
                .onAppear {
                    if isLive { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isLive, !followsLive {
                        jumpToLive { scrollToEnd(proxy) }
                            .padding(MW.s16)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(
                    MW.animation(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion),
                    value: followsLive)
            }
        }

        private static let bottom = "transcript-bottom"

        private func scrollToEnd(_ proxy: ScrollViewProxy) {
            withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }

        private func scrollToActive(active: MeetingTranscriptFind.Match?, proxy: ScrollViewProxy) {
            guard let active else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(active.itemID, anchor: .center) }
        }

        private func jumpToLive(_ action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
                    Text("jump to live").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(BrandUI.textPrimary)
                .padding(.horizontal, MW.s12)
                .frame(height: 30)
                .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: Capsule())
                .overlay(Capsule().stroke(BrandUI.gold.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - one row

private struct TranscriptRow: View {
    let item: MeetingTranscriptBlocks.Item
    let isFirst: Bool
    let query: String
    let activeOccurrence: Int?

    var body: some View {
        switch item.kind {
        case let .session(heading):
            sessionHeading(heading)
        case let .turn(turn):
            paragraph(turn)
                .padding(.top, isFirst ? 0 : (turn.beginsRun ? MW.s16 : MW.s8))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func sessionHeading(_ heading: String) -> some View {
        HStack(spacing: MW.s12) {
            Rectangle().fill(BrandUI.hairline).frame(height: 1)
            Text(heading)
                .font(BrandUI.machineFont(size: 11))
                .foregroundStyle(BrandUI.gold.opacity(0.75))
                .fixedSize()
            Rectangle().fill(BrandUI.hairline).frame(height: 1)
        }
        .padding(.top, isFirst ? 0 : MW.s24)
        .padding(.bottom, MW.s8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func paragraph(_ turn: MeetingTranscriptBlocks.Turn) -> some View {
        let ink = SpeakerInk.color(turn.colour)
        return HStack(alignment: .top, spacing: MW.s12) {
            Text(turn.at.runningClock)
                .font(BrandUI.machineFont(size: 11))
                .foregroundStyle(BrandUI.textSecondary)
                .frame(width: 54, alignment: .leading)
                .padding(.top, turn.beginsRun ? 3 : 2)
            VStack(alignment: .leading, spacing: 4) {
                if turn.beginsRun {
                    Text(turn.speaker)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Capsule().fill(ink.opacity(0.16)))
                        .overlay(Capsule().stroke(ink.opacity(0.3), lineWidth: 1))
                }
                Text(highlighted(turn.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundStyle(BrandUI.textPrimary)
                    .opacity(turn.isConfirmed ? 1 : 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .overlay(alignment: .leading) {
                // a run carries on: the speaker's colour, in the gutter.
                if !turn.beginsRun {
                    Capsule().fill(ink.opacity(0.6)).frame(width: 2)
                        .offset(x: -7)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(turn.speaker), \(turn.at.runningClock): \(turn.text)")
    }

    /// the find field's matches lit pale gold, the one you are on in gold
    /// with a line under it.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        for (index, range) in MeetingTranscriptFind.ranges(of: needle, in: text).enumerated() {
            guard let found = Range(range, in: attributed) else { continue }
            if index == activeOccurrence {
                attributed.paint(found, background: BrandUI.gold.opacity(0.55))
                attributed.underline(found)
            } else {
                attributed.paint(found, background: BrandUI.goldPale.opacity(0.35))
            }
        }
        return attributed
    }
}
