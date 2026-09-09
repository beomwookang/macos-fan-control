//
// The settings window: a draggable curve, with the numbers behind Advanced.
//

import AppKit

// MARK: - settings window

/// Curve first, numbers second. The window opens on a draggable graph; the nine
/// response parameters are real but rarely touched, so they sit behind a
/// disclosure rather than greeting everyone who wants the fan a bit quieter.
/// One width budget for the whole window. Every arranged row is laid out to
/// INNER, the content view is INNER plus the stack's insets, and any label that
/// can run long wraps inside it. Sizing the window from fittingSize alone was
/// what clipped it: a single-line label whose intrinsic width exceeds its row
/// constraint leaves the layout ambiguous, and the width that falls out of that
/// is smaller than the content actually needs.
private let INNER: CGFloat = 540
private let PAD: CGFloat = 20

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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: INNER + PAD * 2, height: 420),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "fanctl Settings"
        self.init(window: w)
        w.delegate = self
        build(status)
        w.center()
    }

    private func label(_ s: String, size: CGFloat = 13, color: NSColor = .labelColor,
                       wrap: CGFloat? = nil) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size)
        t.textColor = color
        if let wrap {
            // Without this a long label reports one enormous line, which is what
            // made the window's own fitting size disagree with its contents.
            t.lineBreakMode = .byWordWrapping
            t.maximumNumberOfLines = 0
            t.preferredMaxLayoutWidth = wrap
            t.widthAnchor.constraint(equalToConstant: wrap).isActive = true
        }
        return t
    }

    /// Live reading pushed in by the menu bar app, so the marker on the graph
    /// tracks the machine while you are editing the curve it follows.
    func updateLive(_ st: Status) {
        guard st.ok, st.have_temp else { return }
        editor.criticalTemp = st.critical_temp
        editor.live = (temp: st.temp, rpm: st.rpm)
    }

    private func build(_ st: Status) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: PAD, bottom: 16, right: PAD)
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
        titleRow.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(titleRow)

        editor.minRPM = st.min_rpm > 0 ? st.min_rpm : 1000
        editor.maxRPM = st.max_rpm > 0 ? st.max_rpm : 4900
        editor.criticalTemp = st.critical_temp
        editor.setPoints(st.curve)
        editor.onChange = { [weak self] _ in self?.note.stringValue = "" }
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        editor.heightAnchor.constraint(equalToConstant: 250).isActive = true
        stack.addArrangedSubview(editor)
        stack.addArrangedSubview(label(
            "Drag a point to move it · double-click to add · ⌫ to remove · "
            + "the leftmost point is the base speed",
            size: 11, color: .secondaryLabelColor, wrap: INNER))

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
            _ = f
            // The explanation column is wrapped to whatever is left after the
            // name and the field, so the grid cannot push the window wider.
            grid.addRow(with: [label(name, size: 12), f,
                               label(why, size: 11, color: .secondaryLabelColor,
                                     wrap: INNER - 160 - 62 - 24)])
        }
        grid.column(at: 0).xPlacement = .trailing

        advanced = NSStackView(views: [grid])
        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.isHidden = true
        stack.addArrangedSubview(advanced)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = INNER
        note.widthAnchor.constraint(equalToConstant: INNER).isActive = true
        stack.addArrangedSubview(note)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(close_))
        let buttons = NSStackView(views: [NSView(), close, save])
        buttons.spacing = 10
        buttons.widthAnchor.constraint(equalToConstant: INNER).isActive = true
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
        // Width is a decision, not a measurement. Only the height follows from
        // the content, and it is measured after a layout pass so wrapped labels
        // have already reported their real heights.
        w.contentView?.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        w.setContentSize(NSSize(width: INNER + PAD * 2, height: h))
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

