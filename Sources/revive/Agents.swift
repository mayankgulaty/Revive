import AppKit
import SQLite3

/// Live activity and plan limits of the AI agents on this Mac (Claude Code, Cursor, Grok Bot),
/// read from the files each one keeps locally. Read-only: Revive never changes them.
///
/// Each agent: ["id", "name", "running": Bool, "sessions": [...], "limits": [...], "note"?]
/// Each session: ["title", "detail", "state", "at": ms]. state: working | needs | done | idle
///   (needs = waiting for your answer, done = finished and not looked at yet).
/// Each limit: ["label", "percent", "resetsAt"? (ms), "plan"?, "asOf"? (ms)]
final class Agents {
    private let queue = DispatchQueue(label: "agents")
    private var latest: [[String: Any]] = []
    private var timer: DispatchSourceTimer?
    private let home = URL(fileURLWithPath: NSHomeDirectory())

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [[String: Any]] { queue.sync { latest } }

    private func refresh() {
        let hidden = hiddenIDs
        latest = Agents.catalog.compactMap { id, _ -> [String: Any]? in
            guard !hidden.contains(id) else { return nil }   // hidden agents aren't even read
            switch id {
            case "claude": return claudeCode()
            case "cursor": return cursor()
            default: return grokBot()
            }
        }
    }

    // MARK: Choosing which agents to show (saved on the Mac, so every phone and browser agrees)

    static let catalog = [("claude", "Claude Code"), ("cursor", "Cursor"), ("grok", "Grok Bot")]
    private let choiceFile = Config.file("agents.json")
    private var hiddenIDs: Set<String> {
        let d = Agents.json(choiceFile) as? [String: Any]
        return Set((d?["hidden"] as? [String]) ?? [])
    }

    /// Every agent Revive knows, whether it's on this Mac, and whether it's shown.
    func choices() -> [[String: Any]] {
        let hidden = hiddenIDs
        return Agents.catalog.map { id, name in
            ["id": id, "name": name, "installed": installed(id), "shown": !hidden.contains(id)]
        }
    }

    func setHidden(_ ids: [String]) throws {
        let known = Set(Agents.catalog.map { $0.0 })
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hidden": ids.filter { known.contains($0) }]).write(to: choiceFile)
        queue.async { self.refresh() }
    }

