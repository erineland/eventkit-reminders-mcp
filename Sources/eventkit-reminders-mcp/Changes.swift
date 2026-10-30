// Every write goes through here: plan (validate, compute before → after, touch nothing), then apply
// all planned changes and commit once. Single-item tools are one-operation batches, so dry runs, the
// writable-list allowlist and the audit log behave the same everywhere.
import EventKit
import Foundation

struct Config {
    var writes = false
    var writableLists: Set<String>? = nil   // titles or ids; nil means any list
    var auditPath = NSString(string: "~/.local/state/eventkit-reminders-mcp/audit.log").expandingTildeInPath

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        var c = Config()
        let yes: Set<String> = ["1", "true", "yes", "on"]
        c.writes = yes.contains((env["REMINDERS_MCP_WRITE"] ?? "").lowercased())
            || CommandLine.arguments.contains("--write")
        if CommandLine.arguments.contains("--read-only") { c.writes = false }
        if let w = env["REMINDERS_MCP_WRITABLE_LISTS"], !w.isEmpty {
            c.writableLists = Set(w.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if let p = env["REMINDERS_MCP_AUDIT_LOG"], !p.isEmpty { c.auditPath = NSString(string: p).expandingTildeInPath }
        return c
    }
}

struct Args {
    let d: [String: Any]

    func has(_ k: String) -> Bool { d[k] != nil }
    func isNull(_ k: String) -> Bool { d[k] is NSNull }

    func str(_ k: String) throws -> String? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw ToolError("'\(k)' must be a string.") }
        return s
    }
    func req(_ k: String) throws -> String {
        guard let s = try str(k), !s.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError("'\(k)' is required.") }
        return s
    }
    func bool(_ k: String) throws -> Bool? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ToolError("'\(k)' must be true or false.") }
        return n.boolValue
    }
    func int(_ k: String) throws -> Int? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw ToolError("'\(k)' must be a number.") }
        return n.intValue
    }
}

final class Planned {
    let index: Int, op: String
    var id: String?, title: String?, list: String?
    var changes: [(field: String, from: Any, to: Any)] = []
    var error: String?, note: String?
    var apply: (() throws -> Void)?
    var touched: EKReminder?   // after apply: the saved reminder, for reporting its (new) id
    var snapshot: [String: Any]?   // a deleted reminder in full, so the audit log can recreate it

    init(_ index: Int, _ op: String) { self.index = index; self.op = op }

    func json() -> [String: Any] {
        var o: [String: Any] = ["index": index, "op": op]
        if let id { o["id"] = id }
        if let title { o["title"] = title }
        if let list { o["list"] = list }
        if !changes.isEmpty {
            var c: [String: Any] = [:]
            for ch in changes { c[ch.field] = ["from": ch.from, "to": ch.to] }
            o["changes"] = c
        }
        if let error { o["error"] = error }
        if let note { o["note"] = note }
        return o
    }
}

final class Engine {
    let rem: Reminders
    let cfg: Config
    init(_ rem: Reminders, _ cfg: Config) { self.rem = rem; self.cfg = cfg }

    var ek: EKEventStore { rem.ek }

    func checkWritable(_ cal: EKCalendar) throws {
        if let allow = cfg.writableLists, !allow.contains(cal.title), !allow.contains(cal.calendarIdentifier) {
            throw ToolError("List '\(cal.title)' is not in REMINDERS_MCP_WRITABLE_LISTS, so it can't be changed.")
        }
        if !cal.allowsContentModifications { throw ToolError("List '\(cal.title)' is read-only in Reminders.") }
    }

    // MARK: plan

    func plan(_ raw: Any, index: Int, allowDestructive: Bool) -> Planned {
        guard let d = raw as? [String: Any] else {
            let p = Planned(index, "?"); p.error = "Each operation must be an object."; return p
        }
        let a = Args(d: d)
        let op = ((try? a.str("op")) ?? nil)?.lowercased() ?? "?"
        let p = Planned(index, op)
        do {
            switch op {
            case "create": try planCreate(a, p)
            case "update": try planUpdate(a, p)
            case "move":
                guard a.has("to_list") || a.has("list") else { throw ToolError("'to_list' is required.") }
                try planUpdate(Args(d: ["id": d["id"] ?? NSNull(), "list": d["to_list"] ?? d["list"]!]), p)
            case "complete", "uncomplete":
                try planUpdate(Args(d: ["id": d["id"] ?? NSNull(), "completed": op == "complete"]), p)
            case "delete": try planDelete(a, p, allowDestructive: allowDestructive)
            default: throw ToolError("Unknown op '\(op)'. Use create, update, move, complete, uncomplete or delete.")
            }
        } catch {
            p.error = "\(error)"
            p.apply = nil
        }
        return p
    }

