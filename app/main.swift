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

let FANCTL      = "/usr/local/bin/fanctl"
let ADMIN       = "/usr/local/libexec/fanctl-admin"
let CONF        = "/usr/local/etc/fanctl.conf"
let AGENT_LABEL = "com.local.fanctl.menubar"

// MARK: - subprocess

@discardableResult
func shell(_ path: String, _ args: [String], input: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var inPipe: Pipe? = nil
    if input != nil { inPipe = Pipe(); p.standardInput = inPipe }
    do { try p.run() } catch { return (-1, "") }
    if let ip = inPipe, let data = input?.data(using: .utf8) {
        ip.fileHandleForWriting.write(data)
        ip.fileHandleForWriting.closeFile()
    }
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = (String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? "")
    return (p.terminationStatus, text)
}

@discardableResult
func admin(_ verb: String, input: String? = nil) -> (code: Int32, out: String) {
    shell("/usr/bin/sudo", ["-n", ADMIN, verb], input: input)
}

// MARK: - status

struct CurvePoint: Codable { var t: Double; var rpm: Double }

struct Status: Codable {
    let ok: Bool
    var have_temp = false
    var temp = 0.0, peak = 0.0, peak_sensor = ""
    var nsensors = 0
    var rpm = 0.0, target = 0.0, min_rpm = 0.0, max_rpm = 0.0
    var forced = false, paused = false
    var mode = ""
    var level = 0
    var up_delay = 0.0, down_delay = 0.0
    var slew_up = 0.0, slew_down = 0.0
    var hysteresis = 0.0, poll = 0.0
    var alpha_up = 0.0, alpha_down = 0.0
    var critical_temp = 0.0
    var curve: [CurvePoint] = []
}

func readStatus() -> Status? {
    let r = shell(FANCTL, ["-j", "status"])
    guard r.code == 0, let data = r.out.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
}

/// loaded / paused / installed / boot, straight from launchd.
func readDaemonState() -> [String: Bool] {
    var out: [String: Bool] = [:]
    for line in admin("state").out.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { out[String(kv[0])] = (kv[1] == "1") }
    }
    return out
}

// MARK: - config

