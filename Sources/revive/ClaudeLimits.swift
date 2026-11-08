import Foundation

/// Optional: Claude Code plan limits (5-hour and weekly % used) on the phone.
///
/// Claude Code doesn't save its limits to disk, but it passes them (`rate_limits`) to the status-line
/// command it runs after each reply. Turning this on points that command at a small script that saves
/// its input to ~/.revive/claude-limits.json, which Agents reads. A status line you already had keeps
/// running (its output is still shown), and turning this off puts your previous setting back.
enum ClaudeLimits {
    static let script = Config.file("claude-statusline.sh")
    private static let previousFile = Config.file("claude-statusline.previous.json")
    private static let settingsFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")

    static var isOn: Bool { (statusLine()?["command"] as? String) == script.path }

    static func enable() throws {
        guard !isOn else { return }
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        var settings = try readSettings()
        let previous = settings["statusLine"] as? [String: Any]
        // Remember what was there, so turning this off restores it exactly.
        try JSONSerialization.data(withJSONObject: previous ?? [:]).write(to: previousFile)
        try writeScript(chaining: previous?["command"] as? String)
        // One backup of the settings file before Revive first changes it.
        let backup = settingsFile.appendingPathExtension("revive-backup")
        if FileManager.default.fileExists(atPath: settingsFile.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: settingsFile, to: backup)
        }
        var line: [String: Any] = previous ?? [:]
        line["type"] = "command"
        line["command"] = script.path
        settings["statusLine"] = line
        try writeSettings(settings)
    }

    static func disable() throws {
        guard isOn else { return }
        var settings = try readSettings()
        if let data = try? Data(contentsOf: previousFile),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !previous.isEmpty {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: Config.file("claude-limits.json"))
    }

    private static func statusLine() -> [String: Any]? { (try? readSettings())?["statusLine"] as? [String: Any] }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "revive.claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object"])
        }
        return obj
    }

    private static func writeSettings(_ s: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    private static func writeScript(chaining previous: String?) throws {
        var sh = """
        #!/bin/sh
        # Revive: Claude Code runs this for its status line. It saves the input, which includes your plan
        # limits ("rate_limits"), so the Revive deck on your phone can show them. Nothing leaves this Mac.
        input=$(cat)
        dir="$HOME/.revive"
        printf '%s' "$input" > "$dir/claude-limits.json.tmp" && mv "$dir/claude-limits.json.tmp" "$dir/claude-limits.json"

        """
        if let previous, !previous.isEmpty {
            sh += "# Your previous status line, which still shows:\nprintf '%s' \"$input\" | {\n\(previous)\n}\n"
        }
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try sh.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
}
