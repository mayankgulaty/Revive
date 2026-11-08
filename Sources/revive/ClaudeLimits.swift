import Foundation

/// Cleanup for an earlier approach: Revive used to point Claude Code's status line at a script that saved
/// its plan limits. Claude Code's IDE extension never runs the status line, so ClaudeUsage replaced it.
/// If that script is still set, `removeStatusLine()` puts back the status line you had before.
enum ClaudeLimits {
    private static let script = Config.file("claude-statusline.sh")
    private static let previousFile = Config.file("claude-statusline.previous.json")
    private static let settingsFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")

    static var isOn: Bool { (statusLine()?["command"] as? String) == script.path }

    static func removeStatusLine() throws {
        if isOn {
            var settings = try readSettings()
            if let data = try? Data(contentsOf: previousFile),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !previous.isEmpty {
                settings["statusLine"] = previous
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: settingsFile, options: .atomic)
        }
        for f in [script, previousFile, Config.file("claude-limits.json")] { try? FileManager.default.removeItem(at: f) }
    }

    private static func statusLine() -> [String: Any]? { (try? readSettings())?["statusLine"] as? [String: Any] }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any] else {
            throw NSError(domain: "revive.claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object"])
        }
        return obj
    }
}