/// Rewrite only the keys that changed, in place. The config carries a lot of
/// hand-written commentary explaining why each number is what it is; a
/// regenerated file would throw that away on the first save.
func patchConf(_ text: String, _ kv: [String: String]) -> String {
    var lines = text.components(separatedBy: "\n")
    var seen = Set<String>()
    for i in lines.indices {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = lines[i].firstIndex(of: "=") else { continue }
        let key = String(lines[i][lines[i].startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        if let v = kv[key] { lines[i] = "\(key) = \(v)"; seen.insert(key) }
    }
    for (k, v) in kv.sorted(by: { $0.key < $1.key }) where !seen.contains(k) {
        lines.append("\(k) = \(v)")
    }
    return lines.joined(separator: "\n")
}

func saveConf(_ kv: [String: String]) -> String? {
    let current = (try? String(contentsOfFile: CONF, encoding: .utf8)) ?? ""
    let r = admin("setconf", input: patchConf(current, kv))
    return r.code == 0 ? nil : (r.out.isEmpty ? "Could not save the settings" : r.out)
}

// MARK: - login item

/// A LaunchAgent rather than SMAppService: this bundle is ad-hoc signed, and a
/// plist in ~/Library/LaunchAgents works the same on every macOS without
/// needing a Developer ID.
enum LoginItem {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(AGENT_LABEL).plist"
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func set(_ on: Bool, appPath: String) {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let uid = getuid()
        if on {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>\(AGENT_LABEL)</string>
              <key>ProgramArguments</key>
              <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        } else {
            shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(AGENT_LABEL)"])
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - presets

struct Preset {
    let name: String
    let detail: String
    let values: [String: String]
}

/// Three points on the noise/temperature trade, expressed as whole configs so a
/// preset cannot leave half of a previous one behind.
let presets: [Preset] = [
    Preset(name: "Quiet", detail: "raises the fan later, and more slowly",
           values: ["curve": "0:1000, 64:1400, 71:1800, 77:2300, 83:2900, 89:3600, 95:4900",
                    "slew_up": "120", "slew_down": "90",
                    "up_delay": "12", "down_delay": "40", "alpha_up": "0.15"]),
    Preset(name: "Balanced", detail: "the defaults",
           values: ["curve": "0:1000, 58:1400, 65:1800, 71:2300, 77:2900, 83:3600, 89:4300, 95:4900",
                    "slew_up": "200", "slew_down": "120",
                    "up_delay": "8", "down_delay": "30", "alpha_up": "0.20"]),
    Preset(name: "Cool", detail: "raises it sooner, and further",
           values: ["curve": "0:1000, 52:1600, 58:2100, 64:2700, 70:3300, 78:4000, 86:4900",
                    "slew_up": "300", "slew_down": "150",
                    "up_delay": "4", "down_delay": "25", "alpha_up": "0.25"]),
]

// MARK: - settings window

/// Curve first, numbers second. The window opens on a draggable graph; the nine
/// response parameters are real but rarely touched, so they sit behind a
/// disclosure rather than greeting everyone who wants the fan a bit quieter.
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private var fields: [String: NSTextField] = [:]
    private let editor = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 520, height: 250))
    private let note = NSTextField(labelWithString: "")
    private let advancedToggle = NSButton()
    private var advanced = NSStackView()
    private var stack = NSStackView()

    private let rows: [(String, String, String)] = [
        ("slew_up",       "Rise limit (rpm/s)",   "Lower means the fan swells slowly and draws less attention. 0 = no limit"),
        ("slew_down",     "Fall limit (rpm/s)",   "Lower means it also quietens down gradually"),
        ("up_delay",      "Rise delay (s)",       "How long a step up must stay justified, so one brief load is ignored"),
        ("down_delay",    "Fall delay (s)",       "How long to wait after a load ends before slowing the fan"),
        ("hysteresis",    "Hysteresis (°C)",      "Extra cooling needed before stepping down. Stops oscillation at a threshold"),
        ("alpha_up",      "Rise smoothing (0-1)", "Smaller is less sensitive to momentary temperature spikes"),
        ("alpha_down",    "Fall smoothing (0-1)", "Smaller treats cooling as slower than it appears"),
        ("poll_interval", "Poll interval (s)",    "How often the sensors are read"),
        ("critical_temp", "Critical temp (°C)",   "Above this, ignore the curve and the limits and go to maximum"),
    ]

    convenience init(status: Status) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "fanctl Settings"
        self.init(window: w)
        w.delegate = self
        build(status)
        w.center()
    }

    private func label(_ s: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size)
        t.textColor = color
        return t
    }

    /// Live reading pushed in by the menu bar app, so the marker on the graph
    /// tracks the machine while you are editing the curve it follows.
    func updateLive(_ st: Status) {
        guard st.ok, st.have_temp else { return }
        editor.live = (temp: st.temp, rpm: st.rpm)
    }

    private func build(_ st: Status) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = label("Fan curve")
        title.font = .boldSystemFont(ofSize: 13)

        var presetButtons: [NSView] = [title, NSView()]
        for (i, p) in presets.enumerated() {
            let b = NSButton(title: p.name, target: self, action: #selector(loadPreset(_:)))
            b.tag = i
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.toolTip = p.detail
            presetButtons.append(b)
        }
        let titleRow = NSStackView(views: presetButtons)
        titleRow.spacing = 6
        titleRow.widthAnchor.constraint(equalToConstant: 528).isActive = true
        stack.addArrangedSubview(titleRow)

        editor.minRPM = st.min_rpm > 0 ? st.min_rpm : 1000
        editor.maxRPM = st.max_rpm > 0 ? st.max_rpm : 4900
        editor.setPoints(st.curve)
        editor.onChange = { [weak self] _ in self?.note.stringValue = "" }
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.widthAnchor.constraint(equalToConstant: 528).isActive = true
        editor.heightAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(editor)
        stack.addArrangedSubview(label(
            "Drag a point to move it · double-click to add · ⌫ to remove · the leftmost point is the base speed",
            size: 11, color: .secondaryLabelColor))

        advancedToggle.setButtonType(.onOff)
        advancedToggle.bezelStyle = .disclosure
        advancedToggle.title = ""
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        let advLabel = label("Advanced", size: 12)
        let advRow = NSStackView(views: [advancedToggle, advLabel])
        advRow.spacing = 4
        stack.addArrangedSubview(advRow)

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 7
        grid.columnSpacing = 12
        let vals: [String: Double] = [
            "slew_up": st.slew_up, "slew_down": st.slew_down,
            "up_delay": st.up_delay, "down_delay": st.down_delay,
            "hysteresis": st.hysteresis, "alpha_up": st.alpha_up,
            "alpha_down": st.alpha_down, "poll_interval": st.poll,
            "critical_temp": st.critical_temp,
        ]
        for (key, name, why) in rows {
            let f = NSTextField(string: fmt(vals[key] ?? 0))
            f.alignment = .right
            f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 62).isActive = true
            fields[key] = f
            grid.addRow(with: [label(name, size: 12), f,
                               label(why, size: 11, color: .secondaryLabelColor)])
        }
        grid.column(at: 0).xPlacement = .trailing

        advanced = NSStackView(views: [grid])
        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.isHidden = true
        stack.addArrangedSubview(advanced)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(close_))
        let buttons = NSStackView(views: [NSView(), close, save])
        buttons.spacing = 10
        buttons.widthAnchor.constraint(equalToConstant: 528).isActive = true
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
        resize()
    }

    private func resize() {
        guard let w = window else { return }
        w.setContentSize(stack.fittingSize)
    }

    private func fmt(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e6 && d >= 1
            ? String(Int(d)) : String(format: "%g", d)
    }

    private func parseCurve(_ s: String) -> [CurvePoint] {
        s.split(separator: ",").compactMap { part in
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard kv.count == 2, let t = Double(kv[0]), let r = Double(kv[1]) else { return nil }
            return CurvePoint(t: t, rpm: r)
        }
    }

    @objc private func toggleAdvanced() {
        advanced.isHidden = (advancedToggle.state != .on)
        resize()
    }

    /// A preset fills the form rather than saving straight away: the point of
    /// having them here is to give the curve a sane starting shape to drag from.
    @objc private func loadPreset(_ sender: NSButton) {
        let p = presets[sender.tag]
        if let c = p.values["curve"] { editor.setPoints(parseCurve(c)) }
        for (k, v) in p.values where k != "curve" { fields[k]?.stringValue = v }
        note.textColor = .secondaryLabelColor
        note.stringValue = "Loaded the \(p.name) preset. Save to apply it."
    }

    @objc private func close_() { window?.close() }

    @objc private func save() {
        var kv: [String: String] = [:]
        for (key, name, _) in rows {
            let raw = fields[key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            guard let v = Double(raw), v >= 0 else {
                advancedToggle.state = .on
                toggleAdvanced()
                fail("\(name): not a number - \"\(raw)\"")
                return
            }
            kv[key] = raw
        }
        let curve = editor.points
            .map { "\(Int($0.t)):\(Int($0.rpm))" }
            .joined(separator: ", ")
        if let err = validateCurve(curve) { fail(err); return }
        kv["curve"] = curve

        if let err = saveConf(kv) {
            fail(err.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            note.textColor = .systemGreen
            note.stringValue = "Saved. The daemon has already picked it up."
        }
    }

    /// The editor keeps the points ordered and in range, so this is a backstop
    /// for a curve that arrived from a preset or an older config file.
    private func validateCurve(_ s: String) -> String? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { return "The curve is empty" }
        var lastT = -1.0
        for p in parts {
            let kv = p.split(separator: ":")
            guard kv.count == 2, let t = Double(kv[0]), let r = Double(kv[1]) else {
                return "Malformed curve entry - \"\(p)\" (expected temperature:RPM)"
            }
            if t <= lastT { return "The curve must ascend by temperature - \"\(p)\"" }
            if r < 0 || r > 20000 { return "RPM out of range - \"\(p)\"" }
            lastT = t
        }
        return nil
    }

    private func fail(_ msg: String) {
        note.textColor = .systemRed
        note.stringValue = msg
    }
}

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

        // Icon carries the state at a glance; the RPM only appears when the fan
        // is actually being driven, so a quiet machine stays a quiet menu bar.
        let symbol = running ? "fanblades.fill" : "fanblades"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "fanctl")
        item.button?.image?.isTemplate = true
        item.button?.appearsDisabled = !running

        if let st, st.ok, running, st.forced {
            item.button?.title = " \(Int(st.rpm))"
        } else {
            item.button?.title = ""
        }

        if let st, st.ok {
            header.title = st.have_temp
                ? String(format: "%.0f°C  ·  %d rpm", st.temp, Int(st.rpm))
                : "Temperature unreadable"
            var bits: [String] = []
            bits.append(st.forced ? "fanctl controlling (step \(st.level))" : "macOS automatic control")
            if st.have_temp { bits.append(String(format: "peak %.0f°C @%@", st.peak, st.peak_sensor)) }
            if st.target != st.rpm && st.forced { bits.append("target \(Int(st.target)) rpm") }
            detailItem.title = bits.joined(separator: "  ·  ")
        } else {
            header.title = "fanctl not responding"
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
