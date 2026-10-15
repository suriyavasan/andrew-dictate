import Combine
import Foundation

/// the rewrite's settings (fn+⌃): whether it is on, who answers, with which
/// model, and the styles of your own. kept apart from `AppSettings` because
/// none of it touches dictation unless you turn it on. secrets are never
/// here: keys and sign-ins live in the keychain (`CredentialStore`).
@MainActor
final class RewriteSettings: ObservableObject {
    static let shared = RewriteSettings()

    /// off by default: plain dictation never leaves the mac, and the
    /// rewrite is the one path that can.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            userDefaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    @Published var provider: RewriteProvider {
        didSet {
            guard provider != oldValue else { return }
            userDefaults.set(provider.rawValue, forKey: Self.providerKey)
        }
    }

    /// the model each provider was last told to use; a provider never
    /// picked uses its default.
    @Published private(set) var models: [RewriteProvider: String] {
        didSet {
            guard models != oldValue else { return }
            let stored = Dictionary(
                uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }
            )
            userDefaults.set(stored, forKey: Self.modelsKey)
        }
    }

    /// yours, in the order the picker shows them, after the three built-in.
    @Published var customStyles: [RewriteStyle] {
        didSet {
            guard customStyles != oldValue else { return }
            if let data = try? JSONEncoder().encode(customStyles) {
                userDefaults.set(data, forKey: Self.customStylesKey)
            }
        }
    }

    /// the style a take gets when you don't reach for the picker, and the
    /// one the picker starts on and takes when its time runs out. chosen
    /// here, never by the last pick: a hidden picker must not move it.
    @Published var defaultStyleID: String {
        didSet {
            guard defaultStyleID != oldValue else { return }
            userDefaults.set(defaultStyleID, forKey: Self.defaultStyleKey)
        }
    }

    /// the second key held with the dictation key (fn+⌃).
    @Published var modifier: RewriteModifier {
        didSet {
            guard modifier != oldValue else { return }
            userDefaults.set(modifier.rawValue, forKey: Self.modifierKey)
        }
    }

    /// meetings are summarized by the same provider when they end. on by
    /// default: a summary is what a meeting is recorded for, and with no
    /// provider set up it asks for nothing.
    @Published var summariesEnabled: Bool {
        didSet {
            guard summariesEnabled != oldValue else { return }
            userDefaults.set(summariesEnabled, forKey: Self.summariesKey)
        }
    }

    /// the template a meeting is summarized with unless it has its own.
    @Published var defaultTemplateID: String {
        didSet {
            guard defaultTemplateID != oldValue else { return }
            userDefaults.set(defaultTemplateID, forKey: Self.templateKey)
        }
    }

    private let userDefaults: UserDefaults

    private static let enabledKey = "AndrewDictate.rewrite.enabled"
    private static let providerKey = "AndrewDictate.rewrite.provider"
    private static let modelsKey = "AndrewDictate.rewrite.models"
    private static let customStylesKey = "AndrewDictate.rewrite.customStyles"
    private static let defaultStyleKey = "AndrewDictate.rewrite.defaultStyle"
    private static let modifierKey = "AndrewDictate.rewrite.modifier"
    private static let summariesKey = "AndrewDictate.ai.summaries"
    private static let templateKey = "AndrewDictate.ai.template"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: Self.enabledKey)
        provider = userDefaults.string(forKey: Self.providerKey)
            .flatMap(RewriteProvider.init(rawValue:)) ?? .chatGPT
        let storedModels = userDefaults.dictionary(forKey: Self.modelsKey)
            as? [String: String] ?? [:]
        models = Dictionary(
            uniqueKeysWithValues: storedModels.compactMap { key, value in
                RewriteProvider(rawValue: key).map { ($0, value) }
            }
        )
        customStyles = userDefaults.data(forKey: Self.customStylesKey)
            .flatMap { try? JSONDecoder().decode([RewriteStyle].self, from: $0) }
            ?? []
        defaultStyleID = userDefaults.string(forKey: Self.defaultStyleKey)
            ?? RewriteStyle.auto.id
        modifier = userDefaults.string(forKey: Self.modifierKey)
            .flatMap(RewriteModifier.init(rawValue:)) ?? .control
        summariesEnabled = userDefaults.object(forKey: Self.summariesKey) as? Bool ?? true
        defaultTemplateID = userDefaults.string(forKey: Self.templateKey)
            ?? MeetingTemplate.auto.id
    }

    func model(for provider: RewriteProvider) -> String {
        let chosen = models[provider]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chosen, !chosen.isEmpty else {
            return provider.defaultModel
        }
        return chosen
    }

    func setModel(_ model: String, for provider: RewriteProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        models[provider] = trimmed.isEmpty ? nil : trimmed
    }

    /// what the picker offers, in order: the three built-in, then yours, at
    /// most nine in all — one per digit key.
    var pickerStyles: [RewriteStyle] {
        Array(
            (RewriteStyle.builtIn + customStyles)
                .prefix(RewriteStyle.builtIn.count + RewriteStyle.maximumCustom)
        )
    }

    var canAddStyle: Bool {
        customStyles.count < RewriteStyle.maximumCustom
    }

    func save(_ style: RewriteStyle) {
        guard !style.isBuiltIn else { return }
        if let index = customStyles.firstIndex(where: { $0.id == style.id }) {
            customStyles[index] = style
        } else if canAddStyle {
            customStyles.append(style)
        }
    }

    func remove(_ style: RewriteStyle) {
        customStyles.removeAll { $0.id == style.id }
        if defaultStyleID == style.id {
            defaultStyleID = RewriteStyle.auto.id
        }
    }
}
