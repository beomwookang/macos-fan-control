//
// Fanctl menu bar app.
//
// The daemon owns fan control; this is a window onto it. Everything that needs
// root goes through /usr/local/libexec/fanctl-admin, which sudoers allows
// without a password, so no branch here ever prompts mid-click.
//
// Quitting stops the daemon. That is deliberate: an invisible thing pinning the
// fan is the problem this app exists to solve, so the icon being gone has to
// mean fan control is actually off.
//

import AppKit
import Foundation

// MARK: - menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var settings: SettingsWindow?
    private var status: Status?
    private var state: [String: Bool] = [:]

    private let header      = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem  = NSMenuItem(title: "", action: #selector(toggleControl), keyEquivalent: "")
    private let loginItem   = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let bootItem    = NSMenuItem(title: "Start Daemon at Boot", action: #selector(toggleBoot), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading

        // The daemon is started on launch, not left to whatever it was doing.
        // The icon appearing has to mean control is on, or it tells you nothing.
        admin("start")

        buildMenu()
        refresh(full: true)
        // The tick only reads fanctl, which is one short-lived process against a
        // cached SMC connection. Daemon state needs sudo + launchctl, so it is
        // refreshed when it can actually have changed: at launch, when the menu
        // opens, and right after an action.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func buildMenu() {
        let m = NSMenu()
        m.delegate = self

        header.isEnabled = false
        detailItem.isEnabled = false
        m.addItem(header)
        m.addItem(detailItem)
        m.addItem(.separator())

        toggleItem.target = self
        m.addItem(toggleItem)

        let presetMenu = NSMenu()
        for (i, p) in presets.enumerated() {
            let mi = NSMenuItem(title: "\(p.name)  —  \(p.detail)",
                                action: #selector(applyPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            presetMenu.addItem(mi)
        }
        let presetItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetItem.submenu = presetMenu
        m.addItem(presetItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        m.addItem(settingsItem)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        m.addItem(logItem)

        m.addItem(.separator())
        loginItem.target = self
        bootItem.target = self
        m.addItem(loginItem)
        m.addItem(bootItem)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit (also stops fan control)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        item.menu = m
    }

    // Refresh while the menu is open too, so the numbers you are reading are
    // not the ones from before you clicked.
    func menuWillOpen(_ menu: NSMenu) { refresh(full: true) }

    private func refresh(full: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            let st = readStatus()
            let ds = full ? readDaemonState() : nil
            DispatchQueue.main.async { self.apply(st, ds) }
        }
    }

    private func apply(_ st: Status?, _ ds: [String: Bool]?) {
        status = st
        if let ds { state = ds }
        // `paused` comes from the status read, so a pause taking effect shows up
        // on the next tick without another privileged call.
        let running = (state["loaded"] ?? false) && !(st?.paused ?? true)

        // The icon carries on/off; the numbers are shown whenever they can be
        // read, including while control is paused. A paused machine still has a
        // temperature, and that is exactly when you want to see it.
        let symbol = running ? "fanblades.fill" : "fanblades"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "fanctl")
        item.button?.image?.isTemplate = true
        item.button?.appearsDisabled = !running
        item.button?.attributedTitle = barTitle(st)

        if let st, st.ok {
            if st.have_temp {
                let h = NSMutableAttributedString(
                    string: String(format: "%.0f°C", st.temp),
                    attributes: [.foregroundColor: heatColor(st.temp, critical: st.critical_temp),
                                 .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
                h.append(NSAttributedString(
                    string: String(format: "  ·  %d rpm", Int(st.rpm)),
                    attributes: [.foregroundColor: NSColor.labelColor,
                                 .font: NSFont.systemFont(ofSize: 13)]))
                header.attributedTitle = h
            } else {
                header.attributedTitle = NSAttributedString(string: "Temperature unreadable")
            }
            var bits: [String] = []
            bits.append(st.forced ? "fanctl controlling (step \(st.level))" : "macOS automatic control")
            if st.have_temp { bits.append(String(format: "peak %.0f°C @%@", st.peak, st.peak_sensor)) }
            if st.target != st.rpm && st.forced { bits.append("target \(Int(st.target)) rpm") }
            detailItem.title = bits.joined(separator: "  ·  ")
        } else {
            // attributedTitle wins over title once it has been set, so every
            // branch has to use it or the fallback text never appears.
            header.attributedTitle = NSAttributedString(string: "fanctl not responding")
            detailItem.title = "Check whether the daemon is installed"
        }

        if !(state["installed"] ?? true) {
            detailItem.title = "The daemon is not installed (sudo ./install.sh)"
        }

        // Keep the marker on an open curve editor tracking the machine.
        if let st, settings?.window?.isVisible == true { settings?.updateLive(st) }

        toggleItem.title = running ? "Turn Fan Control Off (hand back to macOS)" : "Turn Fan Control On"
        loginItem.state = LoginItem.enabled ? .on : .off
        bootItem.state  = (state["boot"] ?? false) ? .on : .off
    }

    /// Monospaced digits, so the item does not jitter sideways every time the
    /// temperature ticks over. Degrees and RPM are separated by a thin space
    /// rather than a bullet: at 11pt in a menu bar, punctuation between two
    /// numbers reads as noise.
    private func barTitle(_ st: Status?) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ]
        guard let st, st.ok else { return NSAttributedString(string: "") }
        let out = NSMutableAttributedString()
        func put(_ s: String, _ color: NSColor) {
            out.append(NSAttributedString(
                string: s, attributes: attrs.merging([.foregroundColor: color]) { $1 }))
        }
        if st.have_temp {
            // Only the temperature is coloured. The RPM is a consequence, not
            // the thing that is or is not a problem.
            put(" " + String(format: "%.0f°", st.temp),
                heatColor(st.temp, critical: st.critical_temp))
        }
        // F0Ac is readable whoever is driving the fan, so the RPM is shown even
        // when the SMC has it. Zero means the fan is genuinely stopped.
        if st.rpm > 0 {
            put((st.have_temp ? "\u{2009}" : " ") + String(format: "%.0f", st.rpm), .labelColor)
        }
        return out
    }

    @objc private func toggleControl() {
        let running = (state["loaded"] ?? false) && !(state["paused"] ?? false)
        admin(running ? "pause" : "start")
        refresh(full: true)
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        let p = presets[sender.tag]
        if let err = saveConf(p.values) {
            alert("Could not apply the \"\(p.name)\" preset", err)
        }
        refresh(full: true)
    }

    @objc private func openSettings() {
        guard let st = status, st.ok else {
            alert("Cannot open settings", "Could not read the fanctl status.")
            return
        }
        settings = SettingsWindow(status: st)
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLog() {
        shell("/usr/bin/open", ["-a", "Console", "/usr/local/var/log/fanctl.log"])
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.enabled, appPath: Bundle.main.bundlePath)
        refresh(full: true)
    }

    @objc private func toggleBoot() {
        admin((state["boot"] ?? false) ? "boot-off" : "boot-on")
        refresh(full: true)
    }

    // Quit means quit: the daemon goes down and the fan goes back to macOS.
    // Leaving a root daemon running behind a dismissed icon is the exact thing
    // that made this app necessary.
    @objc private func quit() {
        admin("stop")
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
