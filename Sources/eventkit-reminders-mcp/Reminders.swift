// EventKit access, lookups and the JSON shape of a reminder.
import EventKit
import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class Box<T> { var value: T; init(_ v: T) { value = v } }

/// JSON-safe optional: nil becomes null.
func jv(_ x: Any?) -> Any { x ?? NSNull() }

enum Status: String { case open, completed, all }

final class Reminders {
    let ek = EKEventStore()

    static let accessHelp = """
        No Reminders access. Open System Settings → Privacy & Security → Reminders and allow the app that \
        launches this server (your terminal, or Claude), then restart the server.
        """

    func ensureAccess() throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return
        case .notDetermined:
            let ok = Box(false), sem = DispatchSemaphore(value: 0)
            ek.requestFullAccessToReminders { granted, _ in ok.value = granted; sem.signal() }
            sem.wait()
            if !ok.value { throw ToolError(Self.accessHelp) }
        default: throw ToolError(Self.accessHelp)
        }
    }

    var lists: [EKCalendar] {
        ek.calendars(for: .reminder).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var defaultList: EKCalendar? { ek.defaultCalendarForNewReminders() }

    /// A list by id, exact title, or case-insensitive title. Ambiguous titles are an error, never a guess.
    func list(_ ref: String) throws -> EKCalendar {
        let all = ek.calendars(for: .reminder)
        if let c = all.first(where: { $0.calendarIdentifier == ref }) { return c }
        var hits = all.filter { $0.title == ref }
        if hits.isEmpty { hits = all.filter { $0.title.caseInsensitiveCompare(ref) == .orderedSame } }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { throw ToolError("No list '\(ref)'. Use reminders_list_lists to see list names and ids.") }
        throw ToolError("\(hits.count) lists are called '\(ref)'; pass a list id instead: "
            + hits.map { "\($0.calendarIdentifier) (\($0.source.title))" }.joined(separator: ", "))
    }

    func fetch(_ cals: [EKCalendar]?, status: Status) -> [EKReminder] {
        let pred: NSPredicate
        switch status {
        case .open: pred = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        case .completed: pred = ek.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: cals)
        case .all: pred = ek.predicateForReminders(in: cals)
        }
        let out = Box<[EKReminder]>([]), sem = DispatchSemaphore(value: 0)
        ek.fetchReminders(matching: pred) { rs in out.value = rs ?? []; sem.signal() }
        sem.wait()
        return out.value
    }

    func reminder(_ id: String) throws -> EKReminder {
        guard let r = ek.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError("No reminder with id '\(id)'.")
        }
        return r
    }
}

// MARK: - Dates

enum When {
    private static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = fmt
        return f
    }
    static let minute = formatter("yyyy-MM-dd HH:mm")
    static let day = formatter("yyyy-MM-dd")
    static let iso = ISO8601DateFormatter()

    /// "YYYY-MM-DD" (all-day) or "YYYY-MM-DD HH:MM" / "YYYY-MM-DDTHH:MM" in local time.
    static func parse(_ s: String) throws -> (DateComponents, allDay: Bool) {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        if let d = day.date(from: t), t.count == 10 {
            return (Calendar.current.dateComponents([.year, .month, .day], from: d), true)
        }
        if let d = minute.date(from: String(t.prefix(16))), t.count == 16 {
            var dc = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            // Without an explicit zone a timed due date is stored "floating" and read back as UTC
            // (an 08:00 reminder showed at 09:00 BST), so pin it to the local zone.
            dc.timeZone = .current
            return (dc, false)
        }
        throw ToolError("Bad date '\(s)'. Use 'YYYY-MM-DD' (all-day) or 'YYYY-MM-DD HH:MM' (local time).")
    }

    /// A filter bound: a date-only value means the start of that day.
    static func bound(_ s: String) throws -> Date {
        let (dc, _) = try parse(s)
        guard let d = Calendar.current.date(from: dc) else { throw ToolError("Bad date '\(s)'.") }
        return d
    }

    static func due(_ r: EKReminder) -> (date: Date, allDay: Bool)? {
        guard var dc = r.dueDateComponents else { return nil }
        let allDay = dc.hour == nil
        dc.calendar = Calendar.current
        if dc.timeZone == nil { dc.timeZone = allDay ? .current : (r.timeZone ?? .current) }
        guard let d = dc.date else { return nil }
        return (d, allDay)
    }

    static func dueString(_ r: EKReminder) -> String? {
        guard let (d, allDay) = due(r) else { return nil }
        return allDay ? day.string(from: d) : minute.string(from: d)
    }

    static func isOverdue(_ r: EKReminder, now: Date = Date()) -> Bool {
        guard !r.isCompleted, let (d, allDay) = due(r) else { return false }
        return allDay ? d < Calendar.current.startOfDay(for: now) : d < now
    }
}

// MARK: - Fields

enum Priority {
    /// EventKit: 0 none, 1–4 high, 5 medium, 6–9 low.
    static func name(_ p: Int) -> String {
        switch p { case 1...4: return "high"; case 5: return "medium"; case 6...9: return "low"; default: return "none" }
    }
    static func value(_ s: String) throws -> Int {
        switch s.lowercased() {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        case "none": return 0
        default: throw ToolError("Bad priority '\(s)'. Use high, medium, low or none.")
        }
    }
}

enum Recurrence {
    static let freqs: [String: EKRecurrenceFrequency] = ["daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly]

    static func describe(_ r: EKReminder) -> String? {
        guard let rule = r.recurrenceRules?.first else { return nil }
        let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"]
        let name = freqs.first(where: { $0.value == rule.frequency })?.key ?? "custom"
        if rule.interval == 1 { return name }
        return "every \(rule.interval) \(unit[name] ?? "period")s"
    }
}

func describe(_ r: EKReminder, notesChars: Int = 500) -> [String: Any] {
    var notes: Any = NSNull()
    if let n = r.notes, !n.isEmpty { notes = n.count > notesChars ? String(n.prefix(notesChars)) + "…" : n }
    var out: [String: Any] = [
        "id": r.calendarItemIdentifier,
        "title": r.title ?? "",
        "list": r.calendar.title,
        "list_id": r.calendar.calendarIdentifier,
        "completed": r.isCompleted,
        "due": jv(When.dueString(r)),
        "priority": Priority.name(r.priority),
        "notes": notes,
        "url": jv(r.url?.absoluteString),
        "recurrence": jv(Recurrence.describe(r)),
    ]
    if r.isCompleted, let c = r.completionDate { out["completed_at"] = When.minute.string(from: c) }
    if When.isOverdue(r) { out["overdue"] = true }
    if let a = r.alarms, !a.isEmpty { out["alarms"] = a.count }
    if let c = r.creationDate { out["created"] = When.minute.string(from: c) }
    return out
}
