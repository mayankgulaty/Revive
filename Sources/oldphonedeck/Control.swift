import AppKit

/// Synthetic key presses (used to press Return in Claude). Requires Accessibility permission.
enum Input {
    static func key(_ name: String) {
        let codes: [String: CGKeyCode] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53]
        guard let code = codes[name] else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}

/// Renders key icons as 114 px PNGs (57 pt @2x, the size an old iPhone's key shows them at).
enum Icons {
    static let size = 114

    /// Call on the main thread (AppKit drawing).
    static func png(size: Int = Icons.size, _ draw: (NSRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Finder's icon for an app or folder. Call on the main thread.
    static func file(_ path: String) -> Data? {
        // Resolve symlinks (e.g. /Applications/Safari.app) so the icon has no alias-arrow badge.
        let img = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        return png { img.draw(in: $0) }
    }
}

/// The app launcher: lists installed apps, renders their icons, and opens them.
enum Apps {
    private static let lock = NSLock()
    private static var iconCache: [String: Data] = [:]
    private static var listCache: (at: Date, apps: [[String: String]])?

    /// Cached for 30 s: the editor asks for ~100 icons at once and each request checks the path against this list.
    static func list() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        if let c = listCache, Date().timeIntervalSince(c.at) < 30 { return c.apps }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var out: [[String: String]] = []
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard seen.insert(name).inserted else { continue }
                out.append(["name": name, "path": dir + "/" + item])
            }
        }
        out.sort { $0["name"]!.localizedCaseInsensitiveCompare($1["name"]!) == .orderedAscending }
        listCache = (Date(), out)
        return out
    }

    /// Only paths that appear in our own listing may be launched or rendered.
    static func isKnown(_ path: String) -> Bool { list().contains { $0["path"] == path } }

    /// Call on the main thread.
    static func icon(_ path: String) -> Data? {
        lock.lock(); if let d = iconCache[path] { lock.unlock(); return d }; lock.unlock()
        guard let png = Icons.file(path) else { return nil }
        lock.lock(); iconCache[path] = png; lock.unlock()
        return png
    }

    static func launch(_ path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, err in
            if let err { print("Launch failed for \(path): \(err.localizedDescription)") }
        }
    }
}

/// Folder keys open a folder in Finder.
enum Folders {
    /// An existing folder (not an app or other package, which Finder would launch), with ~ expanded.
    static func resolve(_ path: String) -> String? {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              v.isDirectory == true, v.isPackage != true else { return nil }
        return url.path
    }

    /// Common folders offered in the key editor. Only folders whose own metadata can be read without
    /// a privacy prompt (looking inside Documents or Desktop would ask for permission).
    static func suggestions() -> [[String: String]] {
        let home = NSHomeDirectory()
        let candidates = [("Home", home), ("Desktop", home + "/Desktop"), ("Documents", home + "/Documents"),
                          ("Downloads", home + "/Downloads"), ("Developer", home + "/Developer"),
                          ("Projects", home + "/Projects"), ("Applications", "/Applications")]
        return candidates.compactMap { name, path in
            resolve(path).map { ["name": name, "path": $0] }
        }
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

/// The deck's keys, in order. Each is ["type": "app", "path"], ["type": "link", "url", "name"]
/// or ["type": "folder", "path", "name"]. Stored on the Mac so Safari and the Home Screen
/// web app (which have separate storage on iOS) see the same keys.
enum Launcher {
    static let maxKeys = 7
    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/launcher.json")

    /// nil = never configured (the phone shows empty keys and suggests editing).
    static func selected() -> [[String: String]]? {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return raw.compactMap { item in
            if let path = item as? String { return ["type": "app", "path": path] }   // older launcher.json: app paths only
            return item as? [String: String]
        }
    }

    @discardableResult
    static func save(_ keys: [[String: String]]) throws -> Int {
        let clean = Array(keys.compactMap(validate).prefix(maxKeys))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clean, options: .prettyPrinted).write(to: file)
        return clean.count
    }

    /// A cleaned-up key, or nil if it can't be opened (unknown app, non-web URL, missing folder).
    static func validate(_ key: [String: String]) -> [String: String]? {
        func label(_ fallback: String) -> String {
            let n = (key["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return String((n.isEmpty ? fallback : n).prefix(40))
        }
        switch key["type"] ?? "app" {
        case "app":
            guard let path = key["path"], Apps.isKnown(path) else { return nil }
            return ["type": "app", "path": path]
        case "link":
            guard let url = Links.web(key["url"] ?? "") else { return nil }
            return ["type": "link", "url": url.absoluteString, "name": label(Links.displayHost(url))]
        case "folder":
            guard let dir = Folders.resolve(key["path"] ?? "") else { return nil }
            return ["type": "folder", "path": dir, "name": label((dir as NSString).lastPathComponent)]
        default:
            return nil
        }
    }

    /// Opens a key on the Mac. Returns false if the key isn't valid.
    static func open(_ key: [String: String]) -> Bool {
        guard let k = validate(key) else { return false }
        DispatchQueue.main.async {
            switch k["type"] {
            case "link": if let u = URL(string: k["url"]!) { NSWorkspace.shared.open(u) }
            case "folder": Folders.open(k["path"]!)
            default: Apps.launch(k["path"]!)
            }
        }
        return true
    }
}

/// Sends text to the Claude desktop app using the same deep link its own macOS
/// Service uses: claude://claude.ai/new?q=<text>&surface=chat (found in app.asar).
enum Claude {
    static let bundleID = "com.anthropic.claudefordesktop"

    static func ask(_ text: String, autoSend: Bool) {
        var comps = URLComponents()
        comps.scheme = "claude"
        comps.host = "claude.ai"
        comps.path = "/new"
        comps.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "surface", value: "chat")]
        // URLComponents leaves "+" and "&"-adjacent chars ambiguous for some parsers; encode strictly.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        NSWorkspace.shared.open(url)
        guard autoSend else { return }
        // Wait for Claude to come to the front, then give the new chat time to load before pressing Return.
        // A cold launch takes several seconds; a fixed delay used to leave those notes unsent.
        pressReturnWhenReady(until: Date().addingTimeInterval(15), settle: wasRunning ? 1.8 : 4.5)
    }

    private static func pressReturnWhenReady(until deadline: Date, settle: TimeInterval) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                // Only if Claude is still in front: never type Return into another app.
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
                    return print("Claude lost focus; left the note unsent")
                }
                Input.key("return")
            }
            return
        }
        guard Date() < deadline else { return print("Claude did not come to the front; left the note unsent") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pressReturnWhenReady(until: deadline, settle: settle) }
    }

    static func focus() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
