import AppKit
import SwiftUI

/// settings › rewrite: fn+⌃. whether it is on, who rewrites, with what
/// model, and the styles on the picker. the one tab whose words can leave
/// the mac, so it says so where the switch is.
struct RewriteSettingsView: View {
    @ObservedObject var settings: RewriteSettings
    @ObservedObject var accounts: RewriteAccounts
    let dictationKey: HotkeyBinding

    @State private var pastedKey = ""
    @State private var models: [String] = []
    @State private var modelDraft = ""
    @State private var editing: RewriteStyle?
    @State private var pendingRemoval: RewriteStyle?

    private var gesture: String {
        "\(dictationKey.displayName)+\(dictationKey.rewriteModifier.symbol)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                SettingsToggleRow(
                    "rewrite with \(gesture)",
                    explanation: "hold \(gesture), talk, let go. pick a style on the pill and an ai rewrites it before it lands. plain \(dictationKey.displayName) never leaves this mac.",
                    isOn: $settings.isEnabled
                )
                divider
                providerRow
                if settings.provider.needsModelChoice {
                    divider
                    modelRow
                }
                divider
                stylesSection
                divider
                Text(privacyLine)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var privacyLine: String {
        switch settings.provider {
        case .apple:
            "apple's model runs on this mac: a rewrite never leaves it."
        default:
            "a rewrite sends what you said, and nothing else, to \(settings.provider.displayName). keys and sign-ins are kept in your keychain."
        }
    }

    // MARK: - who rewrites

    private var providerRow: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(
                "who rewrites it",
                explanation: settings.provider.setupExplanation
            )
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Picker("", selection: $settings.provider) {
                    ForEach(RewriteProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .brandMenuStyle()
                .frame(width: 220)
                .accessibilityLabel("who rewrites it")

                accountControls
            }
        }
    }

    @ViewBuilder
    private var accountControls: some View {
        let provider = settings.provider
        switch accounts.status(of: provider) {
        case let .ready(detail):
            HStack(spacing: 10) {
                Text(detail ?? "ready")
                    .font(BrandUI.valueFont)
                    .foregroundStyle(BrandUI.goldPale)
                if provider.authentication != .none {
                    Button(provider.authentication == .apiKey ? "remove key" : "sign out") {
                        accounts.signOut(provider)
                        models = []
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.gold)
                }
            }
        case let .working(message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.mini)
                Text(message)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                Button("cancel") { accounts.cancelSignIn() }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.gold)
            }
        case let .unavailable(reason):
            Text(reason)
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.attention)
        case let .needsSetup(problem):
            VStack(alignment: .trailing, spacing: 6) {
                if let problem {
                    Text(problem)
                        .font(BrandUI.bodyFont)
                        .foregroundStyle(BrandUI.attention)
                }
                if provider.canSignIn {
                    Button("sign in with \(provider.signInName)…") {
                        Task {
                            await accounts.signIn(provider)
                            loadModels()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.gold)
                }
                if provider.acceptsKey {
                    HStack(spacing: 8) {
                        SecureField(provider.canSignIn ? "or paste a key" : "paste a key", text: $pastedKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(saveKey)
                        Button("save", action: saveKey)
                            .buttonStyle(.plain)
                            .foregroundStyle(BrandUI.gold)
                            .disabled(pastedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let keyPage = provider.keyPage {
                        Button("get a key ↗") {
                            NSWorkspace.shared.open(keyPage)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(BrandUI.textSecondary)
                    }
                }
            }
        }
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
                explanation: "a small, fast model is plenty: a rewrite is a sentence or two. \(settings.provider.defaultModel) unless you pick another."
            )
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                TextField(settings.provider.defaultModel, text: $modelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(BrandUI.valueFont)
                    .frame(width: 220)
                    .onSubmit {
                        settings.setModel(modelDraft, for: settings.provider)
                    }
                    .onChange(of: modelDraft) {
                        settings.setModel(modelDraft, for: settings.provider)
                    }
                if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model) { modelDraft = model }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                SettingsRowLabel(
                    "styles",
                    explanation: "the buttons on the pill, in order, each on its digit key. 0 pastes it as said. nothing picked in five seconds takes the one you used last."
                )
                Spacer(minLength: 8)
                Button("new style…") {
                    editing = .custom(name: "")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrandUI.gold)
                .disabled(!settings.canAddStyle)
            }

            VStack(spacing: 0) {
                ForEach(Array(settings.pickerStyles.enumerated()), id: \.element.id) { index, style in
                    styleRow(style, key: index + 1)
                    if index < settings.pickerStyles.count - 1 {
                        divider.opacity(0.6)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandUI.black.opacity(0.22))
            )
        }
    }

    private func styleRow(_ style: RewriteStyle, key: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(key)")
                .font(BrandUI.valueFont)
                .foregroundStyle(BrandUI.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(style.name)
                        .font(BrandUI.bodyFont.weight(.medium))
                    if style.id == settings.lastStyleID {
                        Text("default")
                            .font(BrandUI.valueFont)
                            .foregroundStyle(BrandUI.gold)
                    }
                }
                Text(summary(of: style))
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if !style.isBuiltIn {
                Button("edit") { editing = style }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.gold)
                Button("remove") { pendingRemoval = style }
                    .buttonStyle(.plain)
                    .foregroundStyle(BrandUI.textSecondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func summary(of style: RewriteStyle) -> String {
        let tone = style.tone.map(\.summary)
            ?? "fits it to what you said"
        let notes = style.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? tone : "\(tone) · \(notes)"
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
