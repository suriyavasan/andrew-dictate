import SwiftUI

/// the meetings window: the list on the left, one meeting on the right, and
/// the recording bar along the bottom of that, over whatever is open.
struct MeetingsWindowView: View {
    @ObservedObject var state: MeetingsWindowState
    @ObservedObject var library: MeetingsLibraryModel
    @ObservedObject var summaries: MeetingSummaries

    @State private var columns = NavigationSplitViewVisibility.all

    init(state: MeetingsWindowState) {
        self.state = state
        library = state.library
        summaries = state.summaries
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MeetingsSidebar(state: state, library: library, summaries: summaries)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MeetingRecordBar(state: state, library: library, summaries: summaries)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .tint(BrandUI.gold)
        .brandGlassWindow()
        .frame(minWidth: 920, minHeight: 560)
        .alert(deleteTitle, isPresented: isDeleting) {
            Button("delete", role: .destructive) { state.confirmDelete() }
            Button("cancel", role: .cancel) { state.pendingDelete = nil }
        } message: {
            Text("the transcript goes to the trash, with its audio.")
        }
        .alert(
            library.failure ?? "",
            isPresented: Binding(
                get: { library.failure != nil },
                set: { if !$0 { library.dismissFailure() } })
        ) {
            Button("ok", role: .cancel) {}
        }
        .background {
            // ⌘W closes it, as any window.
            Button("") { (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: the detail column

    @ViewBuilder
    private var detail: some View {
        switch library.selection {
        case .recording?:
            RecordingDetailView(state: state)
        case let .meeting(url)?:
            if let entry = library.entry(for: url), let document = library.document(for: url) {
                MeetingDetailView(
                    state: state, library: library, summaries: summaries,
                    entry: entry, document: document)
                    .id(url)
            } else {
                // just saved, and the list has not read it yet; or gone.
                Color.clear
            }
        case nil:
            if library.hasLoaded, library.entries.isEmpty {
                emptyState
            } else {
                Color.clear
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MW.s12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(BrandUI.gold.opacity(0.8))
                .padding(.bottom, MW.s8)
            Text("your meetings go here")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BrandUI.textPrimary)
            Text("record a call and andrew writes it up with a summary and a transcript.")
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            MWGoldButton(title: "record your first meeting", symbol: "record.circle") {
                state.recordNew()
            }
            .padding(.top, MW.s8)
            .disabled(state.isBusy)
        }
        .padding(MW.s24)
    }

    // MARK: deleting

    private var isDeleting: Binding<Bool> {
        Binding(
            get: { state.pendingDelete != nil },
            set: { if !$0 { state.pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let url = state.pendingDelete, let entry = library.entry(for: url) else {
            return "delete this meeting?"
        }
        return "delete “\(entry.title)”?"
    }
}
