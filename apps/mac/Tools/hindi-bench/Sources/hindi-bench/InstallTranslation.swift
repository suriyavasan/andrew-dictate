import AppKit
import SwiftUI
@preconcurrency import Translation

/// a CLI cannot download a Translation language pack: macOS asks for it through a
/// view's `.translationTask`, with a consent sheet the user clicks. this opens
/// one small window that asks for hi -> en and quits when it is installed.
/// (the same pack can be added in System Settings > General > Language & Region > Translation Languages.)
struct InstallTranslationView: View {
    @State private var configuration: TranslationSession.Configuration? =
        .init(source: Translator.hi, target: Translator.en)
    @State private var message = "asking macOS for the Hindi to English pack. click Download if a sheet appears."

    var body: some View {
        Text(message)
            .padding(24)
            .frame(width: 460, height: 120)
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    message = "installed: \(await Translator.status())"
                } catch {
                    message = "failed: \(error.localizedDescription)"
                }
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
    }
}

@MainActor func installTranslation() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 120), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
    window.title = "hindi-bench: install Hindi translation"
    window.contentView = NSHostingView(rootView: InstallTranslationView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
}
