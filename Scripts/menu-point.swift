// Prints the middle of an item in a menu that is **open right now**, in screen
// points — so a script can click `Set Cover…` in a pop-up menu instead of
// guessing where it landed.
//
// Why it is not `cell-point.swift`: that walks the application's *windows*, and
// a pop-up `NSMenu` is not in them. It hangs off the application element
// itself, beside the windows, and it is there only while it is open. A script
// that looks for a menu item among the windows finds nothing and — because
// these scripts call their tools with errors redirected — says nothing about
// having found nothing. That is the failure mode `cell-point.swift`'s own
// comment was written about, one level up.
//
// Keyboard driving was tried first and is worse, not better: arrow keys in a
// SwiftUI `Menu` move a highlight that is invisible to every check a script can
// make, and when the menu is not in fact open the same keys scroll the window
// behind it. A run then photographs a window that happens to look right.
//
// Needs the Accessibility permission. Read-only: it reads positions, it clicks
// nothing.
//
// Usage: swift Scripts/menu-point.swift <pid> <title> [n]
//   title   the item's title, exactly, or a prefix of it
//   n       the nth match, default 0
import ApplicationServices
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let pid = Int32(arguments[0]) else {
    FileHandle.standardError.write(Data("usage: menu-point.swift <pid> <title> [n]\n".utf8))
    exit(2)
}
let wantedTitle = arguments[1]
let wanted = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0

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

/// Every `AXMenuItem` under here, in the order they are drawn.
///
/// The menu bar is skipped on purpose: this is for pop-up menus, and a menu bar
/// item called `Cover` would otherwise be found in preference to the one in the
/// menu that is actually open.
func items(under element: AXUIElement, into found: inout [AXUIElement], depth: Int = 0) {
    guard depth < 12 else { return }
    let role = string(element, kAXRoleAttribute as String) ?? ""
    if role == kAXMenuBarRole as String { return }
    if role == kAXMenuItemRole as String {
        let title = string(element, kAXTitleAttribute as String) ?? ""
        if title == wantedTitle || title.hasPrefix(wantedTitle) { found.append(element) }
    }
    for child in children(element) { items(under: child, into: &found, depth: depth + 1) }
}

let app = AXUIElementCreateApplication(pid)
var found: [AXUIElement] = []
for child in children(app) { items(under: child, into: &found) }

guard found.indices.contains(wanted), let box = frame(found[wanted]) else {
    FileHandle.standardError.write(
        Data("no open menu item matching \"\(wantedTitle)\" (found \(found.count))\n".utf8))
    exit(3)
}
print("\(Int(box.midX)) \(Int(box.midY))")
