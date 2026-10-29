import SwiftUI

/// the remembered voices as settings shows them. the book is read when the
/// pane opens and after every change here; a meeting that ends while the
/// pane is open is picked up the next time it is.
@MainActor
final class VoicesModel: ObservableObject {
    @Published private(set) var people: [VoicePerson] = []

    private let book: VoiceBook
    private let prints: MeetingVoicePrints

    init(book: VoiceBook = VoiceBook(), prints: MeetingVoicePrints = MeetingVoicePrints()) {
        self.book = book
        self.prints = prints
    }

    func reload() {
        people = book.people()
    }

    func forget(_ person: VoicePerson) {
        book.forget(person.name)
        reload()
    }

    /// the book, and the voices kept from each meeting with it: the point
    /// of "forget all" is that no voice is left on this mac.
    func forgetAll() {
        book.forgetAll()
        prints.discardAll()
        reload()
    }
}

/// settings › meetings: your name, and the people this mac recognises by
/// voice. plain controls: this is a row, not a design.
struct VoicesSettings: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var voices = VoicesModel()
    @State private var confirmingForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            yourName
            Divider()
            rememberVoices
            if settings.rememberVoices || !voices.people.isEmpty {
                people
            }
        }
        .onAppear { voices.reload() }
        .confirmationDialog(
            "forget every voice?", isPresented: $confirmingForgetAll
        ) {
            Button("forget all", role: .destructive) { voices.forgetAll() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("andrew stops recognising anyone. names already in your transcripts stay.")
        }
    }

    private var yourName: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(
                "your name",
                explanation: "what saved transcripts call you instead of “you”. leave it empty to stay “you”.")
            Spacer(minLength: 8)
            TextField("your name", text: $settings.yourName, prompt: Text("you"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("your name")
        }
    }

    private var rememberVoices: some View {
        SettingsToggleRow(
            "remember voices",
            explanation: "recognise people you have named, in later meetings. voices stay on this mac.",
            isOn: $settings.rememberVoices)
    }

    @ViewBuilder
    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("remembered people")
                    .font(BrandUI.bodyFont.weight(.medium))
                Spacer()
                Button("forget all…") { confirmingForgetAll = true }
                    .disabled(voices.people.isEmpty)
            }
            if voices.people.isEmpty {
                Text("nobody yet. name a speaker in the meetings window and andrew will know them next time.")
                    .font(.caption)
                    .foregroundStyle(BrandUI.textSecondary)
            } else {
                ForEach(voices.people) { person in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name)
                            Text(subtitle(person))
                                .font(.caption)
                                .foregroundStyle(BrandUI.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        Button("forget") { voices.forget(person) }
                            .accessibilityLabel("forget \(person.name)")
                    }
                }
            }
        }
    }

    private func subtitle(_ person: VoicePerson) -> String {
        let heard = person.samples == 1 ? "heard once" : "heard \(person.samples) times"
        return "\(heard) · \(person.updated.formatted(.relative(presentation: .named)))"
    }
}
