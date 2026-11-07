import Foundation

/// The world clocks shown on the idle clock screen (up to three cities), stored on the Mac.
enum WorldClocks {
    static let maxCount = 3
    private static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck/clocks.json")
    private static let lock = NSLock()
    private static var cached: [String]?

    static func selected() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var ids: [String]
        if let data = try? Data(contentsOf: file), let saved = try? JSONSerialization.jsonObject(with: data) as? [String] {
            ids = saved
        } else {
            ids = ["America/New_York", "Europe/London", "Asia/Tokyo"].filter { $0 != TimeZone.current.identifier }
        }
        cached = ids
        return ids
    }

    @discardableResult
    static func save(_ ids: [String]) throws -> [String] {
        var clean: [String] = []
        for id in ids where TimeZone(identifier: id) != nil && !clean.contains(id) && clean.count < maxCount { clean.append(id) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clean).write(to: file)
        lock.lock(); cached = clean; lock.unlock()
        return clean
    }

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires".
    static func city(_ id: String) -> String {
        id == "UTC" ? "UTC" : (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// Every city time zone, for the picker.
    static func all() -> [[String: Any]] {
        let ids = ["UTC"] + TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        let now = Date()
        return ids.compactMap { id in
            guard let tz = TimeZone(identifier: id) else { return nil }
            let region = id.split(separator: "/").first.map(String.init) ?? ""
            return ["id": id, "city": city(id), "region": id == "UTC" ? "" : region, "offset": tz.secondsFromGMT(for: now)]
        }.sorted { ($0["city"] as! String).localizedCaseInsensitiveCompare($1["city"] as! String) == .orderedAscending }
    }

    /// What the phone needs to draw the clocks: the Mac's time (phones' clocks drift) and each zone's UTC offset.
    static func snapshot() -> [String: Any] {
        let now = Date()
        let clocks: [[String: Any]] = selected().compactMap { id in
            guard let tz = TimeZone(identifier: id) else { return nil }
            return ["id": id, "city": city(id), "offset": tz.secondsFromGMT(for: now)]
        }
        return ["now": (now.timeIntervalSince1970 * 1000).rounded(), "offset": TimeZone.current.secondsFromGMT(for: now), "clocks": clocks]
    }
}