    private func planCreate(_ a: Args, _ p: Planned) throws {
        guard let cal = try a.str("list").map({ try rem.list($0) }) ?? rem.defaultList else {
            throw ToolError("No default Reminders list; pass 'list'.")
        }
        try checkWritable(cal)
        p.title = try a.req("title")
        p.list = cal.title
        let (changes, steps) = try edits(a, current: nil)
        p.changes = changes
        p.apply = { [ek] in
            let r = EKReminder(eventStore: ek)
            r.calendar = cal
            for s in steps { s(r) }
            try ek.save(r, commit: false)
            p.touched = r
        }
    }

    private func planUpdate(_ a: Args, _ p: Planned) throws {
        let id = try a.req("id")
        p.id = id
        let r = try rem.reminder(id)
        p.title = r.title
        p.list = r.calendar.title
        try checkWritable(r.calendar)
        var (changes, steps) = try edits(a, current: r)
        if let ref = try a.str("list") {
            let dest = try rem.list(ref)
            if dest.calendarIdentifier != r.calendar.calendarIdentifier {
                try checkWritable(dest)
                changes.append(("list", r.calendar.title, dest.title))
                steps.append { $0.calendar = dest }
            }
        }
        if changes.isEmpty { p.note = "Nothing to change."; return }
        p.changes = changes
        p.apply = { [ek] in
            for s in steps { s(r) }
            try ek.save(r, commit: false)
            p.touched = r
        }
    }

    private func planDelete(_ a: Args, _ p: Planned, allowDestructive: Bool) throws {
        let id = try a.req("id")
        p.id = id
        let r = try rem.reminder(id)
        p.title = r.title
        p.list = r.calendar.title
        try checkWritable(r.calendar)
        guard allowDestructive else { throw ToolError("Deletes are refused in a batch unless 'allow_destructive' is true.") }
        guard try a.bool("confirm") == true else { throw ToolError("Deleting needs 'confirm': true.") }
        if r.hasRecurrenceRules { p.note = "Repeating reminder: deleting removes the whole series." }
        p.changes = [("deleted", false, true)]
        p.snapshot = describe(r, notesChars: Int.max)
        p.apply = { [ek] in try ek.remove(r, commit: false) }
    }

