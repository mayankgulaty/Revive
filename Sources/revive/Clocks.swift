import Foundation

/// The world clocks shown on the idle clock screen (up to three), stored on the Mac.
/// Each is a time zone plus the city name to show, so "New Delhi" can use Asia/Kolkata.
enum WorldClocks {
    struct Clock: Equatable { let zone: String; let city: String }

    static let maxCount = 3
    private static let file = Config.file("clocks.json")
    private static let lock = NSLock()
    private static var cached: [Clock]?

    /// Well-known cities that aren't time-zone names (the tz database names one city per zone).
    private static let aliases: [String: [String]] = [
        "Asia/Kolkata": ["New Delhi", "Delhi", "Mumbai", "Bengaluru", "Bangalore", "Chennai", "Hyderabad", "Pune", "Ahmedabad", "Gurugram", "Noida"],
        "America/Los_Angeles": ["San Francisco", "Seattle", "San Jose", "San Diego", "Las Vegas", "Portland"],
        "America/New_York": ["Boston", "Washington, D.C.", "Miami", "Atlanta", "Philadelphia"],
        "America/Chicago": ["Dallas", "Austin", "Houston", "Minneapolis"],
        "America/Toronto": ["Montreal", "Ottawa"],
        "America/Sao_Paulo": ["Rio de Janeiro"],
        "Europe/London": ["Manchester", "Edinburgh"],
        "Europe/Berlin": ["Munich", "Frankfurt", "Hamburg"],
        "Europe/Zurich": ["Geneva"],
        "Europe/Madrid": ["Barcelona"],
        "Europe/Rome": ["Milan"],
        "Asia/Shanghai": ["Beijing", "Shenzhen", "Hangzhou", "Guangzhou"],
        "Asia/Tokyo": ["Osaka", "Kyoto"],
        "Asia/Dubai": ["Abu Dhabi"],
        "Asia/Qatar": ["Doha"],
        "Asia/Karachi": ["Islamabad", "Lahore"],
        "Asia/Bangkok": ["Hanoi"],
        "Australia/Sydney": ["Canberra"],
    ]

    static func selected() -> [Clock] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var clocks: [Clock]
        if let data = try? Data(contentsOf: file), let saved = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            clocks = saved.compactMap { item in
                if let zone = item as? String { return Clock(zone: zone, city: city(zone)) }   // older format: zone ids only
                guard let d = item as? [String: String], let zone = d["zone"] else { return nil }
                return Clock(zone: zone, city: d["city"] ?? city(zone))
            }
        } else {
            clocks = ["America/New_York", "Europe/London", "Asia/Tokyo"]
                .filter { $0 != TimeZone.current.identifier }.map { Clock(zone: $0, city: city($0)) }
        }
        cached = clocks
        return clocks
    }

    /// `entries` are "zone|city" strings from the phone.
    @discardableResult
    static func save(_ entries: [String]) throws -> [Clock] {
        var clean: [Clock] = []
        for e in entries {
            let parts = e.split(separator: "|", maxSplits: 1).map(String.init)
            guard let zone = parts.first, TimeZone(identifier: zone) != nil, clean.count < maxCount else { continue }
            let name = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespaces)
            let c = Clock(zone: zone, city: String((name.isEmpty ? city(zone) : name).prefix(40)))
            if !clean.contains(c) { clean.append(c) }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: clean.map { ["zone": $0.zone, "city": $0.city] }).write(to: file)
        lock.lock(); cached = clean; lock.unlock()
        return clean
    }

    /// "America/Argentina/Buenos_Aires" → "Buenos Aires".
    static func city(_ id: String) -> String {
        id == "UTC" ? "UTC" : (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// Time zone → country name, from the tz database's zone.tab ("IN  +2232+08822  Asia/Kolkata").
    private static let countries: [String: String] = {
        guard let tab = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in tab.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            out[String(cols[2])] = Locale(identifier: "en_US").localizedString(forRegionCode: String(cols[0])) ?? String(cols[0])
        }
        return out
    }()

    /// Every city for the picker: one per time zone plus the aliases, with country names to search by.
    static func all() -> [[String: Any]] {
        let now = Date()
        var out: [[String: Any]] = []
        // zone.tab has one current name per zone. Foundation's list mixes in old names and misses some
        // current ones (it has Asia/Calcutta but not Asia/Kolkata), so it's only a fallback.
        let canonical = countries.keys.sorted()
        let ids = ["UTC"] + (canonical.isEmpty ? TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") } : canonical)
        for id in ids {
            guard let tz = TimeZone(identifier: id) else { continue }
            let country = countries[id] ?? (id == "UTC" ? "" : id.split(separator: "/").first.map(String.init) ?? "")
            let offset = tz.secondsFromGMT(for: now)
            for name in [city(id)] + (aliases[id] ?? []) {
                out.append(["zone": id, "city": name, "country": country, "offset": offset])
            }
        }
        return out.sorted { ($0["city"] as! String).localizedCaseInsensitiveCompare($1["city"] as! String) == .orderedAscending }
    }

    /// What the phone needs to draw the clocks: the Mac's time (phones' clocks drift) and each zone's UTC offset.
    static func snapshot() -> [String: Any] {
        let now = Date()
        let clocks: [[String: Any]] = selected().compactMap { c in
            guard let tz = TimeZone(identifier: c.zone) else { return nil }
            return ["id": c.zone + "|" + c.city, "zone": c.zone, "city": c.city, "offset": tz.secondsFromGMT(for: now)]
        }
        return ["now": (now.timeIntervalSince1970 * 1000).rounded(), "offset": TimeZone.current.secondsFromGMT(for: now), "clocks": clocks]
    }

    /// The selection as "zone|city" keys, matching the picker's entries.
    static func selectedKeys() -> [String] { selected().map { $0.zone + "|" + $0.city } }
}
