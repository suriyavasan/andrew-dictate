import SwiftUI

/// what the transcript needs to let a speaker be named: which speakers can
/// be, what to suggest, and what to do with the answer. closures, so the
/// pane knows nothing of files or voices.
struct SpeakerNamer {
    /// you are named in settings, not here.
    let isNameable: (_ speaker: String) -> Bool
    /// the label a name replaced (`them 2`), when `speaker` is a name that
    /// can be taken back; nil for a speaker still on its label.
    let revertLabel: (_ speaker: String) -> String?
    /// the people this mac remembers.
    let suggestions: () -> [String]
    /// names `speaker` everywhere in the meeting; a blank name puts the
    /// label back.
    let apply: (_ speaker: String, _ name: String) -> Void
}

/// the small sheet behind a speaker's label: a field, the people already
/// known, and the way back. plain controls; return names, escape cancels.
struct SpeakerNameForm: View {
    let speaker: String
    let namer: SpeakerNamer
    let done: (_ name: String) -> Void
    let cancel: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        speaker: String, namer: SpeakerNamer,
        done: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        self.speaker = speaker
        self.namer = namer
        self.done = done
        self.cancel = cancel
        _draft = State(initialValue: SpeakerNames.isOriginal(speaker) ? "" : speaker)
    }

    private var cleaned: String? { SpeakerNames.clean(draft) }

    private var canName: Bool {
        guard let cleaned else { return false }
        return cleaned != speaker
    }

    /// the remembered people the field's text leads to, without the one
    /// this speaker already is.
    private var suggestions: [String] {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return namer.suggestions()
            .filter { $0 != speaker }
            .filter { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) }
            .prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("name this speaker")
                .font(.headline)
            TextField("name", text: $draft, prompt: Text("who is \(speaker)?"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(name)
                .accessibilityLabel("name for \(speaker)")
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("people andrew knows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { person in
                        Button(person) { done(person) }
                            .buttonStyle(.link)
                            .accessibilityLabel("name them \(person)")
                    }
                }
            }
            HStack {
                if let label = namer.revertLabel(speaker) {
                    Button("back to \(label)") { done("") }
                }
                Spacer()
                Button("cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("name", action: name)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canName)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { focused = true }
    }

    private func name() {
        guard canName, let cleaned else { return }
        done(cleaned)
    }
}
