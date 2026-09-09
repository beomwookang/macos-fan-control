//
// Shared model and IPC layer for the Fanctl menu bar app.
//
// Split out from main.swift so the windows can be instantiated and rendered by
// a test harness: main.swift carries top-level code, which Swift only allows in
// a file of that name, and which therefore cannot be linked into anything else.
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

// MARK: - heat

/// Heat colour for a temperature, expressed relative to the value the config
/// itself calls critical rather than against hardcoded numbers -- so raising or
/// lowering `critical_temp` moves these with it.
///
/// Only two steps above normal. A gradient would be prettier and would say
/// less: what a glance needs to answer is "is this fine, warming, or hot".
func heatColor(_ temp: Double, critical: Double) -> NSColor {
    guard critical > 30 else { return .labelColor }
    if temp >= critical - 8  { return .systemRed }
    if temp >= critical - 20 { return .systemOrange }
    return .labelColor
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

