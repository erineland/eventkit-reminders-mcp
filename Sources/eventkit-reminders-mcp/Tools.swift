// The MCP tools: schemas and handlers. Reads return data; every write goes through Engine.run.
import EventKit
import Foundation

struct Tool {
    let name: String
    let description: String
    let properties: [String: Any]
    var required: [String] = []
    var write = false
    var destructive = false
    let handler: (Args) throws -> [String: Any]

    func listing() -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema,
                "annotations": ["readOnlyHint": !write, "destructiveHint": destructive,
                                "idempotentHint": !write, "openWorldHint": false]]
    }
}

private func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }
private let dateHelp = "'YYYY-MM-DD' (all-day) or 'YYYY-MM-DD HH:MM' (local time)"

/// Fields accepted by create and update.
private let fieldProps: [String: Any] = [
    "title": prop("string", "Title."),
    "notes": prop("string", "Notes; null clears."),
    "url": prop("string", "URL; null clears."),
    "priority": ["type": "string", "enum": ["high", "medium", "low", "none"]],
    "due": prop("string", "Due date, \(dateHelp); null clears. A timed due date gets an alert at that time unless 'alarm' is false."),
    "alarm": prop("boolean", "Add an alert at a timed due date. Default true."),
    "recurrence": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly", "none"],
                   "description": "Repeat, counted from the due date (which it needs). 'none' stops it repeating."],
    "recurrence_interval": prop("integer", "Every N days/weeks/… Default 1."),
]

