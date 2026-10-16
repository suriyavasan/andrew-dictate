import SwiftUI

/// the list of meetings: a search field, then what is being recorded, then
/// today, yesterday, this week and earlier. rows are drawn by hand rather
/// than by a List so the selection, the hover and the gold flash are the
/// brand's, and so the arrow keys and the scroll are ours to keep honest.
struct MeetingsSidebar: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var showsRecordingRow: Bool {
        state.phase != .idle && state.recordingInto == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
        .background {
            // ⌘⇧F: the search field. plain ⌘F is the transcript's.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: searchText) {
            // typing is not a search on every key.
            if searchText.isEmpty {
                library.query = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { library.query = searchText }
        }
    }

    // MARK: - search

    private var searchField: some View {
        HStack(spacing: MW.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BrandUI.textSecondary)
            TextField("search meetings", text: $searchText)
                .textFieldStyle(.plain)
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textPrimary)
                .focused($searchFocused)
                .onSubmit { listFocused = true }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BrandUI.textSecondary)
                }
                .buttonStyle(.plain)
                .help("clear search")
                .accessibilityLabel("clear search")
            }
        }
        .padding(.horizontal, MW.s12)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BrandUI.gold.opacity(searchFocused ? 0.45 : 0), lineWidth: 1)
        }
        .padding(.horizontal, MW.s12)
        .padding(.top, MW.s8)
        .padding(.bottom, MW.s8)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    // MARK: - the list

    @ViewBuilder
    private var content: some View {
        if library.isSearching, library.sections.isEmpty {
            noResults
        } else if library.sections.isEmpty, !showsRecordingRow {
            Text(library.hasLoaded ? "no meetings yet" : "")
                .font(.system(size: 12))
                .foregroundStyle(BrandUI.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var noResults: some View {
        VStack(spacing: MW.s12) {
            Text("no meetings match “\(library.trimmedQuery)”")
                .font(.system(size: 12))
                .foregroundStyle(BrandUI.textSecondary)
                .multilineTextAlignment(.center)
            Button("clear search") { searchText = "" }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandUI.gold)
        }
        .padding(.horizontal, MW.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var order: [MeetingsLibraryModel.Selection] {
        (showsRecordingRow ? [.recording] : []) + library.visible.map { .meeting($0.id) }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if showsRecordingRow {
                        header("recording", first: true)
                        RecordingRow(
                            state: state,
                            isSelected: library.selection == .recording,
                            showsFocus: listFocused
                        )
                        .id(MeetingsLibraryModel.Selection.recording)
                        .onTapGesture { choose(.recording) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(library.selection == .recording ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { choose(.recording) }
                    }
                    ForEach(Array(library.sections.enumerated()), id: \.element.id) { index, section in
                        header(section.group.title, first: index == 0 && !showsRecordingRow)
                        ForEach(section.items) { item in
                            row(item, group: section.group)
                        }
                    }
                }
                .padding(.horizontal, MW.s8)
                .padding(.bottom, MW.s16)
            }
            .scrollIndicators(.never)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.delete) {
                guard case let .meeting(url)? = library.selection else { return .ignored }
                state.pendingDelete = url
                return .handled
            }
            .onChange(of: library.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    private func header(_ title: String, first: Bool) -> some View {
        BrandSectionHeader(title)
            .padding(.leading, MW.s12)
            .padding(.top, first ? MW.s8 : MW.s16)
            .padding(.bottom, 2)
    }

    private func row(_ item: MeetingsLibraryModel.Item, group: MeetingsLibraryModel.Group) -> some View {
        let url = item.entry.id
        return SidebarRow(
            item: item,
            group: group,
            isSelected: library.selection == .meeting(url),
            isRecording: state.recordingInto == url && state.phase != .idle,
            isSummarizing: summaries.state(for: url) == .summarizing,
            flashes: state.flash == url,
            showsFocus: listFocused
        )
        .id(MeetingsLibraryModel.Selection.meeting(url))
        .onTapGesture { choose(.meeting(url)) }
        .contextMenu { MeetingMenuItems(state: state, library: library, summaries: summaries, entry: item.entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(library.selection == .meeting(url) ? [.isButton, .isSelected] : .isButton)
        // a click is a tap; voiceover's press, and the context menu's lines,
        // are these.
        .accessibilityAction { choose(.meeting(url)) }
        .accessibilityAction(named: "record into this meeting") {
            if !state.isBusy { state.record(into: url) }
        }
        .accessibilityAction(named: "rename") {
            library.selection = .meeting(url)
            state.renameRequest = url
        }
        .accessibilityAction(named: "show in finder") { state.revealInFinder(url) }
        .accessibilityAction(named: "delete") { state.pendingDelete = url }
    }

    private func choose(_ selection: MeetingsLibraryModel.Selection) {
        library.selection = selection
        listFocused = true
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard let next = MeetingsLibraryModel.stepped(library.selection, by: delta, in: order) else {
            return .ignored
        }
        library.selection = next
        return .handled
    }
}

// MARK: - rows

/// how a row says when: `today · 9:30`, `thu · 14:02`, `16 oct · 09:30`.
@MainActor
enum SidebarWhen {
    static func label(
        _ date: Date, group: MeetingsLibraryModel.Group, now: Date = Date(),
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let day: String
        switch group {
        case .today: day = "today"
        case .yesterday: day = "yesterday"
        case .thisWeek: day = format(date, "EEE", calendar, locale)
        case .earlier:
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            day = format(date, sameYear ? "d MMM" : "d MMM yyyy", calendar, locale)
        }
        return "\(day) · \(format(date, "jmm", calendar, locale))".lowercased()
    }

    private static func format(
        _ date: Date, _ template: String, _ calendar: Calendar, _ locale: Locale
    ) -> String {
        MW.date(date, template, calendar: calendar, locale: locale)
    }
}

private struct SidebarRow: View {
    let item: MeetingsLibraryModel.Item
    let group: MeetingsLibraryModel.Group
    let isSelected: Bool
    let isRecording: Bool
    let isSummarizing: Bool
    let flashes: Bool
    /// the list has the keyboard: the selected row says so, since the
    /// list's own focus ring is off.
    let showsFocus: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var glow = 0.0

    private var entry: MeetingsLibraryModel.Entry { item.entry }

    var body: some View {
        HStack(alignment: .top, spacing: MW.s8) {
            status
                .frame(width: 10, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MW.s8) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandUI.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.summary.duration.runningClock)
                        .font(BrandUI.machineFont(size: 11))
                        .foregroundStyle(BrandUI.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(height: 18)
                meta
                    .frame(height: 16)
                lastLine
                    .frame(height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? BrandUI.cardBg : Color.white.opacity(isHovering ? 0.04 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    BrandUI.gold.opacity(isSelected ? (showsFocus ? 0.7 : 0.25) : 0),
                    lineWidth: isSelected && showsFocus ? 1.5 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandUI.gold.opacity(glow))
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .onChange(of: flashes, initial: true) { _, now in
            guard now, !reduceMotion else { return }
            glow = 0.34
            withAnimation(.easeOut(duration: 1.1)) { glow = 0 }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var status: some View {
        if isRecording {
            PulsingRecordDot(size: 6)
        } else if isSummarizing {
            MWSpinner(size: 10, lineWidth: 1.5)
        } else {
            Color.clear
        }
    }

    private var meta: some View {
        HStack(spacing: MW.s8) {
            Text(SidebarWhen.label(entry.summary.started, group: group))
                .font(.system(size: 11))
                .foregroundStyle(BrandUI.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            SpeakerDots(speakers: entry.speakers)
            if entry.summary.sessions > 1 {
                Text("\(entry.summary.sessions) sessions")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BrandUI.gold)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(BrandUI.gold.opacity(0.14)))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var lastLine: some View {
        if isSummarizing {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: proxy.size.width * 0.6, height: 6)
                    .mwShimmer()
                    .frame(maxHeight: .infinity)
            }
        } else {
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(BrandUI.textPrimary.opacity(0.45))
                .lineLimit(1)
        }
    }

    private var line: String {
        if let hit = item.hit { return hit }
        if !entry.hasWords { return "nobody spoke" }
        return entry.snippet
    }
}

/// up to three overlapping dots in the speakers' colours, then how many more.
private struct SpeakerDots: View {
    let speakers: [String]

    var body: some View {
        if !speakers.isEmpty {
            HStack(spacing: 4) {
                HStack(spacing: -4) {
                    ForEach(Array(speakers.prefix(3).enumerated()), id: \.offset) { _, speaker in
                        Circle()
                            .fill(SpeakerInk.color(
                                MeetingTranscriptBlocks.colour(of: speaker, in: speakers)))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(BrandUI.windowBg, lineWidth: 1.5))
                    }
                }
                if speakers.count > 3 {
                    Text("+\(speakers.count - 3)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(BrandUI.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(speakers.count == 1
                ? "1 speaker: \(speakers[0])"
                : "\(speakers.count) speakers: \(speakers.joined(separator: ", "))")
        }
    }
}

/// a red dot with a ring that goes out from it: something is being heard.
struct PulsingRecordDot: View {
    var size: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(MW.recordingRed, lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 0.5)
            }
            Circle()
                .fill(MW.recordingRed)
                .frame(width: size, height: size)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .accessibilityLabel("recording")
    }
}

/// the pinned row for a meeting that has no file yet.
private struct RecordingRow: View {
    @ObservedObject var state: MeetingsWindowState
    let isSelected: Bool
    let showsFocus: Bool

    @State private var isHovering = false

    private var title: String {
        if let typed = state.recordingTitle { return typed }
        return MeetingDocument.untitled(app: state.coordinator.meetings.currentCall ?? "meeting")
    }

    private var phaseLine: String {
        switch state.phase {
        case .idle: ""
        case .gettingReady: "getting ready…"
        case .recording: "recording"
        case .problem: state.phase.menuLine(elapsed: .zero) ?? "recording"
        case .writingOut: "writing it out…"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: MW.s8) {
            PulsingRecordDot(size: 6)
                .frame(width: 10, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MW.s8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandUI.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(state.coordinator.meetings.elapsed.runningClock)
                            .font(BrandUI.machineFont(size: 11))
                            .foregroundStyle(BrandUI.textSecondary)
                            .fixedSize()
                    }
                }
                .frame(height: 18)
                Text(phaseLine)
                    .font(.system(size: 11))
                    .foregroundStyle({
                        if case .problem = state.phase { return BrandUI.attention }
                        return BrandUI.textSecondary
                    }())
                    .lineLimit(1)
                    .frame(height: 16)
                Color.clear.frame(height: 14)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 62)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? BrandUI.cardBg : Color.white.opacity(isHovering ? 0.04 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    BrandUI.gold.opacity(isSelected ? (showsFocus ? 0.7 : 0.25) : 0),
                    lineWidth: isSelected && showsFocus ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

// MARK: - the menu a meeting has

/// the same lines in the row's context menu and the detail's `…` menu.
struct MeetingMenuItems: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries
    let entry: MeetingsLibraryModel.Entry

    private var document: MeetingDocument? { library.document(for: entry.id) }
    private var busy: Bool { summaries.state(for: entry.id) == .summarizing }

    var body: some View {
        Button("record into this meeting") { state.record(into: entry.id) }
            .disabled(state.isBusy)
        Button("rename") {
            library.selection = .meeting(entry.id)
            state.renameRequest = entry.id
        }
        Menu("summarize again") {
            ForEach(MeetingTemplate.builtIn) { template in
                Button {
                    state.summarize(entry.id, templateID: template.id)
                } label: {
                    Label(template.name, systemImage: template.symbol)
                }
            }
        }
        .disabled(busy || !entry.hasWords)
        Divider()
        Button("copy summary") {
            if let notes = document?.summary { MW.copy(notes) }
        }
        .disabled(document?.summary == nil)
        Button("copy transcript") {
            if let document { MW.copy(document.transcriptText) }
        }
        .disabled(document == nil || !entry.hasWords)
        Divider()
        Button("show in finder") { state.revealInFinder(entry.id) }
        Button("delete…", role: .destructive) { state.pendingDelete = entry.id }
    }
}
