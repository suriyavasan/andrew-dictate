import AppKit
import SwiftUI

/// the notes, on the left: what the model wrote, drawn in the brand's
/// type; or the shimmering bars while it is writing; or why it could not;
/// or the one button that gets it going. it follows `MeetingSummaries` for
/// this file and nothing else — the file is the truth about what exists.
struct MeetingSummaryPane: View {
    let url: URL
    let document: MeetingDocument
    @ObservedObject var summaries: MeetingSummaries
    @ObservedObject var settings: RewriteSettings
    @ObservedObject var accounts: RewriteAccounts
    let summarize: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var work: MeetingSummaries.State { summaries.state(for: url) }

    /// the pane's face, so a change of it animates and nothing else does.
    private enum Face: Equatable {
        case writing, notes, failed(String), nothingSaid, empty
    }

    private var face: Face {
        if work == .summarizing { return .writing }
        if document.summary != nil {
            return .notes
        }
        if case let .failed(reason) = work { return .failed(reason) }
        return document.hasWords ? .empty : .nothingSaid
    }

    var body: some View {
        VStack(spacing: 0) {
            MWPaneHeader(title: "summary") {
                MWCopyButton(help: "copy the summary", isDisabled: document.summary == nil) {
                    document.summary ?? ""
                }
            }
            ScrollView {
                content
                    .padding(.horizontal, MW.s16)
                    .padding(.top, MW.s8)
                    .padding(.bottom, MW.s24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .animation(MW.animation(.easeInOut(duration: 0.28), reduceMotion: reduceMotion), value: face)
    }

    @ViewBuilder
    private var content: some View {
        switch face {
        case .writing:
            MWSkeleton().mwBlurFade()
        case .notes:
            VStack(alignment: .leading, spacing: MW.s12) {
                if case let .failed(reason) = work {
                    failedBanner(reason)
                }
                MeetingNotesView(markdown: document.summary ?? "")
            }
            .mwBlurFade()
        case let .failed(reason):
            failedCard(reason).mwBlurFade()
        case .nothingSaid:
            MWCard {
                Text("nobody said anything in this one, so there is nothing to write up.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
            }
            .mwBlurFade()
        case .empty:
            emptyCard.mwBlurFade()
        }
    }

    // MARK: states

    private var emptyCard: some View {
        MWCard {
            VStack(alignment: .leading, spacing: MW.s12) {
                Text("no notes yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BrandUI.textPrimary)
                Text("andrew can write up what was decided and who owes what.")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                MWGoldButton(title: "summarize", symbol: "sparkles", action: summarize)
                if let hint {
                    SettingsHint(text: hint.text, link: hint.link)
                }
            }
        }
    }

    /// why the notes did not come by themselves, if the settings are the
    /// reason: told once, under the button that works anyway.
    private var hint: (text: String, link: String)? {
        if case .ready = accounts.status(of: settings.provider) {
            return settings.summariesEnabled
                ? nil : ("notes are not written when a meeting ends. turn that on in ", "settings › ai")
        }
        return ("the ai is not set up yet. set a provider in ", "settings › ai")
    }

    private func failedCard(_ reason: String) -> some View {
        MWCard(tint: BrandUI.attention) {
            VStack(alignment: .leading, spacing: MW.s12) {
                HStack(alignment: .firstTextBaseline, spacing: MW.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(BrandUI.attention)
                    Text("couldn’t write the notes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BrandUI.textPrimary)
                }
                Text(reason)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                MWGoldButton(title: "try again", symbol: "arrow.clockwise", action: summarize)
            }
        }
    }

    /// notes that are there, and a try that did not work: the notes stay.
    private func failedBanner(_ reason: String) -> some View {
        MWCard(tint: BrandUI.attention) {
            HStack(spacing: MW.s12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandUI.attention)
                Text("couldn’t write them again: \(reason)")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("try again", action: summarize)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrandUI.gold)
            }
        }
    }
}

/// "turn it on in settings › ai", with the last words a link to settings.
private struct SettingsHint: View {
    let text: String
    let link: String

    @Environment(\.openSettings) private var openSettings

    private var attributed: AttributedString {
        var words = AttributedString(text)
        words.paint(words.startIndex..<words.endIndex, foreground: BrandUI.textSecondary)
        var settings = AttributedString(link)
        settings.paint(settings.startIndex..<settings.endIndex, foreground: BrandUI.gold)
        settings.underline(settings.startIndex..<settings.endIndex)
        return words + settings
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture {
                NSApp.activate()
                openSettings()
            }
            .help("open settings")
            .accessibilityAddTraits(.isLink)
    }
}

// MARK: - the notes

/// the model's markdown, in the window's own type: `##` as small gold
/// labels, points with a bullet or a box, the rest as prose. bold, italic
/// and code inside a line are the line's own markdown, read per line.
struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = MeetingNotesBlocks.blocks(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                row(block)
                    .padding(.top, top(of: block, after: index > 0 ? blocks[index - 1] : nil))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 8 between lines of a kind, 24 above a heading, so the sections read
    /// as sections.
    private func top(of block: MeetingNotesBlocks.Block, after previous: MeetingNotesBlocks.Block?) -> CGFloat {
        guard let previous else { return 0 }
        if case .heading = block { return MW.s24 }
        if case .heading = previous { return MW.s8 }
        return MW.s8
    }

    @ViewBuilder
    private func row(_ block: MeetingNotesBlocks.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text.lowercased())
                .font(.system(size: level == 1 ? 14 : 12, weight: .semibold))
                .tracking(level == 1 ? 0.2 : 0.6)
                .foregroundStyle(level == 1 ? BrandUI.goldPale : BrandUI.gold)
                .accessibilityAddTraits(.isHeader)
        case let .bullet(text, depth, checked):
            HStack(alignment: .firstTextBaseline, spacing: MW.s8) {
                marker(checked)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * MW.s16)
        case let .numbered(number, text, depth):
            HStack(alignment: .firstTextBaseline, spacing: MW.s8) {
                Text("\(number).")
                    .font(BrandUI.machineFont(size: 12))
                    .foregroundStyle(BrandUI.gold.opacity(0.75))
                    .frame(minWidth: 16, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * MW.s16)
        case let .quote(text):
            inline(text)
                .foregroundStyle(BrandUI.textSecondary)
                .padding(.leading, MW.s12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(BrandUI.gold.opacity(0.4)).frame(width: 2)
                }
        case let .paragraph(text):
            inline(text)
        case .noneNoted:
            Text("none noted.")
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textPrimary.opacity(0.4))
        }
    }

    @ViewBuilder
    private func marker(_ checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(checked ? BrandUI.gold : BrandUI.textSecondary)
                .frame(width: 16)
        } else {
            Text("•")
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.gold.opacity(0.75))
                .frame(width: 16)
        }
    }

    private func inline(_ text: String) -> some View {
        Text(Self.styled(text))
            .font(BrandUI.bodyFont)
            .foregroundStyle(BrandUI.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// bold, italic and `code` from the line's markdown; a line that is not
    /// valid markdown is shown as written.
    private static func styled(_ text: String) -> AttributedString {
        var parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let intents = AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
        for run in parsed.runs {
            if let intent = run[intents], intent.contains(.code) {
                parsed.setFont(run.range, BrandUI.machineFont(size: 12))
                parsed.paint(run.range, background: Color.white.opacity(0.08))
            }
        }
        return parsed
    }
}
