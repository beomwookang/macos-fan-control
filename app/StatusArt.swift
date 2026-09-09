//
// Drawn status: the menu bar mark, and the panel at the top of its menu.
//
// Both halves of the icon carry a value. The thermometer's column fills and
// reddens with temperature; the fan's ring fills with RPM. Neither is
// decoration -- the point is that a glance at the mark answers the same
// question as reading the numbers, for the times you are not reading them.
//

import AppKit

// MARK: - menu bar mark

private let ICON_W: CGFloat = 25
private let ICON_H: CGFloat = 18

/// Fraction of the way from `lo` to `hi`, clamped. Used for both gauges.
private func frac(_ v: Double, _ lo: Double, _ hi: Double) -> CGFloat {
    guard hi > lo else { return 0 }
    return CGFloat(min(max((v - lo) / (hi - lo), 0), 1))
}

/// Draws the gauge glyph into the current context at the given origin.
private func drawGauges(at o: NSPoint, temp: Double?, rpm: Double,
                        minRPM: Double, maxRPM: Double, critical: Double, running: Bool) {
    // Dimmed as a whole when control is off, so the mark reads as inactive
    // before you have parsed either gauge.
    let dim: CGFloat = running ? 1.0 : 0.4
    let ink = NSColor.labelColor.withAlphaComponent(0.85 * dim)
    let track = NSColor.labelColor.withAlphaComponent(0.22 * dim)

    // --- fan: a ring that fills clockwise with RPM
    let c = NSPoint(x: o.x + 8.5, y: o.y + 9)
    let r: CGFloat = 7.2

    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ring.lineWidth = 1.6
    track.setStroke()
    ring.stroke()

    let f = frac(rpm, minRPM, maxRPM)
    if f > 0.005 {
        let gauge = NSBezierPath()
        // Starts at 12 o'clock and sweeps clockwise, the direction a dial is
        // read, rather than the counter-clockwise default.
        gauge.appendArc(withCenter: c, radius: r, startAngle: 90,
                        endAngle: 90 - Double(f) * 360, clockwise: true)
        gauge.lineWidth = 1.6
        gauge.lineCapStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(dim).setStroke()
        gauge.stroke()
    }

    // Three swept blades rather than four symmetric ones: at this size a
    // symmetric petal reads as a flower, and the sweep gives it a direction.
    // The angle advances with RPM, so successive redraws show the fan having
    // turned further when it is spinning faster.
    let spin = Double(f) * 120.0
    func pt(_ a: Double, _ d: CGFloat) -> NSPoint {
        NSPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
    }
    for i in 0..<3 {
        let a = (Double(i) * 120.0 + spin) * .pi / 180
        let blade = NSBezierPath()
        blade.move(to: pt(a - 0.30, 1.4))
        // Leading edge sweeps ahead of the root, trailing edge cuts back to it
        // -- a comma, which is what a fan blade looks like end-on.
        blade.curve(to: pt(a + 0.62, 5.2),
                    controlPoint1: pt(a - 0.10, 4.2),
                    controlPoint2: pt(a + 0.30, 5.2))
        blade.curve(to: pt(a - 0.30, 1.4),
                    controlPoint1: pt(a + 0.95, 3.6),
                    controlPoint2: pt(a + 0.70, 1.8))
        ink.setFill()
        blade.fill()
    }
    NSColor.labelColor.withAlphaComponent(dim).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2)).fill()

    // --- thermometer: column height and colour both track the reading
    let tx = o.x + 20.5
    let bulbR: CGFloat = 2.4
    let bulb = NSPoint(x: tx, y: o.y + 3.2)
    let stemTop = o.y + 15.6
    let stemW: CGFloat = 2.2

    let outline = NSBezierPath()
    outline.appendOval(in: NSRect(x: bulb.x - bulbR, y: bulb.y - bulbR,
                                  width: bulbR * 2, height: bulbR * 2))
    outline.appendRoundedRect(NSRect(x: tx - stemW / 2, y: bulb.y,
                                     width: stemW, height: stemTop - bulb.y),
                              xRadius: stemW / 2, yRadius: stemW / 2)
    track.setFill()
    outline.fill()

    guard let temp else { return }
    // Scaled from 40 C, not 0: nothing below that is worth a pixel of travel on
    // a 12pt column, and starting there makes the useful range legible.
    let heat = heatColor(temp, critical: critical).withAlphaComponent(dim)
    let hf = frac(temp, 40, max(critical, 60))
    let colH = (stemTop - bulb.y - stemW / 2) * hf

    let merc = NSBezierPath()
    merc.appendOval(in: NSRect(x: bulb.x - bulbR + 0.6, y: bulb.y - bulbR + 0.6,
                               width: (bulbR - 0.6) * 2, height: (bulbR - 0.6) * 2))
    if colH > 0.5 {
        merc.appendRoundedRect(NSRect(x: tx - (stemW - 1.2) / 2, y: bulb.y,
                                      width: stemW - 1.2, height: colH),
                               xRadius: (stemW - 1.2) / 2, yRadius: (stemW - 1.2) / 2)
    }
    heat.setFill()
    merc.fill()
}

