import AppKit

/// Website keys: URL checks and icons. The icon is the site's own Home Screen icon
/// (apple-touch-icon) or favicon, fetched once by the Mac and cached in ~/.revive/icons.
enum Links {
    private static let cacheDir = Config.file("icons")
    private static let lock = NSLock()
    private static var memory: [String: Data] = [:]
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
        return URLSession(configuration: cfg)
    }()

    /// Only http(s) links: other schemes (file:, custom app links) could do more than open a page.
    /// "appstoreconnect.apple.com" becomes "https://appstoreconnect.apple.com".
    static func web(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// "www.github.com" → "github.com".
    static func displayHost(_ url: URL) -> String {
        let h = url.host ?? url.absoluteString
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Calls `done` on the main thread with a PNG: the site's icon, or a coloured letter tile.
    static func icon(for url: URL, done: @escaping (Data) -> Void) {
        let host = displayHost(url).lowercased()
        let file = cacheDir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
        lock.lock(); let hit = memory[host]; lock.unlock()
        if let hit { return DispatchQueue.main.async { done(hit) } }
        if let disk = try? Data(contentsOf: file) {
            lock.lock(); memory[host] = disk; lock.unlock()
            return DispatchQueue.main.async { done(disk) }
        }
        fetchImage(for: url) { image in
            DispatchQueue.main.async {
                let png = image.flatMap(tile) ?? letterTile(host) ?? Data()
                if image != nil {
                    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    try? png.write(to: file)
                }
                // A failed fetch (offline?) is only remembered until restart, so it can recover later.
                lock.lock(); memory[host] = png; lock.unlock()
                done(png)
            }
        }
    }

    // MARK: Finding the icon

    private static func fetchImage(for url: URL, done: @escaping (NSImage?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            let base = response?.url ?? url
            var candidates = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
                .map { iconLinks(in: $0, base: base) } ?? []
            for origin in Set([base, url].compactMap(originURL)) {
                candidates.append(origin.appendingPathComponent("apple-touch-icon.png"))
                candidates.append(origin.appendingPathComponent("favicon.ico"))
            }
            tryNext(candidates, done)
        }.resume()
    }

    private static func originURL(_ url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = url.scheme; c.host = url.host; c.port = url.port; c.path = "/"
        return c.url
    }

    private static func tryNext(_ urls: [URL], _ done: @escaping (NSImage?) -> Void) {
        guard let first = urls.first else { return done(nil) }
        session.dataTask(with: first) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok, let data, let img = NSImage(data: data), img.isValid, pixelSize(img) >= 16 { return done(img) }
            tryNext(Array(urls.dropFirst()), done)
        }.resume()
    }

    /// <link rel="apple-touch-icon"> first (big, square), then other icons, largest first.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        let tag = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive)
        let attr = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        let ns = html as NSString
        var found: [(score: Int, url: URL)] = []
        for m in tag.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
            let t = ns.substring(with: m.range)
            var attrs: [String: String] = [:]
            for a in attr.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
                let key = (t as NSString).substring(with: a.range(at: 1)).lowercased()
                for i in 2...4 where a.range(at: i).location != NSNotFound {
                    attrs[key] = (t as NSString).substring(with: a.range(at: i))
                }
            }
            let rel = (attrs["rel"] ?? "").lowercased()
            guard rel.contains("icon"), let href = attrs["href"], !href.lowercased().hasSuffix(".svg"),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL else { continue }
            let size = Int((attrs["sizes"] ?? "").lowercased().split(separator: "x").first ?? "") ?? 0
            let score = (rel.contains("apple-touch-icon") ? 1000 : 0) + (size > 0 ? size : 32)
            found.append((score, url))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    private static func pixelSize(_ img: NSImage) -> Int {
        max(img.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0, Int(img.size.width))
    }

    // MARK: Drawing (main thread)

    /// A rounded tile the same visual size as a macOS app icon. Big icons fill it;
    /// small favicons sit in the middle of a white tile.
    private static func tile(_ img: NSImage) -> Data? {
        Icons.png { rect in
            let box = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
            let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
            NSColor.white.setFill(); shape.fill()
            shape.addClip()
            let px = pixelSize(img)
            let inner = px >= 96 ? box : box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2)
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: inner)
        }
    }

    private static func letterTile(_ host: String) -> Data? {
        let hue = CGFloat(host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) / 360
        let letter = String(host.first ?? "?").uppercased()
        return Icons.png { rect in
            let box = rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1)
            let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
            NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                       ending: NSColor(hue: hue, saturation: 0.75, brightness: 0.7, alpha: 1))?.draw(in: shape, angle: -90)
            let font = NSFont.systemFont(ofSize: box.height * 0.52, weight: .bold)
            let s = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2))
        }
    }
}
