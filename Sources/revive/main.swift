import AppKit
import ApplicationServices

// MARK: Options

struct Options {
    var port: UInt16 = 8045                // http = port, https = port+2, secure WebSocket = port+3
    var micDevice = "BlackHole"            // output device that receives a modern iPhone's mic

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--mic-device": micDevice = it.next() ?? micDevice
            case "-h", "--help":
                print("""
                revive: turn an old iPhone into a Stream Deck-style control panel and desk clock for your Mac
                  --port N          HTTP port (default 8045; HTTPS uses N+2, WebSocket N+3)
                  --mic-device NAME audio device that receives the phone's mic (default BlackHole)
                """)
                exit(0)
            // macOS passes -NSDocumentRevisionsDebugMode etc. to apps launched from Xcode; ignore those.
            case _ where a.hasPrefix("-NS") || a.hasPrefix("-Apple"): _ = it.next()
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)
Config.migrate()   // before anything reads settings
let configDir = Config.dir

// MARK: Access token (anyone on the Wi-Fi could otherwise open apps on your Mac)

func loadToken() -> String {
    let file = configDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? t.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return t
}

let token = loadToken()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: Services

let server: HTTPServer
do { server = try HTTPServer(port: opts.port) } catch { fatal("Cannot listen on \(opts.port): \(error)") }

// Camera + mic from a modern iPhone (browser, over the secure WebSocket).
var cameraViewers: [ObjectIdentifier: HTTPConnection] = [:]   // touched only on server.queue
let phoneMedia = PhoneMediaServer(token: token, audio: AudioOut(deviceMatch: opts.micDevice))
phoneMedia.onFrame = { jpeg in
    server.queue.async { for v in cameraViewers.values { v.pushFrame(jpeg) } }
}

let stats = Stats()
stats.start()
let music = Music()
music.start()
let activity = PhoneActivity()

// MARK: Routes

/// The phone page: inside Revive.app it's in Contents/Resources/web; from `swift build`, in SwiftPM's resource bundle.
let webRoot: URL = {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
       FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
    return Bundle.module.url(forResource: "web", withExtension: nil)!
}()

/// A key from the request: type (app/link/folder) + path or url + name.
func keyParams(_ p: [String: String]) -> [String: String] {
    var k = ["type": p["type"] ?? "app"]
    for f in ["path", "url", "name"] { if let v = p[f] { k[f] = v } }
    return k
}

