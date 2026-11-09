import Foundation

/// Optional: Claude Code plan limits (5-hour and weekly % used, with reset times) for the Agents tab.
///
/// Claude Code's own /usage screen gets these from Anthropic (GET /api/oauth/usage), signed in with the
/// Claude login it keeps in the Keychain ("Claude Code-credentials"). When you turn this on, Revive does
/// the same every few minutes, on this Mac only:
///   • the login is read from your own Keychain at run time, the same way Claude Code reads it,
///   • it's only kept in memory and only sent to api.anthropic.com, never to the phone or anywhere else,
///   • nothing about it is stored in this project, so each person who installs Revive sees their own usage.
/// The endpoint isn't a published API, so if Anthropic changes it the Claude card shows a note instead.
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    private let queue = DispatchQueue(label: "claude-usage")
    private let flag = Config.file("claude-usage-on")          // opt-in switch (no secrets in it)
    private let cache = Config.file("claude-usage-last.json")  // last percentages, so a restart isn't blank (no secrets)
    private var limits: [[String: Any]] = []
    private var problem: String?
    private var nextCheck = Date.distantPast
    private var fetching = false

    var isOn: Bool { FileManager.default.fileExists(atPath: flag.path) }

    func start() {
        queue.async {
            if let data = try? Data(contentsOf: self.cache),
               let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { self.limits = saved }
            self.tick()
        }
    }

    /// Checks every 5 minutes; every minute while something is wrong, so it recovers soon after.
    private func tick() {
        if isOn && Date() >= nextCheck && !fetching { refresh() }
        queue.asyncAfter(deadline: .now() + 15) { self.tick() }
    }

    func setOn(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            queue.async { self.nextCheck = .distantPast; if !self.fetching { self.refresh() } }
        } else {
            try? FileManager.default.removeItem(at: flag)
            try? FileManager.default.removeItem(at: cache)
            queue.async { self.limits = []; self.problem = nil }
        }
    }

    /// For the Agents snapshot: the limits (the last good ones while a check fails), or a note when there are none.
    func current() -> (limits: [[String: Any]], note: String?) {
        queue.sync {
            if !isOn { return ([], "Plan limits: turn on in the Revive menu bar") }
            return (limits, limits.isEmpty ? (problem ?? "Loading plan limits…") : nil)
        }
    }

    // MARK: Fetching (on `queue`, never waiting on the network there: the phone's stats requests read from it)

    private func refresh() {
        guard isOn else { return }
        let login = Self.login()
        guard case .ok(let token) = login else {
            problem = login.message
            nextCheck = Date().addingTimeInterval(60)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Revive", forHTTPHeaderField: "User-Agent")
        fetching = true
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.fetching = false
                if status == 200, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let parsed = Self.parse(obj)
                    self.limits = parsed
                    self.problem = parsed.isEmpty ? "Plan limits not available for this account" : nil
                    self.nextCheck = Date().addingTimeInterval(300)
                    if let d = try? JSONSerialization.data(withJSONObject: parsed) { try? d.write(to: self.cache) }
                } else {
                    self.problem = status == 401 || status == 403
                        ? "Claude login needs a refresh: it renews the next time you use Claude Code"
                        : "Couldn't load plan limits" + (status > 0 ? " (HTTP \(status))" : error != nil ? " (offline?)" : "")
                    self.nextCheck = Date().addingTimeInterval(60)
                }
            }
        }.resume()
    }

    /// { "five_hour": { "utilization": 34.0, "resets_at": "2026-11-08T23:00:00Z" }, "seven_day": {…}, … }
    static func parse(_ obj: [String: Any]) -> [[String: Any]] {
        let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]
        let asOf = Date().timeIntervalSince1970 * 1000
        return windows.compactMap { key, label in
            guard let w = obj[key] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            var out: [String: Any] = ["label": label, "percent": u, "asOf": asOf]
            if let r = resetTime(w["resets_at"] ?? w["resetsAt"]) { out["resetsAt"] = r }
            return out
        }
    }

    private static func resetTime(_ v: Any?) -> Double? {
        if let n = (v as? NSNumber)?.doubleValue { return n < 10_000_000_000 ? n * 1000 : n }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (f.date(from: s) ?? ISO8601DateFormatter().date(from: s)).map { $0.timeIntervalSince1970 * 1000 }
    }

    // MARK: The login

    enum Login {
        case ok(String), missing, expired, unreadable(String)
        var message: String {
            switch self {
            case .ok: return ""
            case .missing: return "No Claude Code login on this Mac: sign in to Claude Code first"
            case .expired: return "Claude login needs a refresh: it renews the next time you use Claude Code"
            case .unreadable(let why): return "Couldn't read your Claude login (\(why))"
            }
        }
    }

    /// Claude Code's login, read exactly the way Claude Code reads it: with macOS's `security` tool.
    /// Claude Code writes the entry with that tool and re-creates it whenever the login refreshes, so the
    /// entry trusts `security` itself. (Reading it directly from Revive needed a Keychain approval, and every
    /// refresh, e.g. after a restart, threw that approval away.) The secret goes from the tool straight into memory.
    static func login() -> Login {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return .unreadable(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0: break
        case 44: return .missing   // errSecItemNotFound
        default: return .unreadable("Keychain error \(p.terminationStatus)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else {
            return .unreadable("unexpected format")
        }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms < Date().timeIntervalSince1970 * 1000 { return .expired }
        return .ok(token)
    }
}