/// The whole menu bar item as one image: gauges, then temperature over RPM.
///
/// The text is drawn here rather than handed to the button as a two-line
/// attributedTitle. NSStatusBarButton centres a title by its own reckoning, and
/// for two lines that reckoning put the block too high and clipped the top of
/// the temperature. Drawing it means the baselines are stated outright.
func statusMark(temp: Double?, rpm: Double, minRPM: Double, maxRPM: Double,
                critical: Double, running: Bool) -> NSImage {
    let H: CGFloat = 18
    let gaugeW: CGFloat = 25
    let gap: CGFloat = 5

    let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let topStr = (temp.map { String(format: "%.0f°", $0) } ?? "--°") as NSString
    let botStr = (rpm > 0 ? String(format: "%.0f", rpm) : "--") as NSString
    let topColor = temp.map { heatColor($0, critical: critical) } ?? NSColor.secondaryLabelColor
    let topAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: topColor]
    let botAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor.withAlphaComponent(running ? 1 : 0.5),
    ]
    let textW = max(topStr.size(withAttributes: topAttrs).width,
                    botStr.size(withAttributes: botAttrs).width)

    let img = NSImage(size: NSSize(width: gaugeW + gap + textW, height: H), flipped: false) { _ in
        drawGauges(at: .zero, temp: temp, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM,
                   critical: critical, running: running)
        // draw(at:) takes the lower-left of the glyph box, and a 9pt box is
        // about 11pt tall -- two of them stacked naively do not fit 18pt. These
        // offsets overlap the boxes and leave the glyphs themselves clear.
        // Right-aligned: the two lines rarely have the same digit count, and
        // ragging them left leaves the stack looking accidental.
        let x = gaugeW + gap
        let tw = topStr.size(withAttributes: topAttrs).width
        let bw = botStr.size(withAttributes: botAttrs).width
        topStr.draw(at: NSPoint(x: x + textW - tw, y: H - 11.5), withAttributes: topAttrs)
        botStr.draw(at: NSPoint(x: x + textW - bw, y: -1.5), withAttributes: botAttrs)
        return true
    }
    // Not a template: the whole point is that the thermometer is coloured, and a
    // template image is a monochrome mask.
    img.isTemplate = false
    return img
}

// MARK: - menu panel

/// The panel at the top of the menu. Replaces two lines of text with the two
/// things the text could not show: where the temperature has been going, and
/// how much of the fan's range is actually in use.
final class StatusPanelView: NSView {
    static let W: CGFloat = 272
    static let H: CGFloat = 126