let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    // Public: the page shell (so a home-screen bookmark loads) and the local CA as an iOS profile.
    // (/oldphonedeck.mobileconfig is the address from before the rename; links to it still work.)
    if req.path == "/revive.mobileconfig" || req.path == "/oldphonedeck.mobileconfig" {
        guard let der = try? Data(contentsOf: LocalTLS.caDER) else { return conn.respond(404, text: "no certificate yet") }
        let cert: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": "com.mayankgulaty.revive.ca.cert", "PayloadUUID": "8D2B5C61-4E3A-4F7B-9C1D-2E6F7A8B9C01",
            "PayloadDisplayName": "Revive CA", "PayloadCertificateFileName": "revive-ca.cer", "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.mayankgulaty.revive.ca", "PayloadUUID": "1A4C7E92-5B6D-4E8F-A0B1-C2D3E4F50612",
            "PayloadDisplayName": "Revive", "PayloadOrganization": "Revive",
            "PayloadDescription": "Lets this iPhone open Revive on your Mac over HTTPS (needed for camera, mic and voice).",
            "PayloadContent": [cert],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
        return conn.respond(200, "application/x-apple-aspen-config", data)
    }
    if req.path == "/" || req.path == "/index.html" {
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("index.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)
    }
    guard req.query["k"] == token else { return conn.respond(403, text: "bad token") }
    activity.touch()
    let p = req.params

    switch (req.method, req.path) {
    case ("GET", "/info"):
        conn.respondJSON(["camera": phoneMedia.isLive])
    case ("GET", "/stats"):
        var snap = stats.snapshot()
        snap["music"] = music.snapshot()
        snap["time"] = WorldClocks.snapshot()
        conn.respondJSON(snap)
    case ("POST", "/speedtest"):
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case ("POST", "/media"):
        let cmd = p["cmd"] ?? ""
        if cmd == "open" { DispatchQueue.global().async { music.openPlayer() } } else { music.control(cmd) }
        conn.respond(text: "ok")
    case ("GET", "/artwork"):
        guard let art = music.artwork() else { return conn.respond(404, text: "no artwork") }
        conn.respond(200, "image/jpeg", art)
    case ("GET", "/launcher"):
        let selected: Any = Launcher.selected() ?? NSNull()
        conn.respondJSON(["selected": selected, "all": Apps.list(), "folders": Folders.suggestions()])
    case ("POST", "/launcher"):
        // Body: keys=<JSON array of keys> in display order.
        guard let json = p["keys"]?.data(using: .utf8),
              let keys = try? JSONSerialization.jsonObject(with: json) as? [[String: String]] else {
            return conn.respond(400, text: "bad keys")
        }
        do { conn.respondJSON(["saved": try Launcher.save(keys)]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("GET", "/icon"):
        let reply = { (png: Data?) in server.queue.async { conn.respond(200, "image/png", png ?? Data()) } }
        switch p["type"] ?? "app" {
        case "link":
            guard let url = Links.web(p["url"] ?? "") else { return conn.respond(404, text: "bad link") }
            Links.icon(for: url, done: reply)
        case "folder":
            guard let dir = Folders.resolve(p["path"] ?? "") else { return conn.respond(404, text: "no such folder") }
            DispatchQueue.main.async { reply(Icons.file(dir)) }
        default:
            let path = p["path"] ?? ""
            guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
            DispatchQueue.main.async { reply(Apps.icon(path)) }
        }
    case ("POST", "/launch"):
        guard Launcher.open(keyParams(p)) else { return conn.respond(404, text: "can't open that") }
        conn.respond(text: "ok")
    case ("GET", "/clocks"):
        conn.respondJSON(["selected": WorldClocks.selectedKeys(), "all": WorldClocks.all(), "max": WorldClocks.maxCount])
    case ("POST", "/clocks"):
        // Body: ids=<zone|city>\n<zone|city>… in display order.
        let ids = (p["ids"] ?? "").split(separator: "\n").map(String.init)
        do { conn.respondJSON(["saved": try WorldClocks.save(ids).count]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("POST", "/claude"):
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if text.isEmpty { Claude.focus() } else { Claude.ask(text, autoSend: p["send"] == "1") }
        }
        conn.respond(text: "ok")
    case ("GET", "/camera.mjpg"):
        let id = ObjectIdentifier(conn)
        conn.onClose = { server.queue.async { cameraViewers[id] = nil } }
        cameraViewers[id] = conn
        conn.beginMJPEG()
        if let last = phoneMedia.latestFrame { conn.pushFrame(last) }
    case ("GET", "/camera.jpg"):
        conn.respond(200, "image/jpeg", phoneMedia.latestFrame ?? Data())
    default:
        conn.respond(404, text: "not found")
    }
}
server.start(routes)

// HTTPS + secure WebSocket for modern iPhones (Safari needs a secure page for camera, mic and speech).
let links = PairingLinks.current(token: token, port: opts.port)
var httpsServer: HTTPServer?
if let identity = LocalTLS.identity(for: links.ip, host: links.host) {
    do {
        let s = try HTTPServer(port: opts.port + 2, parameters: LocalTLS.parameters(identity), queue: server.queue)
        s.start(routes)
        httpsServer = s
        try phoneMedia.startWebSocket(port: opts.port + 3, identity: identity)
    } catch { print("⚠️  HTTPS failed to start: \(error)") }
}

// MARK: Menu bar, permissions, start

let statusMenu = StatusMenu(links: { PairingLinks.current(token: token, port: opts.port) }, activity: activity)
StatusMenu.enableLoginOnFirstRun()

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("⚠️  Grant Accessibility permission (System Settings → Privacy & Security → Accessibility) so Take note can press Return in Claude.")
}

if isatty(STDOUT_FILENO) != 0, let qr = QR.terminal(links.deck) { print("\n" + qr, terminator: "") }
print("""

Revive is running (look for its icon in the menu bar). On the phone (same Wi-Fi), open Safari and go to:

    \(links.deck)
\(links.host != nil ? "    or, if that name doesn't load: \(links.deckByIP)\n" : "")
Modern iPhones can scan the code above. Then tap Share → Add to Home Screen. Hold any key to choose your keys.

Modern iPhone (voice, camera, mic): once, open \(links.profile),
install it, enable it in Settings → General → About → Certificate Trust Settings,
then use \(links.secureDeck)
Camera for OBS (Media Source): \(links.obsCamera)
Menu bar → Pair a Phone… shows these as QR codes. Ctrl-C to quit.

""")

// First run of the installed app: there's no terminal, so show the pairing codes.
if StatusMenu.isApp && !UserDefaults.standard.bool(forKey: "pairingShown") {
    UserDefaults.standard.set(true, forKey: "pairingShown")
    DispatchQueue.main.async { statusMenu.showPairing() }
}

signal(SIGINT) { _ in exit(0) }
app.run()
