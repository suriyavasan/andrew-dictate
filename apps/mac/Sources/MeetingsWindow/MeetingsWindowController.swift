import AppKit
import SwiftUI

/// the meetings window, made the first time it is asked for and kept: closing
/// it only hides it, so reopening is instant and the list is where it was.
/// the house pattern (`AboutWindowController`), at a window's size.
@MainActor
final class MeetingsWindowController: NSWindowController, NSWindowDelegate {
    private static let autosaveName = "meetings"
    private static let firstSize = NSSize(width: 1180, height: 760)
    private static let minimumSize = NSSize(width: 920, height: 560)

    private let state: MeetingsWindowState

    init(coordinator: DictationCoordinator) {
        let state = MeetingsWindowState(coordinator: coordinator)
        self.state = state

        let hosting = NSHostingController(rootView: MeetingsWindowView(state: state))
        // the window's size is the window's: the content does not get to
        // resize it.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "meetings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // a window like any other: the red button and ⌘W close it, and it
        // is neither floating nor hidden when the app is not active.
        window.level = .normal
        window.hidesOnDeactivate = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
            window.standardWindowButton(button)?.isEnabled = true
        }
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.firstSize)
        // other people's words: out of every capture, always. you see it;
        // they do not.
        window.sharingType = CaptureExclusion.sharingType(hidden: true)
        window.backgroundColor = BrandUI.nsColor(BrandUI.windowBgRGB)
        // the saved frame wins; the middle of the screen is only where it
        // starts life.
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)

        super.init(window: window)
        window.delegate = self
        Task { await state.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// in front, on `select` if given. the app has no dock icon and is
    /// usually inactive, so it is brought forward first.
    func present(select url: URL? = nil) {
        if let url { state.select(url) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await state.reload() }
    }

    // MARK: - NSWindowDelegate

    /// closing only hides it (`isReleasedWhenClosed` is off, and the
    /// coordinator keeps this controller): nothing here holds it open.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }

    /// what happened while it was behind is read the moment you are back.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { await state.reload() }
    }
}
