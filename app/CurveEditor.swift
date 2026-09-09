//
// Draggable fan curve editor.
//
// The curve is the one thing in this app actually worth adjusting, and
// expressing it as "0:1000, 58:1400, ..." in a text field made the main feature
// the least approachable part of it. This is what the settings window opens on;
// every numeric knob moved behind an Advanced disclosure.
//

import AppKit

final class CurveEditorView: NSView {

    // MARK: - model

    private(set) var points: [CurvePoint] = []
    var minRPM: Double = 1000
    var maxRPM: Double = 4900

    /// Called on mouse-up and on structural edits, never mid-drag.
    var onChange: (([CurvePoint]) -> Void)?

    /// Live reading from the daemon, drawn as a marker so you can see where the
    /// machine currently sits on the curve you are editing.
    var live: (temp: Double, rpm: Double)? { didSet { needsDisplay = true } }

    /// Feeds the marker's colour, so warm and hot mean the same thing here as
    /// they do in the menu bar.
    var criticalTemp: Double = 98

    private let tMin = 30.0
    private let tMax = 100.0
    private let handleR: CGFloat = 5

    private var selected: Int?
    private var dragging: Int?

    // MARK: - setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func setPoints(_ p: [CurvePoint]) {
        points = p.sorted { $0.t < $1.t }
        // The daemon treats the first entry's temperature as 0 whatever it says,
        // so it is pinned here too rather than letting it drift and then
        // silently mean something else.
        if !points.isEmpty { points[0].t = 0 }
        selected = nil
        needsDisplay = true
    }

    // MARK: - geometry

    private var plot: NSRect {
        NSRect(x: 46, y: 26, width: max(1, bounds.width - 58), height: max(1, bounds.height - 40))
    }

    /// The base step sits at t=0, off the left of a 30-100C axis, so it is drawn
    /// pinned to the axis origin.
    private func px(_ t: Double) -> CGFloat {
        let tt = min(max(t, tMin), tMax)
        return plot.minX + CGFloat((tt - tMin) / (tMax - tMin)) * plot.width
    }
    private func py(_ r: Double) -> CGFloat {
        let rr = min(max(r, minRPM), maxRPM)
        return plot.minY + CGFloat((rr - minRPM) / (maxRPM - minRPM)) * plot.height
    }
    private func temp(atX x: CGFloat) -> Double {
        tMin + Double((x - plot.minX) / plot.width) * (tMax - tMin)
    }
    private func rpm(atY y: CGFloat) -> Double {
        minRPM + Double((y - plot.minY) / plot.height) * (maxRPM - minRPM)
    }
    private func handleRect(_ i: Int) -> NSRect {
        NSRect(x: px(points[i].t) - handleR, y: py(points[i].rpm) - handleR,
               width: handleR * 2, height: handleR * 2)
    }

    // MARK: - drawing

    override func draw(_ dirty: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let label = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: label, .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // grid + axis labels
        NSColor.separatorColor.setStroke()
        var t = tMin
        while t <= tMax {
            let x = px(t)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: plot.minY))
            p.line(to: NSPoint(x: x, y: plot.maxY))
            p.lineWidth = 0.5
            p.stroke()
            let last = t + 10 > tMax
            let text = (last ? "\(Int(t))°C" : "\(Int(t))") as NSString
            let w = text.size(withAttributes: attrs).width
            text.draw(at: NSPoint(x: last ? x - w : x - w / 2, y: 8), withAttributes: attrs)
            t += 10
        }
        var r = (minRPM / 1000).rounded(.up) * 1000
        while r <= maxRPM {
            let y = py(r)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.lineWidth = 0.5
            p.stroke()
            ("\(Int(r))" as NSString).draw(at: NSPoint(x: 6, y: y - 5), withAttributes: attrs)
            r += 1000
        }
        ("rpm" as NSString).draw(at: NSPoint(x: 6, y: plot.maxY + 4), withAttributes: attrs)

        guard points.count > 0 else { return }

        // The curve is a step function: hold the RPM until the next threshold,
        // then jump. Drawing it as a slope would misrepresent what it does.
        let step = NSBezierPath()
        step.move(to: NSPoint(x: plot.minX, y: py(points[0].rpm)))
        for i in points.indices {
            step.line(to: NSPoint(x: px(points[i].t), y: py(points[i].rpm)))
            let nextX = i + 1 < points.count ? px(points[i + 1].t) : plot.maxX
            step.line(to: NSPoint(x: nextX, y: py(points[i].rpm)))
            if i + 1 < points.count {
                step.line(to: NSPoint(x: nextX, y: py(points[i + 1].rpm)))
            }
        }

        let fill = step.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
        fill.close()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        fill.fill()

        NSColor.controlAccentColor.setStroke()
        step.lineWidth = 2
        step.stroke()

        // live marker
        if let live {
            let x = px(live.temp), y = py(live.rpm)
            // Grey when normal rather than a colour: at normal temperature the
            // marker is only saying "you are here", and a warm hue there would
            // read as a warning that is not being made.
            let hc = heatColor(live.temp, critical: criticalTemp)
            let mark = hc == .labelColor ? NSColor.systemGray : hc
            let v = NSBezierPath()
            v.move(to: NSPoint(x: x, y: plot.minY))
            v.line(to: NSPoint(x: x, y: plot.maxY))
            v.lineWidth = 1
            v.setLineDash([3, 3], count: 2, phase: 0)
            mark.withAlphaComponent(0.7).setStroke()
            v.stroke()

            mark.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 4, y: y - 4, width: 8, height: 8)).fill()
            // Measured, not a guessed offset: the readout is wider than a fixed
            // clamp allowed for and ran off the right edge. Flips to the left of
            // the marker when there is no room on the right.
            let now = String(format: "%.0f°C  %.0f rpm", live.temp, live.rpm) as NSString
            let ra: [NSAttributedString.Key: Any] = [.font: label, .foregroundColor: mark]
            let tw = now.size(withAttributes: ra).width
            let tx = x + 8 + tw <= plot.maxX ? x + 8 : max(plot.minX, x - 8 - tw)
            now.draw(at: NSPoint(x: tx, y: plot.maxY - 12), withAttributes: ra)
        }

        // handles
        for i in points.indices {
            let rect = handleRect(i)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
            (i == selected ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    // MARK: - editing

    private func hit(_ p: NSPoint) -> Int? {
        for i in points.indices where handleRect(i).insetBy(dx: -4, dy: -4).contains(p) {
            return i
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = hit(p) {
            selected = i
            dragging = i
            needsDisplay = true
            return
        }
        if e.clickCount == 2, plot.insetBy(dx: -2, dy: -2).contains(p) {
            insert(at: p)
            return
        }
        selected = nil
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let i = dragging else { return }
        let p = convert(e.locationInWindow, from: nil)
        points[i].rpm = (min(max(rpm(atY: p.y), minRPM), maxRPM) / 50).rounded() * 50

        // Index 0 is the base step and has no threshold of its own. The rest
        // stay strictly between their neighbours, so the list cannot become
        // unordered -- which the daemon would accept and then never climb past.
        if i > 0 {
            let lo = points[i - 1].t + 1
            let hi = i + 1 < points.count ? points[i + 1].t - 1 : tMax
            points[i].t = min(max(temp(atX: p.x).rounded(), lo), max(lo, hi))
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if dragging != nil { onChange?(points) }
        dragging = nil
    }

    private func insert(at p: NSPoint) {
        let t = min(max(temp(atX: p.x).rounded(), tMin), tMax)
        let r = (min(max(rpm(atY: p.y), minRPM), maxRPM) / 50).rounded() * 50
        guard !points.contains(where: { abs($0.t - t) < 1 }) else { return }
        points.append(CurvePoint(t: t, rpm: r))
        points.sort { $0.t < $1.t }
        selected = points.firstIndex { $0.t == t }
        needsDisplay = true
        onChange?(points)
    }

    private func removeSelected() {
        // Removing the base step would leave the curve with no floor.
        guard let i = selected, i > 0, points.count > 1 else { NSSound.beep(); return }
        points.remove(at: i)
        selected = nil
        needsDisplay = true
        onChange?(points)
    }

    override func keyDown(with e: NSEvent) {
        let del = e.charactersIgnoringModifiers?.unicodeScalars.first
        if del == UnicodeScalar(NSDeleteCharacter) || del == UnicodeScalar(NSBackspaceCharacter) {
            removeSelected()
        } else {
            super.keyDown(with: e)
        }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = hit(p), i > 0 else { return nil }
        selected = i
        needsDisplay = true
        let m = NSMenu()
        let mi = NSMenuItem(title: "Remove Point", action: #selector(removePoint), keyEquivalent: "")
        mi.target = self
        m.addItem(mi)
        return m
    }

    @objc private func removePoint() { removeSelected() }
}
