import SwiftUI

/// one meeting: its name and what you can do with it across the top, then
/// the notes on the left and what was said on the right. below 760pt of
/// width the two cannot both be read, so they become a pair of tabs.
struct MeetingDetailView: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries
    let entry: MeetingsLibraryModel.Entry
    let document: MeetingDocument

    var body: some View {
        VStack(spacing: 0) {
            MeetingDetailHeader(
                state: state, library: library, summaries: summaries,
                entry: entry, document: document)
            Divider().overlay(BrandUI.hairline)
            MeetingSplit {
                MeetingSummaryPane(
                    url: entry.id, document: document, summaries: summaries,
                    settings: state.coordinator.rewriteSettings,
                    accounts: state.coordinator.rewriteAccounts,
                    summarize: { state.summarize(entry.id, templateID: currentTemplate.id) })
            } transcript: {
                MeetingTranscriptPane(
                    document: document,
                    live: isRecordingIntoThis ? state.coordinator.liveTranscript : nil,
                    namer: isRecordingIntoThis ? nil : namer)
            }
        }
    }

    /// naming a speaker rewrites the file, then the list reads it again.
    private var namer: SpeakerNamer {
        let document = document
        let url = entry.id
        let library = library
        return SpeakerNamer(
            isNameable: { !document.isYou($0) },
            revertLabel: { shown in
                guard !SpeakerNames.isOriginal(shown) else { return nil }
                return MeetingTranscriptFile.origins(of: shown, in: document.header.voices).first
            },
            suggestions: { library.knownNames() },
            apply: { shown, name in
                Task { await library.nameSpeaker(shown, as: name, in: url) }
            })
    }

    private var currentTemplate: MeetingTemplate {
        MeetingTemplate.resolving(
            document.header.template ?? state.coordinator.rewriteSettings.defaultTemplateID)
    }

    private var isRecordingIntoThis: Bool {
        state.recordingInto == entry.id && state.phase != .idle
    }
}

/// the meeting being recorded, which has no file yet: the same two panes,
/// with the notes waiting for the end and the transcript following the talk.
struct RecordingDetailView: View {
    @ObservedObject var state: MeetingsWindowState

    private var title: String {
        if let typed = state.recordingTitle { return typed }
        return MeetingDocument.untitled(app: state.coordinator.meetings.currentCall ?? "meeting")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: MW.s12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BrandUI.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PulsingRecordDot(size: 6)
                            .frame(width: 8, height: 8)
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text("recording · \(state.coordinator.meetings.elapsed.runningClock)")
                                .font(BrandUI.machineFont(size: 11))
                                .foregroundStyle(BrandUI.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MW.s16)
            .frame(height: 56)
            Divider().overlay(BrandUI.hairline)
            MeetingSplit {
                VStack(spacing: 0) {
                    MWPaneHeader(title: "summary") { EmptyView() }
                    VStack(spacing: MW.s8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18))
                            .foregroundStyle(BrandUI.gold.opacity(0.75))
                            .accessibilityHidden(true)
                        Text("the notes are written when the meeting ends")
                            .font(.system(size: 12))
                            .foregroundStyle(BrandUI.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(MW.s24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } transcript: {
                MeetingTranscriptPane(
                    document: nil, live: state.coordinator.liveTranscript)
            }
        }
    }
}

/// the two panes side by side, 55 and 45, or one at a time under a switch.
struct MeetingSplit<Summary: View, Transcript: View>: View {
    @ViewBuilder var summary: Summary
    @ViewBuilder var transcript: Transcript

    private enum Side: String, CaseIterable {
        case summary, transcript
    }

    @State private var side = Side.summary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var collapsesBelow: CGFloat { 760 }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.collapsesBelow {
                HStack(spacing: 0) {
                    summary
                        .frame(width: max(340, (proxy.size.width - 1) * 0.55))
                    Rectangle().fill(BrandUI.hairline).frame(width: 1)
                    transcript
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("show", selection: $side) {
                        ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, MW.s16)
                    .padding(.top, MW.s12)
                    .padding(.bottom, MW.s8)
                    switch side {
                    case .summary: summary
                    case .transcript: transcript
                    }
                }
            }
        }
    }
}

// MARK: - header

