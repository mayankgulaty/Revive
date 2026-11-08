import Foundation
import Security

/// Optional: Claude Code plan limits (5-hour and weekly % used, with reset times) for the Agents tab.
///
/// Claude Code's own /usage screen gets these from Anthropic (GET /api/oauth/usage), signed in with the
/// Claude login it keeps in the Keychain ("Claude Code-credentials"). When you turn this on, Revive does
/// the same every few minutes, on this Mac only:
///   • the login is read from your own Keychain at run time (macOS asks you the first time),
///   • it's only kept in memory and only sent to api.anthropic.com, never to the phone or anywhere else,
///   • nothing about it is stored in this project, so each person who installs Revive sees their own usage.
/// The endpoint isn't a published API, so if Anthropic changes it the Claude card shows a note instead.
final class ClaudeUsage {
    static let shared = ClaudeUsage()

    private let queue = DispatchQueue(label: "claude-usage")
    private let flag = Config.file("claude-usage-on")   // opt-in switch (no secrets in it)
    private var timer: DispatchSourceTimer?
    private var limits: [[String: Any]] = []
    private var problem: String?

    var isOn: Bool { FileManager.default.fileExists(atPath: flag.path) }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 300)   // every 5 minutes, like glancing at /usage
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func setOn(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
            queue.async { self.refresh() }
        } else {
            try? FileManager.default.removeItem(at: flag)
            queue.async { self.limits = []; self.problem = nil }
        }
    }

    /// For the Agents snapshot: (limits, note to show when there are none).
    func current() -> (limits: [[String: Any]], note: String?) {
        queue.sync {
            if !isOn { return ([], "Plan limits: turn on in the Revive menu bar") }
            return (limits, limits.isEmpty ? (problem ?? "Loading plan limits…") : nil)
        }
    }

    // MARK: Fetching (on `queue`)

    private func refresh() {
        guard isOn else { return }
        guard let token = Self.accessToken() else {
            problem = "Couldn't use your Claude login: use Claude Code once (it refreshes the login) and allow Revive in the Keychain prompt"
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Revive", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            defer { done.signal() }
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                if status == 401 || status == 403 {
                    self.problem = "Claude login expired: use Claude Code once to refresh it"
                } else if status != 200 || error != nil {
                    self.problem = "Couldn't load plan limits" + (status > 0 ? " (HTTP \(status))" : "")
                } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let parsed = Self.parse(obj)
                    self.limits = parsed
                    self.problem = parsed.isEmpty ? "Plan limits not available for this account" : nil
                }
            }
        }.resume()
        _ = done.wait(timeout: .now() + 20)
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

    /// Claude Code's login from this Mac's Keychain. The first read shows a macOS prompt
    /// ("Revive wants to use … Claude Code-credentials"); choose Always Allow.
    private static func accessToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires < Date().timeIntervalSince1970 * 1000 { return nil }
        return token
    }
}
