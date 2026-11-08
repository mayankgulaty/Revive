import AppKit
import ServiceManagement

/// When the phone last talked to the Mac (for "Phone connected" in the menu).
final class PhoneActivity {
    private let lock = NSLock()
    private var last: Date?
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return last.map { Date().timeIntervalSince($0) < 8 } ?? false }
}

/// The menu-bar item: pairing QR codes, links, Open at Login, Quit.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let links: () -> PairingLinks
    private let activity: PhoneActivity
    private var pairingWindow: NSWindow?

    /// Running as Revive.app (installed) rather than from the terminal.
    static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init(links: @escaping () -> PairingLinks, activity: PhoneActivity) {
        self.links = links
        self.activity = activity
        super.init()
        let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Revive")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: activity.isConnected ? "Phone connected" : "No phone connected", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(action("Pair a Phone…", #selector(showPairing)))
        menu.addItem(action("Copy Phone Link", #selector(copyDeck)))
        menu.addItem(action("Copy OBS Camera URL", #selector(copyCamera)))
        menu.addItem(.separator())
        if StatusMenu.isApp {
            let login = action("Open at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(action("Show Settings Folder", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Revive", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func copyDeck() { copy(links().deck) }
    @objc private func copyCamera() { copy(links().obsCamera) }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func showSettings() {
        NSWorkspace.shared.open(Config.dir)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Open at Login

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    /// The first time the installed app runs, start it at login: a desk display should come back after a restart.
    static func enableLoginOnFirstRun() {
        guard isApp, !UserDefaults.standard.bool(forKey: "loginItemOffered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemOffered")
        do { try SMAppService.mainApp.register() } catch { print("Open at Login: \(error.localizedDescription)") }
    }

    // MARK: Pairing window

    @objc func showPairing() {
        let l = links()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let codes = NSStackView(views: [
            qrColumn("Any iPhone", l.deck, "Scan with the Camera, open in Safari,\nthen Share → Add to Home Screen."),
            qrColumn("Voice, camera, mic: 1", l.profile, "Install the profile, then turn it on in\nSettings → General → About →\nCertificate Trust Settings."),
            qrColumn("Voice, camera, mic: 2", l.secureDeck, "Open the secure deck and add it\nto the Home Screen."),
        ])
        codes.orientation = .horizontal
        codes.alignment = .top
        codes.spacing = 22
        content.addArrangedSubview(codes)

        let old = label("Older iPhones can't scan codes. Type this in Safari:", size: 12, color: .secondaryLabelColor)
        content.addArrangedSubview(old)
        content.addArrangedSubview(selectable(l.deck, size: 15))
        if l.host != nil {
            content.addArrangedSubview(label("If that doesn't load, use the IP address (it changes if your router assigns a new one):", size: 11, color: .secondaryLabelColor))
            content.addArrangedSubview(selectable(l.deckByIP, size: 12))
        }

        let window = pairingWindow ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a Phone with Revive"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        pairingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func qrColumn(_ title: String, _ url: String, _ caption: String) -> NSView {
        let image = NSImageView(image: QR.image(url, size: 170) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 170).isActive = true
        image.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let col = NSStackView(views: [label(title, size: 13, weight: .semibold), image, label(caption, size: 11, color: .secondaryLabelColor)])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        return col
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    private func selectable(_ s: String, size: CGFloat) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .monospacedSystemFont(ofSize: size, weight: .medium)
        t.isSelectable = true
        return t
    }
}

/// Prints the error and, for the installed app (no terminal to print to), shows it too. Then quits.
func fatal(_ message: String) -> Never {
    print(message)
    if StatusMenu.isApp {
        if Thread.isMainThread { alert("Revive can't start", message) }
        else { DispatchQueue.main.sync { alert("Revive can't start", message) } }
    }
    exit(1)
}

/// Shows an error to someone running the installed app (no terminal to print to).
func alert(_ title: String, _ message: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}