func makeTools(_ rem: Reminders, _ engine: Engine) -> [Tool] {
    let cfg = engine.cfg

    func write(_ tool: String, _ a: Args, _ op: [String: Any], destructive: Bool = false) throws -> [String: Any] {
        try engine.run([op], dryRun: try a.bool("dry_run") ?? false, allowDestructive: destructive, tool: tool)
    }
    let dryRunProp = prop("boolean", "Show the planned change without saving it. Default false.")

    var tools: [Tool] = [
        Tool(name: "reminders_list_lists",
             description: "All Reminders lists with their ids, account and open/overdue counts.",
             properties: [:]) { _ in
            let open = rem.fetch(nil, status: .open)
            var counts: [String: (Int, Int)] = [:]
            let now = Date()
            for r in open {
                let k = r.calendar.calendarIdentifier
                let (o, od) = counts[k] ?? (0, 0)
                counts[k] = (o + 1, od + (When.isOverdue(r, now: now) ? 1 : 0))
            }
            let lists: [[String: Any]] = rem.lists.map { c in
                let (o, od) = counts[c.calendarIdentifier] ?? (0, 0)
                var w = cfg.writes && c.allowsContentModifications
                if let allow = cfg.writableLists { w = w && (allow.contains(c.title) || allow.contains(c.calendarIdentifier)) }
                return ["id": c.calendarIdentifier, "title": c.title, "account": c.source.title,
                        "open": o, "overdue": od, "writable": w,
                        "default": c.calendarIdentifier == rem.defaultList?.calendarIdentifier]
            }
            return ["lists": lists, "open_total": open.count, "writes_enabled": cfg.writes]
        },

        Tool(name: "reminders_list",
             description: "Reminders, filtered. Sorted by due date (undated last). Results carry stable ids for writes.",
             properties: [
                "list": prop("string", "List title or id. Omit for every list."),
                "status": ["type": "string", "enum": ["open", "completed", "all"], "description": "Default open."],
                "text": prop("string", "Only reminders whose title or notes contain this (case-insensitive)."),
                "overdue": prop("boolean", "true: only overdue."),
                "undated": prop("boolean", "true: only reminders with no due date; false: only dated ones."),
                "due_before": prop("string", "Due before this, \(dateHelp)."),
                "due_after": prop("string", "Due on or after this, \(dateHelp)."),
                "priority": ["type": "string", "enum": ["high", "medium", "low", "none"]],
                "limit": prop("integer", "Default 100, max 1000."),
                "offset": prop("integer", "Skip this many (paging)."),
             ]) { a in try query(rem, a, text: try a.str("text")) },

        Tool(name: "reminders_search",
             description: "Text search across every list's titles and notes (case-insensitive).",
             properties: [
                "query": prop("string", "Text to find."),
                "status": ["type": "string", "enum": ["open", "completed", "all"], "description": "Default open."],
                "limit": prop("integer", "Default 100, max 1000."),
             ], required: ["query"]) { a in try query(rem, a, text: try a.req("query")) },

        Tool(name: "reminders_get",
             description: "Full details of reminders by id (notes untruncated).",
             properties: ["ids": ["type": "array", "items": ["type": "string"], "description": "Reminder ids."]],
             required: ["ids"]) { a in
            guard let ids = a.d["ids"] as? [String], !ids.isEmpty else { throw ToolError("'ids' must be a list of reminder ids.") }
            var found: [[String: Any]] = [], missing: [String] = []
            for id in ids {
                if let r = try? rem.reminder(id) { found.append(describe(r, notesChars: 100_000)) } else { missing.append(id) }
            }
            return ["reminders": found, "not_found": missing]
        },

        Tool(name: "reminders_stats",
             description: "Per-list health: open, overdue, undated, high priority, duplicate open titles and the oldest open item. Use it to plan a tidy-up.",
             properties: ["list": prop("string", "List title or id. Omit for every list.")]) { a in
            let cals = try a.str("list").map { [try rem.list($0)] }
            let open = rem.fetch(cals, status: .open)
            let now = Date()
            var rows: [String: [String: Any]] = [:]
            var keys: [String: [String: Int]] = [:]
            for r in open {
                let k = r.calendar.calendarIdentifier
                var row = rows[k] ?? ["list": r.calendar.title, "list_id": k, "open": 0, "overdue": 0, "undated": 0, "high_priority": 0]
                row["open"] = (row["open"] as! Int) + 1
                if When.isOverdue(r, now: now) { row["overdue"] = (row["overdue"] as! Int) + 1 }
                if r.dueDateComponents == nil { row["undated"] = (row["undated"] as! Int) + 1 }
                if Priority.name(r.priority) == "high" { row["high_priority"] = (row["high_priority"] as! Int) + 1 }
                if let c = r.creationDate {
                    let old = (row["oldest_open"] as? String) ?? "9999"
                    let s = When.day.string(from: c)
                    if s < old { row["oldest_open"] = s }
                }
                rows[k] = row
                keys[k, default: [:]][normalise(r.title ?? ""), default: 0] += 1
            }
            for (k, counts) in keys { rows[k]?["duplicate_titles"] = counts.filter { !$0.key.isEmpty && $0.value > 1 }.count }
            let sorted = rows.values.sorted { ($0["open"] as! Int) > ($1["open"] as! Int) }
            let total = { (f: String) in sorted.reduce(0) { $0 + ($1[f] as! Int) } }
            return ["lists": sorted, "totals": ["open": total("open"), "overdue": total("overdue"),
                                                "undated": total("undated"), "high_priority": total("high_priority")]]
        },

        Tool(name: "reminders_find_duplicates",
             description: """
                Groups of open reminders with the same or near-same titles (case, spacing, punctuation and emoji ignored; \
                'fuzzy' also catches small typos), within one list or across all, so they can be merged.
                """,
             properties: [
                "list": prop("string", "Only this list (title or id). Omit to search across every list."),
                "fuzzy": prop("boolean", "Also group titles that differ by a small typo (about 1 edit per 8 letters). Default false."),
                "include_completed": prop("boolean", "Also match against completed reminders. Default false."),
                "limit": prop("integer", "Max groups. Default 100."),
             ]) { a in
            let cals = try a.str("list").map { [try rem.list($0)] }
            let rs = rem.fetch(cals, status: try a.bool("include_completed") == true ? .all : .open)
            let groups = duplicateGroups(rs, fuzzy: try a.bool("fuzzy") ?? false)
            let limit = max(try a.int("limit") ?? 100, 1)
            return ["groups": groups.prefix(limit).map { g -> [String: Any] in
                        let items = g.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                        return ["count": g.count, "lists": Array(Set(g.map { $0.calendar.title })).sorted(),
                                "reminders": items.map { r -> [String: Any] in
                                    var d: [String: Any] = ["id": r.calendarItemIdentifier, "title": r.title ?? "",
                                                            "list": r.calendar.title, "completed": r.isCompleted,
                                                            "due": jv(When.dueString(r))]
                                    if let c = r.creationDate { d["created"] = When.day.string(from: c) }
                                    if let n = r.notes, !n.isEmpty { d["has_notes"] = true }
                                    return d
                                }]
                    },
                    "group_count": groups.count, "reminders_in_groups": groups.reduce(0) { $0 + $1.count }]
        },
    ]

    guard cfg.writes else { return tools }   // read-only mode doesn't even list the write tools

    tools += [
        Tool(name: "reminders_create",
             description: "Create a reminder. Omit 'list' for the default list.",
             properties: fieldProps.merging(["list": prop("string", "List title or id."), "dry_run": dryRunProp]) { a, _ in a },
             required: ["title"], write: true) { a in
            var op = a.d; op["op"] = "create"
            return try write("reminders_create", a, op)
        },
        Tool(name: "reminders_update",
             description: "Change any field of a reminder by id. Only the fields you pass change.",
             properties: fieldProps.merging(["id": prop("string", "Reminder id."),
                                             "list": prop("string", "Move to this list (title or id)."),
                                             "completed": prop("boolean", "Tick or untick."),
                                             "dry_run": dryRunProp]) { a, _ in a },
             required: ["id"], write: true) { a in
            var op = a.d; op["op"] = "update"
            return try write("reminders_update", a, op)
        },
        Tool(name: "reminders_move",
             description: "Move a reminder to another list. The same reminder moves; it is not re-created.",
             properties: ["id": prop("string", "Reminder id."), "to_list": prop("string", "Destination list title or id."),
                          "dry_run": dryRunProp],
             required: ["id", "to_list"], write: true) { a in
            try write("reminders_move", a, ["op": "move", "id": a.d["id"] ?? NSNull(), "to_list": a.d["to_list"] ?? NSNull()])
        },
        Tool(name: "reminders_complete",
             description: "Tick a reminder done. For a repeating reminder this advances it to the next occurrence.",
             properties: ["id": prop("string", "Reminder id."), "dry_run": dryRunProp],
             required: ["id"], write: true) { a in
            try write("reminders_complete", a, ["op": "complete", "id": a.d["id"] ?? NSNull()])
        },
        Tool(name: "reminders_uncomplete",
             description: "Untick a completed reminder.",
             properties: ["id": prop("string", "Reminder id."), "dry_run": dryRunProp],
             required: ["id"], write: true) { a in
            try write("reminders_uncomplete", a, ["op": "uncomplete", "id": a.d["id"] ?? NSNull()])
        },
        Tool(name: "reminders_delete",
             description: "DESTRUCTIVE: permanently delete a reminder (a repeating one loses its whole series). Needs confirm: true. Prefer complete.",
             properties: ["id": prop("string", "Reminder id."), "confirm": prop("boolean", "Must be true."), "dry_run": dryRunProp],
             required: ["id", "confirm"], write: true, destructive: true) { a in
            try write("reminders_delete", a, ["op": "delete", "id": a.d["id"] ?? NSNull(), "confirm": a.d["confirm"] ?? NSNull()],
                      destructive: true)
        },
        Tool(name: "reminders_batch",
             description: """
                Apply many changes in one call. DRY RUN BY DEFAULT: returns the plan (per operation: what changes, \
                from → to) and writes nothing until you pass dry_run: false. All-or-nothing: if any operation is \
                invalid, nothing is applied. Each op is {"op": "create"|"update"|"move"|"complete"|"uncomplete"|"delete", ...} \
                with the same fields as the single tools (move takes 'to_list'). One operation per reminder; \
                deletes are refused unless allow_destructive is true and the op has confirm: true.
                """,
             properties: [
                "operations": ["type": "array", "items": ["type": "object"], "description": "Up to 500 operations."],
                "dry_run": prop("boolean", "Default TRUE: plan only. Pass false to apply."),
                "allow_destructive": prop("boolean", "Allow delete ops. Default false."),
             ],
             required: ["operations"], write: true, destructive: true) { a in
            guard let ops = a.d["operations"] as? [Any] else { throw ToolError("'operations' must be a list.") }
            return try engine.run(ops, dryRun: try a.bool("dry_run") ?? true,
                                  allowDestructive: try a.bool("allow_destructive") ?? false, tool: "reminders_batch")
        },
        Tool(name: "reminders_create_list",
             description: "Create a new list in the default account.",
             properties: ["title": prop("string", "List name.")],
             required: ["title"], write: true) { a in
            let title = try a.req("title")
            if let allow = cfg.writableLists, !allow.contains(title) {
                throw ToolError("'\(title)' is not in REMINDERS_MCP_WRITABLE_LISTS, so it can't be created.")
            }
            if rem.lists.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                throw ToolError("A list called '\(title)' already exists.")
            }
            guard let source = rem.defaultList?.source else { throw ToolError("No default Reminders account.") }
            let c = EKCalendar(for: .reminder, eventStore: rem.ek)
            c.title = title
            c.source = source
            try rem.ek.saveCalendar(c, commit: true)
            let entry: [String: Any] = ["op": "create_list", "id": c.calendarIdentifier, "title": title, "account": source.title]
            var out: [String: Any] = ["created": entry]
            if let w = Audit.write(cfg.auditPath, tool: "reminders_create_list", entries: [entry]) { out["audit_warning"] = w }
            return out
        },
        Tool(name: "reminders_rename_list",
             description: "Rename a list. Its reminders and id stay the same.",
             properties: ["list": prop("string", "List title or id."), "new_title": prop("string", "New name.")],
             required: ["list", "new_title"], write: true) { a in
            let c = try rem.list(try a.req("list"))
            try engine.checkWritable(c)
            let new = try a.req("new_title")
            if let allow = cfg.writableLists, !allow.contains(new) {
                throw ToolError("'\(new)' is not in REMINDERS_MCP_WRITABLE_LISTS, so a list can't be renamed to it.")
            }
            if rem.lists.contains(where: { $0.calendarIdentifier != c.calendarIdentifier && $0.title.caseInsensitiveCompare(new) == .orderedSame }) {
                throw ToolError("A list called '\(new)' already exists.")
            }
            let old = c.title
            c.title = new
            try rem.ek.saveCalendar(c, commit: true)
            let entry: [String: Any] = ["op": "rename_list", "id": c.calendarIdentifier, "changes": ["title": ["from": old, "to": new]]]
            var out: [String: Any] = ["renamed": entry]
            if let w = Audit.write(cfg.auditPath, tool: "reminders_rename_list", entries: [entry]) { out["audit_warning"] = w }
            return out
        },
        Tool(name: "reminders_delete_list",
             description: "DESTRUCTIVE: delete a list. Refuses a list that still has reminders (open or completed) unless force is true. Needs confirm: true.",
             properties: ["list": prop("string", "List title or id."), "confirm": prop("boolean", "Must be true."),
                          "force": prop("boolean", "Also delete the reminders in it. Default false.")],
             required: ["list", "confirm"], write: true, destructive: true) { a in
            let c = try rem.list(try a.req("list"))
            try engine.checkWritable(c)
            guard try a.bool("confirm") == true else { throw ToolError("Deleting a list needs 'confirm': true.") }
            let inside = rem.fetch([c], status: .all).count
            if inside > 0, try a.bool("force") != true {
                throw ToolError("'\(c.title)' still holds \(inside) reminder(s). Move them first, or pass force: true to delete them with it.")
            }
            let entry: [String: Any] = ["op": "delete_list", "id": c.calendarIdentifier, "title": c.title, "reminders_deleted": inside]
            try rem.ek.removeCalendar(c, commit: true)
            var out: [String: Any] = ["deleted": entry]
            if let w = Audit.write(cfg.auditPath, tool: "reminders_delete_list", entries: [entry]) { out["audit_warning"] = w }
            return out
        },
    ]
    return tools
}

