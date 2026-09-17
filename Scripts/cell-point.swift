// Prints the middle of a control in a running app's window, in screen points —
// so a script can click a *real* cell instead of a coordinate somebody measured
// off a screenshot once.
//
// Why it exists: `Scripts/keyboard-proof.sh` has to click a book cover and then
// press a key. A click computed from the window frame and a guess at the grid's
// padding is a click that silently lands on the background the moment a margin
// changes — and a proof whose failure mode is "the click missed" cannot tell
// that apart from the defect it is testing.
//
// The accessibility API knows where things are. This asks it.
//
// Needs the Accessibility permission (System Settings ▸ Privacy & Security ▸
// Accessibility). Read-only: it reads positions, it clicks nothing.
//
// Usage: swift Scripts/cell-point.swift <pid> <what> [n]
//   what   cell      the nth cover in the grid (default n = 0)
//          search    the search field
//          row       the nth row of the table
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2, let pid = Int32(arguments.first ?? "") else {
    FileHandle.standardError.write(Data("usage: cell-point.swift <pid> <cell|search|row> [n]\n".utf8))
    exit(2)
}
let what = Array(arguments)[1]
let wanted = arguments.count > 2 ? Int(Array(arguments)[2]) ?? 0 : 0

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

/// The element's frame in screen points, origin top-left – the same counting
/// `screencapture` and System Events use.
func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute as String),
        let sizeValue = attribute(element, kAXSizeAttribute as String)
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    // swift-format-ignore
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Depth-first, so the order matches what a person reads down the window.
func matches(_ element: AXUIElement, into found: inout [AXUIElement], depth: Int = 0) {
    guard depth < 20 else { return }
    let role = string(element, kAXRoleAttribute as String) ?? ""
    switch what {
    case "cell":
        // A cover is an AXImage whose help text is the cell's own three-line
        // summary; the sidebar's icons are images too and have none.
        if role == "AXImage", (string(element, kAXHelpAttribute as String)?.contains("\n") ?? false) {
            found.append(element)
        }
    case "search":
        if role == "AXTextField",
            (string(element, kAXHelpAttribute as String)?.hasPrefix("Search titles") ?? false)
        {
            found.append(element)
        }
    case "row":
        if role == "AXRow" { found.append(element) }
    default:
        break
    }
    for child in children(element) { matches(child, into: &found, depth: depth + 1) }
}

let application = AXUIElementCreateApplication(pid)
guard let windows = attribute(application, kAXWindowsAttribute as String) as? [AXUIElement],
    let window = windows.first
else {
    FileHandle.standardError.write(Data("no window for pid \(pid)\n".utf8))
    exit(1)
}

var found: [AXUIElement] = []
matches(window, into: &found)
guard wanted < found.count, let box = frame(found[wanted]) else {
    FileHandle.standardError.write(Data("found \(found.count) “\(what)” – no number \(wanted)\n".utf8))
    exit(1)
}
print("\(Int(box.midX)) \(Int(box.midY))")