    private var st: Status?
    private var history: [Double] = []
    private var running = true

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.W, height: Self.H))
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ st: Status?, history: [Double], running: Bool) {
        self.st = st
        self.history = history
        self.running = running
        needsDisplay = true
    }

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, mono: Bool = false, rightOf: CGFloat? = nil) {
        let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                     : NSFont.systemFont(ofSize: size, weight: weight)
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
        let ns = s as NSString
        let x = rightOf.map { $0 - ns.size(withAttributes: a).width } ?? p.x
        ns.draw(at: NSPoint(x: x, y: p.y), withAttributes: a)
    }

    override func draw(_ dirty: NSRect) {
        let pad: CGFloat = 14
        let right = Self.W - pad

        guard let st, st.ok else {
            text("fanctl is not responding", NSPoint(x: pad, y: Self.H / 2 - 8),
                 size: 12, color: .secondaryLabelColor)
            return
        }

        let heat = st.have_temp ? heatColor(st.temp, critical: st.critical_temp) : .secondaryLabelColor

        // Bands, stated rather than derived. An earlier version positioned each
        // element relative to the last and the range labels ended up drawn on
        // top of the line they described.
        let yHead: CGFloat = Self.H - 32
        let ySub: CGFloat  = Self.H - 50
        let sparkY: CGFloat = 44
        let sparkH: CGFloat = 32
        let ySpan: CGFloat = 30
        let yGauge: CGFloat = 12

        // --- headline
        let tempStr = st.have_temp ? String(format: "%.0f°", st.temp) : "--°"
        text(tempStr, NSPoint(x: pad, y: yHead), size: 22, weight: .medium,
             color: heat, mono: true)
        text(String(format: "%.0f", st.rpm), NSPoint(x: 0, y: yHead + 4),
             size: 17, weight: .medium, mono: true, rightOf: right - 26)
        text("rpm", NSPoint(x: right - 23, y: yHead + 6), size: 10,
             color: .secondaryLabelColor)

        // --- second line: what the headline leaves out
        var bits: [String] = []
        if st.have_temp { bits.append(String(format: "peak %.0f° @%@", st.peak, st.peak_sensor)) }
        bits.append(running ? (st.forced ? "step \(st.level)" : "SMC control") : "paused")
        if st.forced && abs(st.target - st.rpm) > 50 {
            bits.append(String(format: "→ %.0f rpm", st.target))
        }
        text(bits.joined(separator: "  ·  "), NSPoint(x: pad, y: ySub),
             size: 10, color: .secondaryLabelColor)

        // --- sparkline, with the range labels in a reserved gutter so they can
        // never sit on top of the trace
        let gutter: CGFloat = 30
        let spark = NSRect(x: pad, y: sparkY, width: Self.W - pad * 2 - gutter, height: sparkH)
        if history.count >= 2 {
            // Auto-ranged, but never tighter than 15 C: zooming into a degree of
            // noise makes an idle machine look like it is thrashing.
            var lo = history.min()! - 1, hi = history.max()! + 1
            if hi - lo < 15 { let mid = (hi + lo) / 2; lo = mid - 7.5; hi = mid + 7.5 }

            let path = NSBezierPath()
            for (i, v) in history.enumerated() {
                let x = spark.minX + spark.width * CGFloat(i) / CGFloat(history.count - 1)
                let y = spark.minY + spark.height * frac(v, lo, hi)
                i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: spark.maxX, y: spark.minY))
            fill.line(to: NSPoint(x: spark.minX, y: spark.minY))
            fill.close()
            heat.withAlphaComponent(0.14).setFill()
            fill.fill()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            heat.setStroke()
            path.stroke()

            text(String(format: "%.0f°", hi), NSPoint(x: spark.maxX + 6, y: spark.maxY - 8),
                 size: 8, color: .tertiaryLabelColor, mono: true)
            text(String(format: "%.0f°", lo), NSPoint(x: spark.maxX + 6, y: spark.minY),
                 size: 8, color: .tertiaryLabelColor, mono: true)

            let secs = Double(history.count) * st.poll
            text(secs >= 90 ? "last \(Int(round(secs / 60))) min" : "last \(Int(secs))s",
                 NSPoint(x: pad, y: ySpan), size: 8, color: .tertiaryLabelColor)
        } else {
            text("collecting…", NSPoint(x: pad, y: spark.midY - 5), size: 10,
                 color: .tertiaryLabelColor)
        }

        // --- fan gauge: how much of the fan's range is in use
        let labelW: CGFloat = 30
        let bar = NSRect(x: pad + labelW, y: yGauge, width: Self.W - pad * 2 - labelW * 2, height: 5)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()

        let f = frac(st.rpm, st.min_rpm, st.max_rpm)
        if f > 0.01 {
            let filled = NSRect(x: bar.minX, y: bar.minY,
                                width: max(5, bar.width * f), height: bar.height)
            NSColor.controlAccentColor.withAlphaComponent(running ? 1 : 0.4).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
        }
        // Where the curve is asking for, when the ramp has not got there yet.
        if st.forced && abs(st.target - st.rpm) > 50 {
            let mx = bar.minX + bar.width * frac(st.target, st.min_rpm, st.max_rpm)
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: NSRect(x: mx - 0.75, y: bar.minY - 2,
                                      width: 1.5, height: bar.height + 4)).fill()
        }
        text(String(format: "%.0f", st.min_rpm), NSPoint(x: pad, y: yGauge - 2), size: 8,
             color: .tertiaryLabelColor, mono: true)
        text(String(format: "%.0f", st.max_rpm), NSPoint(x: 0, y: yGauge - 2), size: 8,
             color: .tertiaryLabelColor, mono: true, rightOf: right)
    }
}
