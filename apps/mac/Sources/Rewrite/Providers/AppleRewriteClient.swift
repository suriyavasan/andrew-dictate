import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// whether apple's on-device model can take a rewrite, in words that name
/// the user's next move. the os says exactly which reason it is — "needs
/// macOS 26" was the old answer, and it was wrong on a mac already on 26.
enum AppleModelAvailability: Equatable, Sendable {
    case available
    case appleIntelligenceOff
    case stillDownloading
    case deviceCannotRunIt

    var reason: String? {
        switch self {
        case .available:
            nil
        case .appleIntelligenceOff:
            "turn on apple intelligence"
        case .stillDownloading:
            "the model is still downloading"
        case .deviceCannotRunIt:
            "this mac can't run it"
        }
    }

    static var current: AppleModelAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .stillDownloading
        case .unavailable:
            return .deviceCannotRunIt
        }
        #else
        return .deviceCannotRunIt
        #endif
    }
}

/// the rewrite on this mac: apple's foundation model, nothing sent
/// anywhere. there is one model, so the model id is ignored. a fresh
/// session per rewrite — a rewrite has no history to carry.
struct AppleRewriteClient: RewriteClient {
    /// read at each rewrite, not at init: apple intelligence can be turned
    /// on, or finish downloading, while the app runs.
    let availability: @Sendable () -> AppleModelAvailability

    init(availability: @escaping @Sendable () -> AppleModelAvailability = { .current }) {
        self.availability = availability
    }

    func rewrite(_ prompt: RewritePrompt, model: String) async throws -> String {
        if let reason = availability().reason {
            throw RewriteFailure.unavailable(reason)
        }
        #if canImport(FoundationModels)
        let answer: String
        do {
            let session = LanguageModelSession(instructions: prompt.instructions)
            answer = try await session.respond(to: prompt.text).content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.failure(from: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RewriteFailure.unavailable("apple's model couldn't do it")
        }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RewriteFailure.emptyAnswer
        }
        return trimmed
        #else
        throw RewriteFailure.unavailable(AppleModelAvailability.deviceCannotRunIt.reason!)
        #endif
    }

    #if canImport(FoundationModels)
    static func failure(from error: LanguageModelSession.GenerationError) -> RewriteFailure {
        switch error {
        case .exceededContextWindowSize:
            .unavailable("too long for apple's model")
        case .assetsUnavailable:
            .unavailable(AppleModelAvailability.stillDownloading.reason!)
        case .guardrailViolation, .refusal:
            .unavailable("apple's model refused this")
        case .unsupportedLanguageOrLocale:
            .unavailable("apple's model doesn't know this language")
        case .rateLimited, .concurrentRequests:
            .rateLimited(.apple)
        default:
            .unavailable("apple's model couldn't do it")
        }
    }
    #endif
}