private struct MeetingDetailHeader: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries
    let entry: MeetingsLibraryModel.Entry
    let document: MeetingDocument

    @State private var draft = ""
    @FocusState private var editing: Bool
    @State private var isHoveringTitle = false

    private var url: URL { entry.id }
    private var isSummarizing: Bool { summaries.state(for: url) == .summarizing }
    private var currentTemplate: MeetingTemplate {
        MeetingTemplate.resolving(
            document.header.template ?? state.coordinator.rewriteSettings.defaultTemplateID)
    }

    var body: some View {
        HStack(spacing: MW.s12) {
            titleBlock
            Spacer(minLength: MW.s8)
            HStack(spacing: 4) {
                templateMenu
                MWIconButton(
                    symbol: "arrow.clockwise", help: "write the notes again",
                    isDisabled: isSummarizing || !document.hasWords
                ) {
                    state.summarize(url, templateID: currentTemplate.id)
                }
                copyMenu
                MWIconButton(symbol: "folder", help: "show in finder") {
                    state.revealInFinder(url)
                }
                moreMenu
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, MW.s16)
        .frame(height: 56)
        .onAppear {
            draft = entry.title
            takeRenameRequest()
        }
        .onChange(of: entry.title) { _, title in
            if !editing { draft = title }
        }
        .onChange(of: state.renameRequest) { _, _ in takeRenameRequest() }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { commit() }
        }
    }

    private func takeRenameRequest() {
        guard state.renameRequest == url else { return }
        state.renameRequest = nil
        editing = true
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("name this meeting", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(BrandUI.textPrimary)
                .focused($editing)
                .onSubmit { commit(); editing = false }
                .onExitCommand { draft = entry.title; editing = false }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(editing ? 0.07 : (isHoveringTitle ? 0.04 : 0)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(BrandUI.gold.opacity(editing ? 0.45 : 0), lineWidth: 1)
                }
                .onHover { isHoveringTitle = $0 }
                .help("click to rename")
                // the field sits 6pt in so its text lines up with the line below.
                .padding(.leading, -6)
            Text(meta)
                .font(BrandUI.machineFont(size: 11))
                .foregroundStyle(BrandUI.textSecondary)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.12), value: isHoveringTitle)
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != entry.title else { return }
        Task {
            await library.rename(url, to: name)
            draft = entry.title
        }
    }

    /// `thu 16 oct · 09:30 · 42m · 3 speakers · 2 sessions`
    private var meta: String {
        let started = document.header.started
        var parts = ["\(MW.date(started, "EEE d MMM")) · \(MW.date(started, "jmm"))".lowercased()]
        parts.append(document.header.duration.spoken)
        let speakers = document.speakers.count
        if speakers > 0 { parts.append(speakers == 1 ? "1 speaker" : "\(speakers) speakers") }
        if document.sessions.count > 1 { parts.append("\(document.sessions.count) sessions") }
        return parts.joined(separator: " · ")
    }

    // MARK: menus

    private var templateMenu: some View {
        Menu {
            ForEach(MeetingTemplate.builtIn) { template in
                Button {
                    state.summarize(url, templateID: template.id)
                } label: {
                    if template.id == currentTemplate.id {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentTemplate.symbol).font(.system(size: 11, weight: .medium))
                Text(currentTemplate.name).font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .foregroundStyle(BrandUI.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isSummarizing || !document.hasWords)
        .help("the shape of the notes")
    }

    private var copyMenu: some View {
        Menu {
            Button("copy summary") { MW.copy(MeetingsLibraryModel.text(.summary, of: document)) }
                .disabled(document.summary == nil)
            Button("copy transcript") { MW.copy(MeetingsLibraryModel.text(.transcript, of: document)) }
                .disabled(!document.hasWords)
            Button("copy both") { MW.copy(MeetingsLibraryModel.text(.both, of: document)) }
        } label: {
            MWIconLabel(symbol: "square.on.square")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("copy")
        .accessibilityLabel("copy")
    }

    private var moreMenu: some View {
        Menu {
            Button("rename") { editing = true }
            Button("record into this meeting") { state.record(into: url) }
                .disabled(state.isBusy)
            Divider()
            Button("delete…", role: .destructive) { state.pendingDelete = url }
        } label: {
            MWIconLabel(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("more")
        .accessibilityLabel("more")
    }
}
