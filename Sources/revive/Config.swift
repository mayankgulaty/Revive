import Foundation

/// Where Revive keeps its settings: ~/.revive (token, keys, world clocks, icon cache, HTTPS certificates).
enum Config {
    static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".revive")
    static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Revive started as a fork of OldPhoneDeck, which used ~/.oldphonedeck. Move that folder once, keeping the
    /// access token and the HTTPS certificate authority, so paired phones and their bookmarks keep working.
    static func migrate() {
        let fm = FileManager.default
        let old = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) else { return }
        do {
            try fm.moveItem(at: old, to: dir)
            print("Moved your settings from ~/.oldphonedeck to ~/.revive")
        } catch {
            print("⚠️  Could not move ~/.oldphonedeck to ~/.revive: \(error.localizedDescription)")
        }
    }
}