private func query(_ rem: Reminders, _ a: Args, text: String?) throws -> [String: Any] {
    let cals = try a.str("list").map { [try rem.list($0)] }
    guard let status = Status(rawValue: (try a.str("status") ?? "open").lowercased()) else {
        throw ToolError("'status' must be open, completed or all.")
    }
    var rs = rem.fetch(cals, status: status)
    let now = Date()
    if let t = text, !t.isEmpty {
        rs = rs.filter { ($0.title ?? "").localizedCaseInsensitiveContains(t) || ($0.notes ?? "").localizedCaseInsensitiveContains(t) }
    }
    if try a.bool("overdue") == true { rs = rs.filter { When.isOverdue($0, now: now) } }
    if let u = try a.bool("undated") { rs = rs.filter { ($0.dueDateComponents == nil) == u } }
    if let s = try a.str("due_before") { let b = try When.bound(s); rs = rs.filter { When.due($0).map { $0.date < b } ?? false } }
    if let s = try a.str("due_after") { let b = try When.bound(s); rs = rs.filter { When.due($0).map { $0.date >= b } ?? false } }
    if let p = try a.str("priority") {
        let want = Priority.name(try Priority.value(p))
        rs = rs.filter { Priority.name($0.priority) == want }
    }
    let keyed = rs.map { (r: $0, due: When.due($0)?.date) }.sorted { x, y in
        switch (x.due, y.due) {
        case let (a?, b?) where a != b: return a < b
        case (nil, _?): return false
        case (_?, nil): return true
        default: return (x.r.title ?? "").localizedCaseInsensitiveCompare(y.r.title ?? "") == .orderedAscending
        }
    }
    let limit = min(max(try a.int("limit") ?? 100, 1), 1000), offset = max(try a.int("offset") ?? 0, 0)
    let page = keyed.dropFirst(offset).prefix(limit).map { describe($0.r) }
    var out: [String: Any] = ["total": keyed.count, "returned": page.count, "reminders": Array(page)]
    if offset + page.count < keyed.count { out["next_offset"] = offset + page.count }
    return out
}

