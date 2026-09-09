//
// Checks for the parts of the app that are logic rather than drawing: the
// config rewriter, and the curve editor's editing rules.
//
// Driven through the real mouse and key handlers rather than by calling into
// the model, because the rules being checked -- the base step is pinned, points
// stay between their neighbours, the base step cannot be deleted -- exist to
// stop a drag producing a curve the daemon accepts and then behaves oddly on.
// Testing them below the event layer would not test them.
//
// Run with: make test
//

import AppKit

@main
enum EditorTests {
    static func main() {
        // AppKit needs an application instance before NSEvent or NSColor will
        // behave, even with nothing on screen.
        _ = NSApplication.shared

        var fails = 0
        func check(_ ok: Bool, _ what: String, _ detail: String = "") {
            print(ok ? "  ok   \(what)" : "  FAIL \(what)  \(detail)")
            if !ok { fails += 1 }
        }

        // ---------- patchConf: does the commentary survive an edit? ----------
        let conf = """
        # curve explains itself
        curve = 0:1000, 58:1400
        # hysteresis matters because of X
        hysteresis = 5
        #slew_up = 999
        mode = force
        """
        let out = patchConf(conf, ["curve": "0:1000, 60:1500", "slew_up": "200"])
        check(out.contains("# curve explains itself"), "patchConf keeps comments")
        check(out.contains("curve = 0:1000, 60:1500"), "patchConf replaces a key in place")
        check(out.contains("# hysteresis matters because of X"), "patchConf keeps unrelated comments")
        check(out.contains("hysteresis = 5"), "patchConf leaves untouched keys alone")
        check(out.contains("slew_up = 200"), "patchConf appends a key that was absent")
        check(out.contains("#slew_up = 999"), "patchConf does not resurrect a commented-out key",
              "a commented key must not be treated as the one to replace")
        check(out.components(separatedBy: "slew_up = 200").count == 2, "patchConf appends only once")

        // ---------- CurveEditorView: edited through real mouse events ----------
        // No window: CI runners may have no window server, and the view converts from
        // nil-window coordinates, which is an identity transform for a view that has no
        // superview. Everything under test is geometry and state, not presentation.
        let ed = CurveEditorView(frame: NSRect(x: 0, y: 0, width: 528, height: 250))
        ed.minRPM = 1000; ed.maxRPM = 4900

        // The view's geometry, restated here. If the view's changes, this breaks
        // first, which is the intent.
        let plot = NSRect(x: 46, y: 26, width: 528 - 58, height: 250 - 40)
        func px(_ t: Double) -> CGFloat {
            plot.minX + CGFloat((min(max(t, 30), 100) - 30) / 70) * plot.width
        }
        func py(_ r: Double) -> CGFloat {
            plot.minY + CGFloat((min(max(r, 1000), 4900) - 1000) / 3900) * plot.height
        }
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func drag(from a: NSPoint, to b: NSPoint) {
            ed.mouseDown(with: ev(.leftMouseDown, a))
            ed.mouseDragged(with: ev(.leftMouseDragged, b))
            ed.mouseUp(with: ev(.leftMouseUp, b))
        }

        // Unsorted input with a non-zero first temperature
        ed.setPoints([CurvePoint(t: 71, rpm: 2300), CurvePoint(t: 33, rpm: 1000),
                      CurvePoint(t: 58, rpm: 1400)])
        check(ed.points.map { $0.t } == [0, 58, 71], "setPoints sorts and pins the base step to 0",
              "\(ed.points.map { $0.t })")

        // The base step must not move sideways
        drag(from: NSPoint(x: px(0), y: py(1000)), to: NSPoint(x: px(50), y: py(1600)))
        check(ed.points[0].t == 0, "base step cannot be dragged sideways", "t=\(ed.points[0].t)")
        check(ed.points[0].rpm > 1000, "base step RPM can still be dragged", "rpm=\(ed.points[0].rpm)")

        // Dragged past a neighbour, a point has to stay between them
        ed.setPoints([CurvePoint(t: 0, rpm: 1000), CurvePoint(t: 58, rpm: 1400),
                      CurvePoint(t: 71, rpm: 2300)])
        drag(from: NSPoint(x: px(58), y: py(1400)), to: NSPoint(x: px(95), y: py(1400)))
        check(ed.points[1].t < ed.points[2].t, "a point cannot be dragged past its right neighbour",
              "\(ed.points.map { $0.t })")
        drag(from: NSPoint(x: px(ed.points[1].t), y: py(1400)), to: NSPoint(x: px(-20), y: py(1400)))
        check(ed.points[1].t > ed.points[0].t, "a point cannot be dragged past its left neighbour",
              "\(ed.points.map { $0.t })")
        check(zip(ed.points, ed.points.dropFirst()).allSatisfy { $0.t < $1.t },
              "ordering invariant holds after drags", "\(ed.points.map { $0.t })")

        // RPM clamping
        ed.setPoints([CurvePoint(t: 0, rpm: 1000), CurvePoint(t: 58, rpm: 1400)])
        drag(from: NSPoint(x: px(58), y: py(1400)), to: NSPoint(x: px(58), y: py(1400) + 9999))
        check(ed.points[1].rpm <= 4900, "RPM clamped to maxRPM", "rpm=\(ed.points[1].rpm)")
        drag(from: NSPoint(x: px(58), y: py(4900)), to: NSPoint(x: px(58), y: py(1000) - 9999))
        check(ed.points[1].rpm >= 1000, "RPM clamped to minRPM", "rpm=\(ed.points[1].rpm)")

        // Insertion by double-click
        ed.setPoints([CurvePoint(t: 0, rpm: 1000), CurvePoint(t: 80, rpm: 3000)])
        let before = ed.points.count
        ed.mouseDown(with: ev(.leftMouseDown, NSPoint(x: px(60), y: py(2000)), clicks: 2))
        check(ed.points.count == before + 1, "double-click inserts a point", "\(ed.points.count)")
        check(zip(ed.points, ed.points.dropFirst()).allSatisfy { $0.t < $1.t },
              "insert keeps the curve ordered", "\(ed.points.map { $0.t })")

        // Deletion: refused for the base step, allowed for the rest
        func pressDelete() {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                     isARepeat: false, keyCode: 51)!
            ed.keyDown(with: e)
        }
        ed.setPoints([CurvePoint(t: 0, rpm: 1000), CurvePoint(t: 58, rpm: 1400),
                      CurvePoint(t: 71, rpm: 2300)])
        ed.mouseDown(with: ev(.leftMouseDown, NSPoint(x: px(0), y: py(1000))))
        ed.mouseUp(with: ev(.leftMouseUp, NSPoint(x: px(0), y: py(1000))))
        pressDelete()
        check(ed.points.count == 3, "delete refuses to remove the base step", "\(ed.points.count)")
        ed.mouseDown(with: ev(.leftMouseDown, NSPoint(x: px(58), y: py(1400))))
        ed.mouseUp(with: ev(.leftMouseUp, NSPoint(x: px(58), y: py(1400))))
        pressDelete()
        check(ed.points.count == 2, "delete removes a selected non-base point", "\(ed.points.count)")
        check(ed.points.map { $0.t } == [0, 71], "delete removes the right one",
              "\(ed.points.map { $0.t })")

        // Serialisation: editor state to the config's curve syntax
        ed.setPoints([CurvePoint(t: 0, rpm: 1000), CurvePoint(t: 58, rpm: 1400),
                      CurvePoint(t: 77, rpm: 2900)])
        let line = ed.points.map { "\(Int($0.t)):\(Int($0.rpm))" }.joined(separator: ", ")
        check(line == "0:1000, 58:1400, 77:2900", "serialises to the config's curve syntax", line)

        print(fails == 0 ? "\nAll checks passed." : "\n\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)

    }
}