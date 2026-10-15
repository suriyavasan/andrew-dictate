import Foundation

/// the meter's own object. the levels change fifteen times a second while a
/// meeting records, and `DictationCoordinator` is what the menu, the badge
/// and every settings pane observe: put on it, each change would redraw all
/// of them. here only the view that draws the bars watches.
@MainActor
final class MeetingLevelsFeed: ObservableObject {
    @Published var levels = MeetingLevels.zero
}