    /// Field edits shared by create and update: the visible before → after, and the steps that apply them.
    private func edits(_ a: Args, current r: EKReminder?) throws
        -> ([(field: String, from: Any, to: Any)], [(EKReminder) -> Void])
    {
        var changes: [(field: String, from: Any, to: Any)] = []
        var steps: [(EKReminder) -> Void] = []
        func change(_ field: String, _ from: Any, _ to: Any, _ step: @escaping (EKReminder) -> Void) {
            if r != nil, "\(from)" == "\(to)" { return }
            changes.append((field, from, to))
            steps.append(step)
        }

        if a.has("title") {
            let t = try a.req("title")
            change("title", jv(r?.title), t) { $0.title = t }
        }
        if a.has("notes") {
            let n = try a.str("notes")
            change("notes", jv(r?.notes.flatMap { $0.isEmpty ? nil : $0 }), jv(n)) { $0.notes = n }
        }
        if a.has("url") {
            var u: URL?
            if let s = try a.str("url") {
                guard let parsed = URL(string: s), parsed.scheme != nil else { throw ToolError("Bad url '\(s)'.") }
                u = parsed
            }
            change("url", jv(r?.url?.absoluteString), jv(u?.absoluteString)) { $0.url = u }
        }
        if a.has("priority") {
            let v = try Priority.value(try a.req("priority"))
            change("priority", r.map { Priority.name($0.priority) } ?? "none", Priority.name(v)) { $0.priority = v }
        }
        if let c = try a.bool("completed") {
            change("completed", r?.isCompleted ?? false, c) { $0.isCompleted = c }
        }

        var dueAfter: Bool = r?.dueDateComponents != nil
        if a.has("due") {
            let alarm = try a.bool("alarm") ?? true
            if let s = try a.str("due") {
                let (dc, allDay) = try When.parse(s)
                dueAfter = true
                let shown = allDay ? s.prefix(10).description : When.minute.string(from: Calendar.current.date(from: dc)!)
                change("due", jv(r.flatMap { When.dueString($0) }), shown) { rem in
                    rem.dueDateComponents = dc
                    // Only the fixed-time alerts belong to the old due time, so only they are replaced. Alerts
                    // relative to the due date move with it, and location alerts ("when I get home") are kept.
                    let alarms = rem.alarms ?? []
                    alarms.filter { $0.absoluteDate != nil }.forEach { rem.removeAlarm($0) }
                    let hasRelative = alarms.contains { $0.absoluteDate == nil && $0.structuredLocation == nil }
                    if !allDay {
                        rem.timeZone = .current   // the components' own zone is dropped on save; the item's sticks
                        if alarm, !hasRelative, let at = Calendar.current.date(from: dc) { rem.addAlarm(EKAlarm(absoluteDate: at)) }
                    } else {
                        rem.timeZone = nil
                    }
                }
            } else {
                dueAfter = false
                change("due", jv(r.flatMap { When.dueString($0) }), NSNull()) { rem in
                    rem.dueDateComponents = nil
                    // Time alerts mean nothing without a due date; location alerts still do.
                    rem.alarms?.filter { $0.structuredLocation == nil }.forEach { rem.removeAlarm($0) }
                }
            }
        }

        if a.has("recurrence") {
            let s = (try a.str("recurrence") ?? "none").lowercased()
            let interval = try a.int("recurrence_interval") ?? 1
            guard interval >= 1 else { throw ToolError("'recurrence_interval' must be 1 or more.") }
            let before = r.flatMap { Recurrence.describe($0) }
            if s == "none" {
                change("recurrence", jv(before), NSNull()) { rem in rem.recurrenceRules?.forEach { rem.removeRecurrenceRule($0) } }
            } else {
                guard let f = Recurrence.freqs[s] else { throw ToolError("Bad recurrence '\(s)'. Use daily, weekly, monthly, yearly or none.") }
                guard dueAfter else { throw ToolError("A repeating reminder needs a due date; pass 'due' too.") }
                let unit = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"][s]!
                let after = interval == 1 ? s : "every \(interval) \(unit)s"
                change("recurrence", jv(before), after) { rem in
                    rem.recurrenceRules?.forEach { rem.removeRecurrenceRule($0) }
                    rem.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: f, interval: interval, end: nil))
                }
            }
        } else if !dueAfter, let r, r.hasRecurrenceRules, a.has("due") {
            throw ToolError("This reminder repeats; clearing its due date needs 'recurrence': 'none' too.")
        }
        return (changes, steps)
    }

    // MARK: run

    func run(_ ops: [Any], dryRun: Bool, allowDestructive: Bool, tool: String) throws -> [String: Any] {
        guard cfg.writes else { throw ToolError("Writes are disabled (read-only mode). Start the server with REMINDERS_MCP_WRITE=1 to allow changes.") }
        guard !ops.isEmpty else { throw ToolError("No operations given.") }
        guard ops.count <= 500 else { throw ToolError("At most 500 operations per batch.") }

        let plans = ops.enumerated().map { plan($1, index: $0, allowDestructive: allowDestructive) }
        // Two operations on one reminder would race each other's saves; one 'update' can change every field.
        var seen = Set<String>()
        for p in plans where p.error == nil {
            if let id = p.id, !seen.insert(id).inserted {
                p.error = "This reminder already appears earlier in the batch; combine the changes into one 'update'."
                p.apply = nil
            }
        }

        let bad = plans.filter { $0.error != nil }
        let todo = plans.filter { $0.apply != nil }
        var out: [String: Any] = ["dry_run": dryRun, "operations": plans.map { $0.json() }]

        if dryRun {
            out["result"] = bad.isEmpty
                ? "Dry run: \(todo.count) change(s) planned, nothing written. Run again with dry_run: false to apply."
                : "Dry run: \(bad.count) operation(s) would be refused (see 'error'), so applying this batch would change nothing."
            return out
        }
        if !bad.isEmpty {
            out["result"] = "Refused: \(bad.count) operation(s) invalid (see 'error'). Nothing was changed."
            return out
        }

        do {
            for p in todo { try p.apply?() }
            try ek.commit()
        } catch {
            ek.reset()
            throw ToolError("Saving failed, nothing was committed: \(error.localizedDescription)")
        }

        // Report ids as they are after the save (a new reminder only has one now).
        for p in todo {
            if let r = p.touched {
                let now = r.calendarItemIdentifier
                if p.id == nil { p.id = now } else if p.id != now { p.note = "id changed on save; new id \(now)"; p.id = now }
            }
        }
        out["operations"] = plans.map { $0.json() }
        out["result"] = "Applied \(todo.count) change(s)."
        if let warn = Audit.write(cfg.auditPath, tool: tool, entries: todo.map { p in
            var e = p.json()
            if let s = p.snapshot { e["deleted_reminder"] = s }
            return e
        }) { out["audit_warning"] = warn }
        return out
    }
}

enum Audit {
    /// Append one JSON line per write call. Returns a warning instead of failing: the change is already saved.
    static func write(_ path: String, tool: String, entries: [[String: Any]]) -> String? {
        let line: [String: Any] = ["ts": When.iso.string(from: Date()), "tool": tool, "changes": entries]
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
            return nil
        } catch {
            return "Change saved, but the audit log couldn't be written: \(error.localizedDescription)"
        }
    }
}
