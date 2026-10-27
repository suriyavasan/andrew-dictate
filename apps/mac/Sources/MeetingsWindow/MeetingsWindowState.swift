import AppKit
import Combine
import SwiftUI

/// what the meetings window knows beyond its list: what the meeting
/// machinery is doing, where the next recording goes, which row to flash.
///
/// the coordinator is the truth about recording — its guards and its pills
/// stay in charge — so this only mirrors it. it watches the coordinator and
/// copies out the few values the window draws, publishing each only when it
/// changes: the coordinator announces a change every second while a meeting
/// runs, and a window that redrew for every one would redraw its notes and
/// its transcript for nothing. the clock and the meter read the live values
/// themselves.
@MainActor
final class MeetingsWindowState: ObservableObject {
    /// where a recording started from the bar goes.
    enum Target: Equatable {
        case new
        case meeting(URL)
    }

    let library: MeetingsLibraryModel
    let coordinator: DictationCoordinator

    @Published private(set) var phase: MeetingPhase = .idle
    @Published private(set) var isLiveTranscriptShown = false
    /// the last meeting could not hear the mac: the bar says so on its chip.
    @Published private(set) var cannotHearTheMac = false
    /// the meeting being recorded into, while one is; nil for a new one.
    @Published private(set) var recordingInto: URL?
    /// what the new meeting was named in the bar, if it was, for the row that
    /// stands for it until it has a file.
    @Published private(set) var recordingTitle: String?
    /// the file a meeting was last saved to, for the bar to say it is
    /// being summarized.
    @Published private(set) var lastSaved: URL?
    /// the row that gold-flashes once: the meeting that was just saved.
    @Published private(set) var flash: URL?
    @Published var target: Target = .new
    /// what the bar's title field holds, for a new meeting.
    @Published var newTitle = ""
    /// the meeting a delete is waiting to be confirmed for.
    @Published var pendingDelete: URL?
    /// asked to start renaming: the open detail takes the focus.
    @Published var renameRequest: URL?

    private var seenRevision: Int
    /// when the last save was, not where: recording into the same meeting
    /// twice saves the same file twice.
    private var seenSavedAt: Date?
    private var watching: AnyCancellable?
    private var selectionBeforeRecording: MeetingsLibraryModel.Selection?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        let keptAudio = KeptAudio()
        library = MeetingsLibraryModel(
            load: { [] },
            delete: { url in try MeetingRemoval.remove(url, keptAudio: keptAudio) })
        seenRevision = coordinator.meetingsRevision
        seenSavedAt = coordinator.lastMeetingSavedAt
        lastSaved = coordinator.lastMeeting?.fileURL
        library.onChange = { [weak coordinator] _ in coordinator?.noteMeetingsChanged() }
        watching = coordinator.objectWillChange.sink { [weak self] _ in
            // willChange: the new values are there a turn later.
            Task { @MainActor [weak self] in self?.sync() }
        }
        sync()
    }

    var summaries: MeetingSummaries { coordinator.meetingSummaries }

    var isBusy: Bool { phase != .idle }

    /// reads the folder again, then makes sure the selection is something
    /// that exists.
    func reload() async {
        // the folder is settings', and may have been changed since.
        let folder = coordinator.settings.meetingsFolder
        library.load = { MeetingTranscriptFile.listAll(in: folder) }
        await library.reload()
        settleSelection()
    }

    func select(_ url: URL) {
        library.selection = .meeting(url)
    }

    // MARK: - mirroring the coordinator

    private func sync() {
        let now = coordinator.meetings.phase
        if now != phase {
            let was = phase
            phase = now
            if now == .idle, was != .idle { recordingEnded() }
        }
        if coordinator.meetingsNeedAttention != cannotHearTheMac {
            cannotHearTheMac = coordinator.meetingsNeedAttention
        }
        if coordinator.isLiveTranscriptShown != isLiveTranscriptShown {
            isLiveTranscriptShown = coordinator.isLiveTranscriptShown
        }
        if coordinator.lastMeetingSavedAt != seenSavedAt {
            seenSavedAt = coordinator.lastMeetingSavedAt
            if let saved = coordinator.lastMeeting?.fileURL { meetingSaved(saved) }
        }
        if coordinator.meetingsRevision != seenRevision {
            seenRevision = coordinator.meetingsRevision
            Task { await reload() }
        }
    }

    /// the file is on disk: select it if it is the meeting that was on
    /// screen while it was recorded, and flash its row.
    private func meetingSaved(_ url: URL) {
        lastSaved = url
        let watched = library.selection == .recording
            || (recordingInto.map { library.selection == .meeting($0) } ?? false)
        if watched { library.selection = .meeting(url) }
        flash = url
        Task { await reload() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if flash == url { flash = nil }
        }
    }

    private func recordingEnded() {
        recordingInto = nil
        recordingTitle = nil
        // the row for the recording is gone. the saved file takes its
        // place if one is coming; if nothing was kept, back to what was
        // open before, or the newest.
        guard library.selection == .recording else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if library.selection == .recording, phase == .idle { revertRecordingSelection() }
        }
    }

    private func revertRecordingSelection() {
        if let before = selectionBeforeRecording, before != .recording {
            library.selection = before
        } else {
            library.selection = library.entries.first.map { .meeting($0.id) }
        }
    }

    private func settleSelection() {
        switch library.selection {
        case nil:
            library.selection = library.entries.first.map { .meeting($0.id) }
        case let .meeting(url)?:
            // gone from disk (deleted in finder), and not the one that is
            // just about to appear.
            if library.hasLoaded, library.entry(for: url) == nil, url != lastSaved {
                library.selection = library.entries.first.map { .meeting($0.id) }
            }
        case .recording?:
            break
        }
        if case let .meeting(url) = target, library.hasLoaded, library.entry(for: url) == nil {
            target = .new
        }
    }

    // MARK: - actions

    func record() {
        switch target {
        case .new: recordNew()
        case let .meeting(url): record(into: url)
        }
    }

    func recordNew() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        recordingInto = nil
        recordingTitle = title.isEmpty ? nil : title
        beginSelectingRecording()
        coordinator.startMeeting(title: title.isEmpty ? nil : title)
        newTitle = ""
    }

    func record(into url: URL) {
        guard !isBusy else { return }
        recordingTitle = nil
        recordingInto = url
        selectionBeforeRecording = library.selection
        library.selection = .meeting(url)
        coordinator.startMeeting(title: nil, appendingTo: url)
    }

    private func beginSelectingRecording() {
        selectionBeforeRecording = library.selection
        library.selection = .recording
        // a start that did not take (no model yet, dictating) leaves the
        // phase idle: put the selection back rather than leave it on a
        // recording that is not there.
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if phase == .idle, library.selection == .recording { revertRecordingSelection() }
        }
    }

    func stop() {
        coordinator.stopMeeting()
    }

    func toggleLiveTranscript() {
        coordinator.toggleLiveTranscript()
    }

    func summarize(_ url: URL, templateID: String) {
        summaries.summarize(url, templateID: templateID)
    }

    func confirmDelete() {
        guard let url = pendingDelete else { return }
        pendingDelete = nil
        if case .meeting(url) = target { target = .new }
        library.remove(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
