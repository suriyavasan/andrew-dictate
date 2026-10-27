import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by a second copy on its way out, so the copy already living in
    /// the menu bar can say where it is. The bundle id is interpolated
    /// because this is a machine-wide bus: the development build and the
    /// release build must not answer each other.
    static let andrewDictateAlreadyRunning = Notification.Name(
        "\(AppIdentity.bundleID).alreadyRunning"
    )
}

/// a menu-bar app is never "opened" twice — double-clicking it in
/// /Applications sends a reopen to the instance already running. that is the
/// user coming back to us, and the moment to re-verify what we're allowed to do.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    var onTerminate: (() -> NSApplication.TerminateReply)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        onReopen?()
        return true
    }

    /// One archive, one spool, one pasteboard. A second copy — the dmg you
    /// opened to see what changed, still running from /Volumes — sweeps the
    /// live meeting spool as an orphan and deletes it out from under the copy
    /// recording into it. `willFinish`, not `didFinish`: the coordinator that
    /// opens the archive, installs the monitors and sweeps the spool is built
    /// when the scene body first runs, so there is nothing here to unwind.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Capabilities.current.refusesASecondInstance,
              let other = Self.otherRunningCopy()
        else {
            // before the coordinator reads the permissions: a row left by a
            // differently signed copy reads as "granted" in system settings
            // and as nothing to us (StaleGrantRepair).
            StaleGrantRepair.runAtLaunch()
            return
        }
        // it cannot say anything itself — it is about to be gone — so the
        // copy that is running draws the pill.
        DistributedNotificationCenter.default().postNotificationName(
            .andrewDictateAlreadyRunning,
            object: nil,
            deliverImmediately: true
        )
        _ = other.activate()
        exit(0)
    }

    /// A copy of this app that is neither this process nor already gone.
    private static func otherRunningCopy() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// on upgrade day the quit does not come from the menu: brew asks the app
    /// to go so it can replace the bundle under it. that request can land in
    /// the middle of a meeting, so it goes through the coordinator, which
    /// stops the recording and waits for the markdown before answering.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        onTerminate?() ?? .terminateNow
    }
}

@main
@MainActor
struct AndrewDictateApp: App {
    @StateObject private var coordinator = DictationCoordinator()
    @StateObject private var updates = DailyUpdateCheck.live()
    /// what clicking the update line does: a brew install runs the upgrade
    /// and the line follows it; a dmg install opens the releases page.
    @StateObject private var updateHandOff = UpdateHandOff.live()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate

    /// the badge carries hue and corner and nothing else. voiceover gets the
    /// sentence: what the meeting is doing, or the call nobody records.
    private var menuBarLabel: String {
        if coordinator.needsAttention {
            return "Andrew Dictate — setup needed"
        }
        if let meeting = coordinator.meetings.phase.spoken {
            return "Andrew Dictate — \(meeting)"
        }
        if let call = coordinator.unrecordedCall {
            return "Andrew Dictate — call in \(call), not recording"
        }
        return "Andrew Dictate"
    }

    var body: some Scene {
        MenuBarExtra {
            // a panel, not a menu: control center's tiles, so the switch
            // and the meeting are a glance and a click (MenuBarPanel).
            MenuBarPanel(
                coordinator: coordinator,
                settings: coordinator.settings,
                rewrite: coordinator.rewriteSettings,
                updates: updates,
                updateHandOff: updateHandOff
            )
        } label: {
            // the badge wears what the coordinator says it is: a take, a
            // meeting's rim, a call nobody records, or a setup gap.
            Image(
                nsImage: MenuBarBrandIcon.image(for: coordinator.badgeLook)
            )
            .accessibilityLabel(menuBarLabel)
            .task {
                lifecycleDelegate.onReopen = { [weak coordinator] in
                    coordinator?.handleReopen()
                }
                lifecycleDelegate.onTerminate = { [weak coordinator] in
                    coordinator?.prepareToQuit() ?? .terminateNow
                }
                // busy is anything but idle: loading the model, a take, a
                // meeting. the check waits for the next tick; a click on
                // the line is refused.
                let isBusy = { [weak coordinator] in
                    guard let coordinator else {
                        return true
                    }
                    return coordinator.state != .idle
                        || coordinator.meetings.isRecording
                }
                updates.start(isBusy: isBusy)
                updateHandOff.isBusy = isBusy
            }
        }
        .menuBarExtraStyle(.window)

        // the system settings scene, not a hand-rolled window: pane chrome,
        // per-pane window title, and dimmed traffic lights come free, and
        // they're what the HIG asks of a settings window (ADR 0036).
        Settings {
            SettingsView(
                coordinator: coordinator,
                meetingsLoader: {
                    MeetingTranscriptFile.listAll(
                        in: coordinator.settings.meetingsFolder)
                }
            )
        }
        .windowResizability(.contentSize)
    }
}
