import Foundation

/// the shape a meeting's notes are asked to take: which sections, in what
/// order, and what each is for. the built-ins and their section lists are
/// adapted from muesli (MIT), github.com/Muesli-HQ/muesli,
/// MeetingTemplates.swift. the names are ours and lowercase, like the rest
/// of what the app says; `instructions` goes to the model as it is, in
/// english, whatever language the app speaks to you in.
///
/// `id` is what a meeting's file keeps in `template:` and what settings
/// keep as the default, so a case may be renamed in swift and its id never
/// changes.
struct MeetingTemplate: Equatable, Sendable, Identifiable {
    let id: String
    /// what a picker says.
    let name: String
    /// an SF Symbol.
    let symbol: String
    /// the sections, as the prompt says them. ends the system prompt.
    let instructions: String

    static let auto = MeetingTemplate(
        id: "auto",
        name: "auto",
        symbol: "sparkles",
        instructions: """
        Use this structure exactly:

        ## Meeting Summary
        A 2-3 sentence overview of what was discussed.

        ## Key Discussion Points
        - Bullet points of the main topics discussed

        ## Decisions Made
        - Bullet points of any decisions reached

        ## Action Items
        - [ ] Bullet points of tasks assigned or agreed upon, with owners if mentioned

        ## Notable Quotes
        - Any important or notable statements, if applicable
        """)

    static let oneToOne = MeetingTemplate(
        id: "oneToOne",
        name: "1 to 1",
        symbol: "person.2.fill",
        instructions: """
        Use this structure exactly:

        ## Check-In
        A brief summary of how the conversation opened and the overall tone.

        ## Topics Discussed
        - Main themes raised by either person

        ## Support Needed
        - Blockers, concerns, or asks for help

        ## Commitments
        - [ ] Follow-ups or commitments made by either person

        ## Manager Notes
        - Coaching, feedback, or context that should be remembered
        """)

    static let customerDiscovery = MeetingTemplate(
        id: "customerDiscovery",
        name: "customer discovery",
        symbol: "person.crop.circle.badge.questionmark",
        instructions: """
        Use this structure exactly:

        ## Customer Context
        - Company, role, or situation if mentioned

        ## Problems and Pain Points
        - Explicit frustrations, blockers, or unmet needs

        ## Current Workflow
        - How they currently solve the problem today

        ## Buying Signals
        - Indicators of urgency, budget, timing, or decision process

        ## Next Steps
        - [ ] Follow-up actions, owners, and dates if mentioned
        """)

    static let hiring = MeetingTemplate(
        id: "hiring",
        name: "hiring",
        symbol: "briefcase.fill",
        instructions: """
        Use this structure exactly:

        ## Candidate Snapshot
        A concise overview of the candidate and relevant background.

        ## Strengths
        - Positive signals from the conversation

        ## Concerns
        - Risks, gaps, or open questions

        ## Role Fit
        - Why they do or do not fit the role as discussed

        ## Decision and Next Steps
        - [ ] Hiring decision, interview progression, or follow-up items
        """)

    static let standUp = MeetingTemplate(
        id: "standUp",
        name: "stand-up",
        symbol: "figure.stand",
        instructions: """
        Use this structure exactly:

        ## Yesterday
        - Work completed or progress since the last update

        ## Today
        - Planned work or priorities for today

        ## Blockers
        - Risks, delays, or dependencies

        ## Coordination Notes
        - Decisions, asks, or cross-team alignment points
        """)

    static let weeklyTeam = MeetingTemplate(
        id: "weeklyTeam",
        name: "weekly team",
        symbol: "calendar",
        instructions: """
        Use this structure exactly:

        ## Weekly Overview
        A concise summary of the most important updates from the meeting.

        ## Progress Updates
        - Key workstreams and status changes

        ## Decisions
        - Decisions made or confirmed

        ## Risks and Open Questions
        - Issues that need attention or follow-up

        ## Action Items
        - [ ] Tasks, owners, and timing if mentioned
        """)

    /// in the order a picker lists them: the one that fits anything first.
    static let builtIn: [MeetingTemplate] = [
        auto, oneToOne, customerDiscovery, hiring, standUp, weeklyTeam,
    ]

    /// the template a file or a setting names, or `auto` for an id this
    /// build does not know (a file written by a later one, a setting left
    /// from a template that was taken out): notes are still worth having.
    static func resolving(_ id: String?) -> MeetingTemplate {
        builtIn.first { $0.id == id } ?? auto
    }
}
