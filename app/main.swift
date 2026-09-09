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

    private let panel = StatusPanelView()
    private let panelItem = NSMenuItem()
    private let notInstalled = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Temperatures, oldest first, for the panel's sparkline. Capped at what
    /// fits the panel's width at one pixel per sample -- keeping more would draw
    /// several readings into the same column and show nothing extra.
    private var history: [Double] = []
    private let historyMax = 240
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

        panelItem.view = panel
        m.addItem(panelItem)
        notInstalled.isEnabled = false
        notInstalled.isHidden = true
        m.addItem(notInstalled)
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

        if let st, st.ok, st.have_temp {
            history.append(st.temp)
            if history.count > historyMax { history.removeFirst(history.count - historyMax) }
        }

        // Both halves of the mark carry a value, so the icon answers the same
        // question as the numbers for the times you do not read them. Drawn
        // under the button's own appearance: a dynamic colour resolved outside
        // it would be stale after a light/dark switch.
        let draw = {
            // One image, text included. Handing the button a two-line title let
            // it centre the block by its own reckoning, which pushed it up and
            // clipped the temperature.
            self.item.button?.image = statusMark(
                temp: (st?.ok == true && st?.have_temp == true) ? st?.temp : nil,
                rpm: st?.rpm ?? 0,
                minRPM: st?.min_rpm ?? 1000, maxRPM: st?.max_rpm ?? 4900,
                critical: st?.critical_temp ?? 98, running: running)
            self.item.button?.attributedTitle = NSAttributedString(string: "")
        }
        if let ea = item.button?.effectiveAppearance {
            ea.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }

        panel.update(st, history: history, running: running)
        notInstalled.isHidden = state["installed"] ?? true
        if !notInstalled.isHidden {
            notInstalled.title = "The daemon is not installed — run sudo ./install.sh"
        }

        // Keep the marker on an open curve editor tracking the machine.
        if let st, settings?.window?.isVisible == true { settings?.updateLive(st) }

        toggleItem.title = running ? "Turn Fan Control Off (hand back to macOS)" : "Turn Fan Control On"
        loginItem.state = LoginItem.enabled ? .on : .off
        bootItem.state  = (state["boot"] ?? false) ? .on : .off
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
