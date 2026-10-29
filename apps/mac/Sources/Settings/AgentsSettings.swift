import AppKit
import SwiftUI

/// settings › meetings: the line that adds the meetings to an agent. plain
/// controls: this is a row, not a design.
struct AgentsSettings: View {
    /// the app this is, so the path is the one on this mac.
    var app: URL = Bundle.main.bundleURL

    @State private var copied = false

    private var command: String {
        AgentSetup.command(helper: AgentSetup.helperURL(in: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                SettingsRowLabel(
                    "use with AI agents",
                    explanation: "paste this in a terminal and Claude Code can read your meetings: who said what, saved and live. it reads on this mac only; nothing is sent anywhere.")
                Spacer(minLength: 8)
                Button(copied ? "copied" : "copy") { copy() }
                    .accessibilityLabel("copy the command that adds andrew dictate to Claude Code")
            }
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("command: \(command)")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
