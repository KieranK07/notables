import Foundation

// Mirrors docs/PROTOCOL.md. Keep the two in sync.

struct Note: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var course: String
    var section: String?
    var topic: String?
    var classDate: String?          // "2026-09-04" — the day of the class; notes sort by this
    var recordedAt: Date?
    var durationSec: Double?
    var state: NoteState
    var tags: [String]
    var summary: String?
    var actionItemCount: Int?
    var notePath: String?
    var transcriptPath: String?
    var updatedAt: Date?
    /// "whisper" (the PC's GPU pass) or "draft" (this Mac's rough live pass). A draft means
    /// whisper failed and the lecture fell back — the user must be able to see that.
    var transcriptSource: String?

    enum CodingKeys: String, CodingKey {
        case id, title, course, section, topic, classDate, recordedAt, durationSec
        case state, tags, summary, actionItemCount, notePath, transcriptPath, updatedAt
        case transcriptSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        course = (try? c.decode(String.self, forKey: .course)) ?? "Unfiled"
        section = try? c.decodeIfPresent(String.self, forKey: .section)
        topic = try? c.decodeIfPresent(String.self, forKey: .topic)
        classDate = try? c.decodeIfPresent(String.self, forKey: .classDate)
        recordedAt = Note.date(c, .recordedAt)
        durationSec = try? c.decodeIfPresent(Double.self, forKey: .durationSec)
        state = (try? c.decode(NoteState.self, forKey: .state)) ?? .ready
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        actionItemCount = try? c.decodeIfPresent(Int.self, forKey: .actionItemCount)
        notePath = try? c.decodeIfPresent(String.self, forKey: .notePath)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        updatedAt = Note.date(c, .updatedAt)
        transcriptSource = try? c.decodeIfPresent(String.self, forKey: .transcriptSource)
    }

    /// True when the note was written from the rough on-device draft rather than whisper.
    var isDraftTranscript: Bool { transcriptSource == "draft" }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) -> Date? {
        guard let s = try? c.decode(String.self, forKey: k) else { return nil }
        return ISO8601.parse(s)
    }

    /// The date the note files under: the class day when we have it, else when it was recorded.
    var sortDate: Date {
        if let d = classDate, let parsed = DateFormatter.ymd.date(from: d) { return parsed }
        return recordedAt ?? .distantPast
    }

    /// Section is rendered as its own pill, so it is deliberately absent here.
    var displaySubtitle: String {
        var parts = [DateFormatter.friendly.string(from: sortDate)]
        if let d = durationSec, d > 0 { parts.append("\(Int(d / 60)) min") }
        return parts.joined(separator: " · ")
    }
}

/// The lifecycle in docs/PROTOCOL.md:
/// `awaiting_audio` → `transcribing` → `processing` → `ready`, or `failed` at any step.
enum NoteState: String, Codable, Hashable {
    case queued
    case awaitingAudio = "awaiting_audio"
    case transcribing
    case processing
    case ready
    case failed

    /// Unknown future states decode as `.processing` rather than dropping the note.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "ready"
        self = NoteState(rawValue: raw) ?? .processing
    }

    var isSettled: Bool { self == .ready || self == .failed }

    /// What the user is actually waiting on.
    var progressLabel: String {
        switch self {
        case .queued:        return "Queued"
        case .awaitingAudio: return "Uploading audio…"
        case .transcribing:  return "Transcribing on the PC…"
        case .processing:    return "Claude is writing it up…"
        case .ready:         return "Ready"
        case .failed:        return "Failed"
        }
    }
}

struct Course: Codable, Identifiable, Hashable {
    var name: String
    var noteCount: Int
    var lastClass: String?
    var id: String { name }
}

struct Todo: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var due: String?
    var course: String?
    var done: Bool
    var source: String?

    // Canvas assignments carry more than a line of text.
    var kind: String?          // "assignment" when it came from Canvas
    var dueAt: String?         // full timestamp, so 11:59pm can be shown
    var url: String?           // back to Canvas
    var points: Double?
    var submitted: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        due = try? c.decodeIfPresent(String.self, forKey: .due)
        course = try? c.decodeIfPresent(String.self, forKey: .course)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        dueAt = try? c.decodeIfPresent(String.self, forKey: .dueAt)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        points = try? c.decodeIfPresent(Double.self, forKey: .points)
        submitted = try? c.decodeIfPresent(Bool.self, forKey: .submitted)
    }
    enum CodingKeys: String, CodingKey {
        case id, text, due, course, done, source, kind, dueAt, url, points, submitted
    }

    /// From Canvas, as opposed to something a lecturer said out loud.
    var isAssignment: Bool { kind == "assignment" }
    var dueStyle: DueStyle { done ? .none : Dates.style(for: due) }
    var dueDisplay: String? { due == nil ? nil : Dates.relative(due) }
    var dueTime: String? { Dates.timeOfDay(dueAt) }
    var isOverdue: Bool { !done && dueStyle == .overdue }
    var pointsDisplay: String? {
        guard let p = points, p > 0 else { return nil }
        return p == p.rounded() ? "\(Int(p)) pts" : String(format: "%.1f pts", p)
    }
}

struct NotesIndex: Codable {
    var courses: [Course]
    var notes: [Note]
    var todos: [Todo]?
}

struct NoteDetail: Codable {
    var id: String
    var markdown: String?
    var transcript: String?
}

// MARK: - Date helpers

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
    static func string(_ d: Date) -> String { plain.string(from: d) }
}

extension DateFormatter {
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let friendly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    static let friendlyYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                 : String(format: "%d:%02d", m, sec)
}
