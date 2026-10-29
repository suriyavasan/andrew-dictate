import Foundation

/// the four tools, their words, and what each does with its arguments. the
/// descriptions are written for the model that reads them: the first thing it
/// learns about this server, and what stops it reading `them 2` as a name.
struct MCPTools {
    struct Tool {
        let name: String
        let title: String
        let description: String
        let schema: OrderedJSON
    }

    /// what the model is told about names once, at `initialize`, and again in
    /// the tools that return them.
    static let aboutNames = """
    speaker names come from the call app's own window, from voices the user \
    has named and the app remembers, or from the user naming a speaker by \
    hand; the user's own name is theirs from settings. a speaker called \
    “them”, “them 2” and so on is not named: the app heard another voice and \
    does not know whose. do not guess who it is from the words alone, and \
    say so when a question depends on it.
    """

    static let instructions = """
    the user's meetings, recorded on this mac by andrew dictate: saved \
    transcripts, and the meeting recording right now. read-only. \
    \(aboutNames)
    """

    let tools: [Tool] = [
        Tool(
            name: "list_meetings",
            title: "list meetings",
            description: """
            the user's saved meetings, newest first: id, title, app, when it \
            started, how long it ran, and who was in it (participants are \
            named people; speakers are every label the transcript uses). \
            `query` filters by title, app or a person's name, not by what \
            was said: use search_meetings for that. \(aboutNames)
            """,
            schema: schema([
                ("limit", "integer", "how many meetings, newest first. default 20, at most 200."),
                ("since", "string", "only meetings that started at or after this: a date (2026-10-01) or a time with an offset."),
                ("query", "string", "words that must appear in the title, the app or a person's name."),
            ])),
        Tool(
            name: "get_meeting",
            title: "get a meeting",
            description: """
            one saved meeting by the id list_meetings gives. by default the \
            markdown file as it is: front matter (app, started, duration, \
            speakers, participants, and `voices`, which says which label each \
            name replaced), the notes if there are any, and the transcript as \
            `[hh:mm:ss] speaker: text`. with format “turns”, the same as \
            structured turns: [{at, speaker, text}], with `session` on each \
            when the meeting was recorded into more than once. \(aboutNames)
            """,
            schema: schema([
                ("id", "string", "the meeting's id, from list_meetings."),
                ("format", "string", "“markdown” (default) or “turns”."),
            ], required: ["id"])),
        Tool(
            name: "search_meetings",
            title: "search what was said",
            description: """
            turns across all saved meetings that say every word of `query` \
            (any case), newest first, each with the meeting, the time in it \
            and who said it. `speaker` keeps only one person's turns: a name, \
            “you” for the user, or a label such as “them 2”. the query may be \
            empty when a speaker is given. \(aboutNames)
            """,
            schema: schema([
                ("query", "string", "words the turn must contain. all of them, in any order."),
                ("speaker", "string", "only this speaker: a name, “you”, or a label like “them 2”."),
                ("limit", "integer", "how many turns. default 20, at most 100."),
            ], required: ["query"])),
        Tool(
            name: "get_live_meeting",
            title: "the meeting recording now",
            description: """
            whether a meeting is recording on this mac right now, and if so \
            its app, when it started, the people named so far and its lines \
            so far: seq, time, side (you or them), speaker, text. poll it: \
            pass the `last_seq` you were given as `after_seq` to get only \
            what was said since. while a meeting records the far side is \
            “them” and only the user is named; the other people are named in \
            the saved transcript once the meeting ends. when nothing is \
            recording it says so and names the last meeting and where it \
            was saved. \(aboutNames)
            """,
            schema: schema([
                ("after_seq", "integer", "only lines after this sequence number. omit it for the latest lines."),
            ])),
    ]

    private static func schema(
        _ properties: [(String, String, String)], required: [String] = []
    ) -> OrderedJSON {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties.map { name, type, words in
                (name, .object([("type", .string(type)), ("description", .string(words))]))
            })),
            ("required", .array(required.map { .string($0) })),
            ("additionalProperties", .bool(false)),
        ])
    }

    func listed() -> OrderedJSON {
        .array(tools.map {
            .object([
                ("name", .string($0.name)),
                ("title", .string($0.title)),
                ("description", .string($0.description)),
                ("inputSchema", $0.schema),
                ("annotations", .object([
                    ("readOnlyHint", .bool(true)),
                    ("destructiveHint", .bool(false)),
                    ("idempotentHint", .bool(true)),
                    ("openWorldHint", .bool(false)),
                ])),
            ])
        })
    }

    /// the text a tool answers with, or the sentence that says what was
    /// wrong with the call. nil for a name that is no tool.
    func call(
        _ name: String, _ arguments: [String: Any], on reader: MeetingsReader
    ) -> Result<String, MeetingsReader.Failure>? {
        guard tools.contains(where: { $0.name == name }) else { return nil }
        do {
            switch name {
            case "list_meetings":
                let since = try text("since", arguments).map { value -> Date in
                    guard let date = MeetingsReader.date(from: value) else {
                        throw MeetingsReader.Failure(
                            message: "since must be a date like 2026-10-01 or a time like 2026-10-01T09:00:00+05:30.")
                    }
                    return date
                }
                return .success(reader.listMeetings(
                    limit: try integer("limit", arguments), since: since,
                    query: try text("query", arguments)).pretty)
            case "get_meeting":
                guard let id = try text("id", arguments), !id.isEmpty else {
                    throw MeetingsReader.Failure(message: "id is required: an id from list_meetings.")
                }
                let format = try text("format", arguments) ?? "markdown"
                guard ["markdown", "turns"].contains(format) else {
                    throw MeetingsReader.Failure(message: "format is “markdown” or “turns”.")
                }
                return .success(try reader.getMeeting(id: id, turns: format == "turns"))
            case "search_meetings":
                let query = try text("query", arguments) ?? ""
                let speaker = try text("speaker", arguments)
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty
                        || !(speaker ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    throw MeetingsReader.Failure(message: "query is required, unless a speaker is given.")
                }
                return .success(reader.searchMeetings(
                    query: query, speaker: speaker, limit: try integer("limit", arguments)).pretty)
            default:
                return .success(reader.liveMeeting(afterSeq: try integer("after_seq", arguments)).pretty)
            }
        } catch let failure as MeetingsReader.Failure {
            return .failure(failure)
        } catch {
            return .failure(.init(message: "the call could not be answered."))
        }
    }

    private func text(_ key: String, _ arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            throw MeetingsReader.Failure(message: "\(key) must be a string.")
        }
        return text
    }

    private func integer(_ key: String, _ arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           let int = Int(exactly: number.doubleValue) {
            return int
        }
        throw MeetingsReader.Failure(message: "\(key) must be a whole number.")
    }
}
