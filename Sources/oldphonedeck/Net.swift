import Foundation
import SystemConfiguration

/// How the phone finds this Mac on the local network.
enum Net {
    /// The Mac's current IPv4 address on Wi-Fi/Ethernet (en0 preferred), or "localhost".
    static func lanAddress() -> String {
        var addr = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
            if name == "en0" { break }
        }
        return addr
    }

    /// The Bonjour name, e.g. "alexs-macbook-air.local". Unlike the IP address it survives a router
    /// handing out a new address, so the phone's Home Screen bookmark keeps working.
    static func bonjourHost() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name.lowercased() + ".local"
    }

    /// The Mac's display name ("Alex's MacBook Air"). Fast, unlike Host.current().localizedName.
    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}

/// The addresses a phone (or OBS) uses to reach the deck.
struct PairingLinks {
    let token: String
    let port: UInt16
    let ip: String
    let host: String?

    static func current(token: String, port: UInt16) -> PairingLinks {
        PairingLinks(token: token, port: port, ip: Net.lanAddress(), host: Net.bonjourHost())
    }

    /// Prefer the Bonjour name: it doesn't change when the router assigns a new IP.
    var name: String { host ?? ip }
    var deck: String { "http://\(name):\(port)/#k=\(token)" }
    var deckByIP: String { "http://\(ip):\(port)/#k=\(token)" }
    var secureDeck: String { "https://\(name):\(port + 2)/#k=\(token)" }
    var profile: String { "http://\(name):\(port)/oldphonedeck.mobileconfig" }
    var obsCamera: String { "http://localhost:\(port)/camera.mjpg?k=\(token)" }
}