    private func installed(_ id: String) -> Bool {
        switch id {
        case "claude": return FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
        case "cursor": return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
        default: return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") != nil
        }
    }

    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
    private static func alive(_ pid: Int) -> Bool { pid > 0 && kill(pid_t(pid), 0) == 0 }
    private static func json(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    private static func running(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Claude Code

    /// Each running session writes ~/.claude/sessions/<pid>.json with status busy/idle, its folder and name.
    /// Plan limits come from ClaudeUsage (optional, off until turned on in the menu bar).
    private func claudeCode() -> [String: Any]? {
        let root = home.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let dir = root.appendingPathComponent("sessions")
        let now = Agents.nowMs()
        var sessions: [[String: Any]] = []
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let d = Agents.json(f) as? [String: Any], let pid = d["pid"] as? Int, Agents.alive(pid) else { continue }
            let status = (d["status"] as? String ?? "").lowercased()
            let at = (d["statusUpdatedAt"] as? Double) ?? (d["updatedAt"] as? Double) ?? now
            let state: String
            if ["busy", "running", "working", "thinking"].contains(status) { state = "working" }
            else if status.contains("wait") || status.contains("permission") || status.contains("input") || status.contains("approval") { state = "needs" }
            else if status == "idle" && now - at < 15 * 60_000 { state = "done" }   // just finished: your turn
            else { state = "idle" }
            let project = ((d["cwd"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
            let surface = (d["entrypoint"] as? String ?? "").contains("vscode") ? "IDE" : "terminal"
            sessions.append(["title": (d["name"] as? String) ?? project, "detail": project.isEmpty ? surface : "\(project) · \(surface)",
                             "state": state, "at": at])
        }
        let usage = ClaudeUsage.shared.current()
        var agent: [String: Any] = ["id": "claude", "name": "Claude Code", "running": !sessions.isEmpty,
                                    "sessions": Agents.sorted(sessions), "limits": usage.limits]
        if let note = usage.note { agent["note"] = note }
        return agent
    }

    // MARK: Cursor

    /// Cursor keeps its agent chats in a SQLite database ("composerData:<id>" rows). Opened read-only.
    /// Its plan usage lives on Cursor's servers only.
    private func cursor() -> [String: Any]? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil else { return nil }
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        var sessions: [[String: Any]] = []
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 300)
            let sql = """
            SELECT json_extract(value,'$.name'), json_extract(value,'$.status'), json_extract(value,'$.lastUpdatedAt'),
                   json_extract(value,'$.hasUnreadMessages'), json_array_length(json_extract(value,'$.generatingBubbleIds')),
                   json_extract(value,'$.workspaceIdentifier.uri.fsPath')
            FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;' AND json_valid(value)
              AND json_extract(value,'$.lastUpdatedAt') > ?1
            ORDER BY 3 DESC LIMIT 6
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let now = Agents.nowMs()
                sqlite3_bind_double(stmt, 1, now - 12 * 3_600_000)
                func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let status = text(1).lowercased(), at = sqlite3_column_double(stmt, 2)
                    let generating = sqlite3_column_int(stmt, 4) > 0, unread = sqlite3_column_int(stmt, 3) != 0
                    let state = generating || ["generating", "running", "streaming", "loading"].contains(status) ? "working"
                        : unread ? "done" : "idle"
                    let project = text(5).split(separator: "/").last.map(String.init) ?? ""
                    let name = text(0)
                    sessions.append(["title": name.isEmpty ? "Untitled chat" : name, "detail": project, "state": state, "at": at])
                }
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
        return ["id": "cursor", "name": "Cursor", "running": Agents.running("com.todesktop.230313mzl4w4u92"),
                "sessions": Agents.sorted(sessions), "limits": [], "note": "Plan usage is only on cursor.com"]
    }

    // MARK: Grok Bot

    /// Grok Bot (Electron) persists its state as JSON blobs named by base32 keys such as
    /// "sand.client.slice.account.<id>.roster.last-roster" and "….weekly-usage.cache".
    private func grokBot() -> [String: Any]? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") != nil else { return nil }
        let dir = home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
        var blobs: [String: URL] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "blob" {
            if let key = Agents.base32(f.deletingPathExtension().lastPathComponent) { blobs[key] = f }
        }
        func blob(endingWith suffix: String) -> [String: Any]? {
            blobs.first { $0.key.hasSuffix(suffix) }.flatMap { Agents.json($0.value) as? [String: Any] }?["value"] as? [String: Any]
        }
        let now = Agents.nowMs()
        var sessions: [[String: Any]] = []
        for row in (blob(endingWith: ".roster.last-roster")?["rows"] as? [[String: Any]]) ?? [] {
            let at = Agents.number(row["lastActivityAt"]) ?? 0
            guard now - at < 24 * 3_600_000, row["isRemovedFromSidebar"] as? Bool != true else { continue }
            let state = row["awaitingUserResponse"].map { !($0 is NSNull) } == true ? "needs"
                : (row["hasUnread"] as? Bool == true) ? "done"
                : now - at < 3 * 60_000 ? "working" : "idle"
            let last = ((row["lastEntry"] as? [String: Any])?["text"] as? String) ?? (row["description"] as? String) ?? ""
            sessions.append(["title": row["name"] as? String ?? "Agent", "detail": String(last.prefix(80)), "state": state, "at": at])
        }
        for entry in (blob(endingWith: ".cloud-agents.infos")?["entries"] as? [[String: Any]]) ?? [] {
            guard let info = entry["info"] as? [String: Any], let status = (info["status"] as? String)?.lowercased(),
                  !["finished", "failed", "error", "cancelled", "expired"].contains(status) else { continue }
            let lines = "+\(Agents.number(info["linesAdded"]).map { Int($0) } ?? 0) −\(Agents.number(info["linesRemoved"]).map { Int($0) } ?? 0)"
            sessions.append(["title": info["name"] as? String ?? "Cloud agent", "detail": "cloud agent · \(lines)",
                             "state": "working", "at": Agents.number(info["lastActivityAtMs"]) ?? now])
        }
        var limits: [[String: Any]] = []
        if let reading = blob(endingWith: ".weekly-usage.cache")?["reading"] as? [String: Any],
           let usage = reading["usage"] as? [String: Any], let pct = Agents.number(usage["percentUsed"]) {
            var l: [String: Any] = ["label": "Weekly", "percent": pct]
            if let r = Agents.number(usage["nextResetMs"]) { l["resetsAt"] = r }
            if let plan = usage["grokPlanLabel"] as? String ?? usage["unifiedPlanName"] as? String { l["plan"] = plan }
            if let asOf = Agents.number(reading["readAtMs"]) { l["asOf"] = asOf }
            limits.append(l)
        }
        return ["id": "grok", "name": "Grok Bot", "running": Agents.running("com.anysphere.sand"),
                "sessions": Agents.sorted(sessions).prefix(6).map { $0 }, "limits": limits]
    }

    // MARK: Helpers

    /// Needs-you first, then working, done, idle; newest first within each.
    private static func sorted(_ s: [[String: Any]]) -> [[String: Any]] {
        let rank = ["needs": 0, "working": 1, "done": 2, "idle": 3]
        return s.sorted {
            let a = rank[$0["state"] as? String ?? ""] ?? 4, b = rank[$1["state"] as? String ?? ""] ?? 4
            return a != b ? a < b : (($0["at"] as? Double) ?? 0) > (($1["at"] as? Double) ?? 0)
        }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !(v is Bool) { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// A reset time as epoch ms, from seconds, milliseconds or an ISO 8601 string.
    private static func time(_ v: Any?) -> Double? {
        if let n = number(v) { return n < 10_000_000_000 ? n * 1000 : n }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d.timeIntervalSince1970 * 1000 }
        }
        return nil
    }

    private static func base32(_ s: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = [UInt8]()
        for c in s.uppercased() {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return String(bytes: out, encoding: .utf8)
    }
}
