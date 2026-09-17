// Prints the accessibility tree of a running process: the tree VoiceOver walks,
// and the only description of the window that can be read without a screenshot.
//
// It is how Sprint 1's "nobody has seen the window" was partly answered on a
// machine whose terminal has no Screen Recording permission: the tree says what
// is on screen, what it is called and what it says, even when `screencapture`
// refuses. It found two defects that way — two number formats in one window,
// and sidebar rows with no role a keyboard user can activate.
//
// `AXValueDescription` is read as well as `AXValue`, and that matters: SwiftUI
// puts `.accessibilityValue` on a custom control into the *description*, so a
// dumper that only reads `AXValue` reports "this control publishes no value"
// about a control that publishes one. That is exactly the wrong answer to have
// written down, and it was written down once.
//
// Needs the Accessibility permission (System Settings ▸ Privacy & Security ▸
// Accessibility) for whatever runs it. Read-only: it changes nothing.
//
// Usage: swift Scripts/ax-dump.swift <pid> [maxDepth]
import ApplicationServices
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax-dump.swift <pid> [maxDepth]\n".utf8))
    exit(2)
}
let maxDepth = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 12 : 12

func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let string = value as? String { return string.isEmpty ? nil : string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

/// The attributes worth printing, in the order a reader wants them.
let columns: [(label: String, key: String)] = [
    ("title", kAXTitleAttribute as String),
    ("value", kAXValueAttribute as String),
    ("valueDescription", kAXValueDescriptionAttribute as String),
    ("desc", kAXDescriptionAttribute as String),
    ("help", kAXHelpAttribute as String),
]

func dump(_ element: AXUIElement, depth: Int) {
    var line = String(repeating: "  ", count: depth) + (text(element, kAXRoleAttribute as String) ?? "?")
    if let subrole = text(element, kAXSubroleAttribute as String) { line += " [\(subrole)]" }
    for column in columns {
        guard let found = text(element, column.key) else { continue }
        let flat = found.replacingOccurrences(of: "\n", with: " ⏎ ")
        line += " \(column.label)=\"\(flat.count > 90 ? String(flat.prefix(90)) + "…" : flat)\""
    }
    print(line)
    guard depth < maxDepth,
        let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    else { return }
    for child in children { dump(child, depth: depth + 1) }
}

let app = AXUIElementCreateApplication(pid)
guard let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement], !windows.isEmpty else {
    FileHandle.standardError.write(
        Data("no windows for pid \(pid) – is the app hidden, or on another Space?\n".utf8))
    exit(3)
}
for window in windows { dump(window, depth: 0) }