// MARK: - Duplicates

/// Lowercase letters and digits only, words single-spaced: "Call the GP!! 📞" → "call the gp".
func normalise(_ s: String) -> String {
    let kept = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
}

private func editDistance(_ a: [Character], _ b: [Character], max: Int) -> Int {
    if abs(a.count - b.count) > max { return max + 1 }
    var prev = Array(0...b.count), cur = prev
    for i in 1...a.count {
        cur[0] = i
        var best = cur[0]
        for j in 1...b.count {
            cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            best = Swift.min(best, cur[j])
        }
        if best > max { return max + 1 }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

/// Exact-after-normalising groups, then (if fuzzy) merges groups whose keys are a few edits apart.
func duplicateGroups(_ rs: [EKReminder], fuzzy: Bool) -> [[EKReminder]] {
    var byKey: [String: [EKReminder]] = [:]
    for r in rs {
        let k = normalise(r.title ?? "")
        if !k.isEmpty { byKey[k, default: []].append(r) }
    }
    var keys = byKey.keys.sorted()
    var groups: [[EKReminder]] = []
    if fuzzy {
        // Union keys that are within ~1 edit per 8 characters (and at least 6 characters long, so "gym"/"gp" stay apart).
        let chars = keys.map { Array($0) }
        var parent = Array(0..<keys.count)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in 0..<keys.count where chars[i].count >= 6 {
            for j in (i + 1)..<keys.count where chars[j].count >= 6 {
                let allowed = Swift.max(1, Swift.min(chars[i].count, chars[j].count) / 8)
                if editDistance(chars[i], chars[j], max: allowed) <= allowed { parent[root(j)] = root(i) }
            }
        }
        var merged: [Int: [EKReminder]] = [:]
        for (i, k) in keys.enumerated() { merged[root(i), default: []] += byKey[k]! }
        groups = Array(merged.values)
    } else {
        groups = keys.map { byKey[$0]! }
    }
    keys.removeAll()
    return groups.filter { $0.count > 1 }.sorted {
        $0.count != $1.count ? $0.count > $1.count : normalise($0[0].title ?? "") < normalise($1[0].title ?? "")
    }
}
