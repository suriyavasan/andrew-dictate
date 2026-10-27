import AppKit
import SwiftUI

/// settings › ai: the one tab whose words can leave the mac, so it says so
/// at the foot. three sections: the provider (who answers, with what
/// model), which both of the others use; the rewrite (fn+⌃: whether it is
/// on, the key that asks for it, the styles); and the summaries of
/// meetings (whether they run on their own, and in what shape).
struct RewriteSettingsView: View {
    @ObservedObject var settings: RewriteSettings
    @ObservedObject var accounts: RewriteAccounts
    let dictationKey: HotkeyBinding

    @State private var pastedKey = ""
    @State private var models: [String] = []
    @State private var modelDraft = ""
    @State private var editing: RewriteStyle?
    @State private var pendingRemoval: RewriteStyle?
    @State private var hoveredStyleID: String?

    /// the right-hand column every row's control sits in, so the picker,
    /// the key field and the model line up down the tab.
    private static let controlWidth: CGFloat = 230

    private var modifier: RewriteModifier {
        dictationKey.rewriteModifier(preferring: settings.modifier)
    }

    private var gesture: String {
        "\(dictationKey.displayName)+\(modifier.symbol)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                BrandSectionHeader("provider")
                providerRow
                if settings.provider.needsModelChoice {
                    divider
                    modelRow
                }

                // the sections are told apart by space and a header; the
                // hairline is for rows inside one.
                BrandSectionHeader("rewrite")
                    .padding(.top, 8)
                SettingsToggleRow(
                    "rewrite with \(gesture)",
                    explanation: "hold \(gesture), talk, let go, and an ai rewrites it before it lands. plain \(dictationKey.displayName) never leaves this mac.",
                    isOn: $settings.isEnabled
                )
                divider
                keyRow
                divider
                stylesSection

                BrandSectionHeader("summaries")
                    .padding(.top, 8)
                SettingsToggleRow(
                    "summarize meetings when they end",
                    explanation: summariesExplanation,
                    isOn: $settings.summariesEnabled
                )
                divider
                templateRow

                divider
                    .padding(.top, 6)
                privacyFootnote
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .onAppear {
            accounts.refresh()
            modelDraft = settings.model(for: settings.provider)
            loadModels()
        }
        .onChange(of: settings.provider) {
            pastedKey = ""
            modelDraft = settings.model(for: settings.provider)
            loadModels()
        }
        .sheet(item: $editing) { style in
            RewriteStyleEditor(
                style: style,
                accounts: accounts,
                settings: settings,
                onSave: { saved in
                    settings.save(saved)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
        .alert(
            "remove \(pendingRemoval?.name ?? "this style")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("remove", role: .destructive) {
                if let pendingRemoval {
                    settings.remove(pendingRemoval)
                }
                pendingRemoval = nil
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(BrandUI.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func textButton(
        _ title: String,
        quiet: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(BrandUI.bodyFont)
            .foregroundStyle(quiet ? BrandUI.textSecondary : BrandUI.gold)
    }

    // MARK: - the key

    /// the dictation key is set on the dictation tab; this row only adds
    /// the second key to it, and says which one is in force when the one
    /// you chose is the dictation key's own kind.
    private var keyRow: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(
                "rewrite key",
                explanation: modifier == settings.modifier
                    ? "held with \(dictationKey.displayName), your dictation key. that one is set on the dictation tab."
                    : "\(settings.modifier.symbol) is your dictation key's own, so \(modifier.symbol) stands in. the dictation key is set on the dictation tab."
            )
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                KeyChip(dictationKey.displayName)
                Text("+")
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.textSecondary)
                Menu {
                    ForEach(RewriteModifier.allCases) { option in
                        Button {
                            settings.modifier = option
                        } label: {
                            if option == modifier {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                        .disabled(!option.isFree(alongside: dictationKey))
                    }
                } label: {
                    HStack(spacing: 5) {
                        KeyChip(modifier.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BrandUI.textSecondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("rewrite key, held with \(dictationKey.displayName)")
            }
        }
    }

    // MARK: - who answers

    private var providerRow: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                SettingsRowLabel(
                    "who answers",
                    explanation: "\(settings.provider.setupExplanation) rewrites and meeting summaries both ask it."
                )
                Spacer(minLength: 8)
                Picker("", selection: $settings.provider) {
                    ForEach(RewriteProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
                .frame(width: Self.controlWidth)
                .accessibilityLabel("who answers")
            }
            accountControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var accountControls: some View {
        let provider = settings.provider
        switch accounts.status(of: provider) {
        case let .ready(detail):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(BrandUI.gold)
                    .accessibilityHidden(true)
                Text(readyLine(provider, detail: detail))
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if provider.authentication != .none {
                    Text("·")
                        .foregroundStyle(BrandUI.textSecondary)
                        .accessibilityHidden(true)
                    textButton(provider.authentication == .apiKey ? "remove key" : "sign out") {
                        accounts.signOut(provider)
                        models = []
                    }
                }
            }
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(message)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                Text("·")
                    .foregroundStyle(BrandUI.textSecondary)
                    .accessibilityHidden(true)
                textButton("cancel") { accounts.cancelSignIn() }
            }
        case let .unavailable(reason):
            Text(reason)
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.attention)
        case let .needsSetup(problem):
            VStack(alignment: .trailing, spacing: 8) {
                if let problem {
                    Text(problem)
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.attention)
                        .multilineTextAlignment(.trailing)
                }
                if provider.canSignIn {
                    Button("sign in with \(provider.signInName)…") {
                        Task {
                            await accounts.signIn(provider)
                            loadModels()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandUI.goldDeep)
                    .frame(width: Self.controlWidth, alignment: .trailing)
                }
                if provider.acceptsKey {
                    HStack(spacing: 8) {
                        SecureField(
                            provider.canSignIn ? "or paste a key" : "paste a key",
                            text: $pastedKey
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                        textButton("save", action: saveKey)
                            .disabled(pastedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(width: Self.controlWidth)
                }
                if let keyPage = provider.keyPage {
                    textButton("get a key ↗", quiet: true) {
                        NSWorkspace.shared.open(keyPage)
                    }
                }
            }
        }
    }

    /// "signed in as you@example.com", "key ending 3f9a", "ready".
    private func readyLine(_ provider: RewriteProvider, detail: String?) -> String {
        guard let detail else {
            return "ready"
        }
        return provider.authentication == .signIn ? "signed in as \(detail)" : detail
    }

    private func saveKey() {
        let key = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        accounts.saveKey(key, for: settings.provider)
        pastedKey = ""
        loadModels()
    }

    // MARK: - the model

    private var modelRow: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(
                "model",
                explanation: "a small, fast model is plenty: a rewrite is a sentence or two, and notes are no harder. \(settings.provider.defaultModel) unless you pick another."
            )
            Spacer(minLength: 8)
            TextField(settings.provider.defaultModel, text: $modelDraft)
                .textFieldStyle(.roundedBorder)
                .font(BrandUI.valueFont)
                .frame(width: Self.controlWidth)
                .onSubmit {
                    settings.setModel(modelDraft, for: settings.provider)
                }
                .onChange(of: modelDraft) {
                    settings.setModel(modelDraft, for: settings.provider)
                }
                .overlay(alignment: .trailing) {
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { model in
                                Button(model) { modelDraft = model }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(BrandUI.textSecondary)
                                .frame(width: 22, height: 18)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .padding(.trailing, 4)
                        .accessibilityLabel("models \(settings.provider.displayName) offers")
                    }
                }
        }
    }

    private func loadModels() {
        let provider = settings.provider
        Task {
            let listed = await accounts.models(for: provider)
            if settings.provider == provider {
                models = listed
            }
        }
    }

    // MARK: - styles

    private var stylesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                SettingsRowLabel(
                    "styles",
                    explanation: "every take gets the default. move the pointer while you talk and the pill offers them all, each on its number key."
                )
                Spacer(minLength: 8)
                textButton("new style…") {
                    editing = .custom(name: "")
                }
                .disabled(!settings.canAddStyle)
            }

            VStack(spacing: 0) {
                ForEach(Array(settings.pickerStyles.enumerated()), id: \.element.id) { index, style in
                    styleRow(style, key: index + 1)
                    divider.padding(.leading, 52)
                }
                asSaidRow
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandUI.cardBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandUI.hairline, lineWidth: 1)
            }
        }
    }

    private func styleRow(_ style: RewriteStyle, key: Int) -> some View {
        let isDefault = style.id == settings.defaultStyleID
        let isHovered = hoveredStyleID == style.id
        return HStack(spacing: 12) {
            KeyChip("\(key)")
                .frame(width: 26)
                .accessibilityLabel("key \(key)")
            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .font(BrandUI.bodyFont.weight(.medium))
                    .foregroundStyle(BrandUI.textPrimary)
                Text(summary(of: style))
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                if !style.isBuiltIn {
                    textButton("edit", quiet: true) { editing = style }
                    textButton("remove", quiet: true) { pendingRemoval = style }
                }
                if isDefault {
                    defaultBadge
                } else {
                    // on the row under the pointer only: a column of
                    // "make default" would shout over the names.
                    textButton("make default") {
                        settings.defaultStyleID = style.id
                    }
                    .opacity(isHovered ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { over in
            if over {
                hoveredStyleID = style.id
            } else if hoveredStyleID == style.id {
                hoveredStyleID = nil
            }
        }
    }

    /// the last button on the pill: no model at all.
    private var asSaidRow: some View {
        HStack(spacing: 12) {
            KeyChip("\(RewritePick.asSaidKey)")
                .frame(width: 26)
                .accessibilityLabel("key \(RewritePick.asSaidKey)")
            VStack(alignment: .leading, spacing: 2) {
                Text("as said")
                    .font(BrandUI.bodyFont.weight(.medium))
                    .foregroundStyle(BrandUI.textPrimary)
                Text("on the picker only: pastes it the way you said it")
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var defaultBadge: some View {
        Text("default")
            .font(BrandUI.sectionLabelFont)
            .foregroundStyle(BrandUI.windowBg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(BrandUI.gold))
    }

    private func summary(of style: RewriteStyle) -> String {
        let tone = style.tone.map(\.summary)
            ?? "fits it to what you said"
        let notes = style.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? tone : "\(tone) · \(notes)"
    }

    // MARK: - summaries

    /// says where the transcript goes, because this is the switch that
    /// sends other people's words somewhere.
    private var summariesExplanation: String {
        switch settings.provider {
        case .apple:
            "when a meeting is saved its transcript is read by apple's model and the notes land at the top of the file. it stays on this mac. regenerate any time from the meetings window."
        default:
            "when a meeting is saved its transcript goes to \(settings.provider.shortName) and the notes land at the top of the file. regenerate any time from the meetings window."
        }
    }

    /// an id this build doesn't know shows as auto, which is also what
    /// the summary will use for it.
    private var templateBinding: Binding<String> {
        Binding(
            get: { MeetingTemplate.resolving(settings.defaultTemplateID).id },
            set: { settings.defaultTemplateID = $0 }
        )
    }

    private var templateRow: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(
                "template",
                explanation: "how notes are laid out unless a meeting has its own."
            )
            Spacer(minLength: 8)
            Picker("", selection: templateBinding) {
                ForEach(MeetingTemplate.builtIn) { template in
                    Label(template.name, systemImage: template.symbol)
                        .tag(template.id)
                }
            }
            .labelsHidden()
            .brandMenuStyle()
            .frame(width: Self.controlWidth)
            .accessibilityLabel("template")
        }
    }

    // MARK: - privacy

    private var privacyFootnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock")
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
                .accessibilityHidden(true)
            Text(privacyLine)
                .font(.caption)
                .foregroundStyle(BrandUI.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyLine: String {
        switch settings.provider {
        case .apple:
            "apple's model runs on this mac: neither a rewrite nor a summary leaves it."
        default:
            "a rewrite sends what you said, a summary sends what a meeting heard, and nothing else, to \(settings.provider.shortName). keys and sign-ins stay in your keychain."
        }
    }
}

/// a style of your own: a name, a place on the tone pad, figma's presets
/// to start from, a line of your own, and a try on a sentence before you
/// keep it.
struct RewriteStyleEditor: View {
    @State var style: RewriteStyle
    @ObservedObject var accounts: RewriteAccounts
    @ObservedObject var settings: RewriteSettings
    var onSave: (RewriteStyle) -> Void
    var onCancel: () -> Void

    @State private var sample = "um so i think we should probably move the sync to thursday because like half the team is out on wednesday and honestly it's not urgent"
    @State private var tried: String?
    @State private var tryFailure: String?
    @State private var isTrying = false
    @State private var tryTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(style.name.isEmpty ? "new style" : style.name)
                .font(BrandUI.titleFont)

            TextField("name, as the pill shows it", text: $style.name)
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .top, spacing: 18) {
                TonePadView(tone: toneBinding)
                VStack(alignment: .leading, spacing: 8) {
                    Text("presets")
                        .font(BrandUI.bodyFont.weight(.medium))
                    ForEach(TonePreset.all) { preset in
                        Button(preset.name) {
                            style.tone = preset.tone
                            style.notes = preset.notes
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            style.tone == preset.tone && style.notes == preset.notes
                                ? BrandUI.goldPale
                                : BrandUI.gold
                        )
                    }
                    Button("reset") {
                        style.tone = .center
                        style.notes = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
                    .padding(.top, 4)
                    Text((style.tone ?? .center).summary)
                        .font(BrandUI.valueFont)
                        .foregroundStyle(BrandUI.goldPale)
                        .padding(.top, 6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("anything else")
                    .font(BrandUI.bodyFont.weight(.medium))
                TextField("e.g. no emoji · end with a question · write it as a commit message", text: $style.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("try it")
                        .font(BrandUI.bodyFont.weight(.medium))
                    Spacer()
                    if isTrying {
                        ProgressView().controlSize(.mini)
                    }
                    Button(tried == nil ? "try" : "try again", action: tryIt)
                        .buttonStyle(.plain)
                        .foregroundStyle(BrandUI.gold)
                        .disabled(isTrying)
                }
                TextField("something you might say", text: $sample, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                if let tried {
                    Text(tried)
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.goldPale)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tryFailure {
                    Text(tryFailure)
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.attention)
                }
            }

            HStack {
                Spacer()
                Button("cancel") {
                    tryTask?.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("save") {
                    tryTask?.cancel()
                    var saved = style
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .brandTinted()
        .preferredColorScheme(.dark)
        .onDisappear { tryTask?.cancel() }
    }

    private var toneBinding: Binding<TonePosition> {
        Binding(
            get: { style.tone ?? .center },
            set: { style.tone = $0 }
        )
    }

    private func tryIt() {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isTrying = true
        tryFailure = nil
        let style = style
        let provider = settings.provider
        let model = settings.model(for: provider)
        tryTask = Task {
            defer { isTrying = false }
            switch await accounts.connect(provider, model: model) {
            case let .failure(failure):
                tryFailure = failure.pillReason
            case let .success(connection):
                do {
                    let answer = try await connection.client.rewrite(
                        RewriteInstructions.prompt(for: text, style: style),
                        model: connection.model
                    )
                    guard !Task.isCancelled else { return }
                    tried = RewriteInstructions.cleanAnswer(answer)
                } catch let failure as RewriteFailure {
                    tryFailure = failure.pillReason
                } catch {
                    tryFailure = RewriteFailure.network.pillReason
                }
            }
        }
    }
}
