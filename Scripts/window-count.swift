// Counts a process's windows, without needing permission to automate System
// Events. Prints two numbers: how many windows exist, and how many of those are
// currently on screen.
//
// The distinction matters: a minimised window, or one on another Space, still
// exists but is not on screen. Counting only the visible ones once reported "no
// window" for a perfectly healthy app.
//
// **The first number is not a window count.** Measured on macOS 26.6: every app
// carries four extra layer-0 windows of 1512 × 33 at (0, 0) that belong to the
// system's menu bar and are never on screen. Selector reports exactly the same
// four, which is how they were identified. So a healthy one-window app reads
// "5 1": four artefacts plus its window, one of them on screen. The *second*
// number is the one that counts windows.
//
// Since Sprint 2b there is a *third* number: windows on screen that are not
// menu-bar strips. That is the one to assert on. An app that started and never
// built its window reported "5 1" on a cold run and "1 1" on the run that went
// wrong, and in the second case the "1" was a menu-bar strip — a window that is
// not a window, counted as one.
//
// Usage: swift Scripts/window-count.swift <pid>   →  "5 1 1"
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-count.swift <pid>\n".utf8))
    exit(2)
}

/// Layer 0 is a normal document window; panels, menus and tooltips sit higher.
func documentWindows(_ option: CGWindowListOption) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    return (list ?? []).filter {
        $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0
    }
}

/// Whether a window is one of the menu-bar strips every app carries.
///
/// A strip at the very top of the screen, no taller than a menu bar. They are
/// the four artefacts the comment above describes, and until Sprint 2b they
/// were only *counted* — which let one of them pass as a real window: an app
/// that started and never built its window reported "1 1", and the smoke test
/// read the second number as "one window on screen" and said ok. Excluding them
/// makes the third number below the one worth asserting.
func isMenuBarStrip(_ window: [String: Any]) -> Bool {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let y = bounds["Y"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return y <= 1 && height <= 40
}

guard CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) != nil else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(3)
}

let all = documentWindows(.optionAll)
let onScreen = documentWindows(.optionOnScreenOnly)
let real = onScreen.filter { !isMenuBarStrip($0) }
// Three numbers now: layer-0 windows, those on screen, and those on screen that
// are not menu-bar strips. The first two are kept so the figures in the
// CHANGELOG ("a healthy Shelf reads 5 1") still mean what they meant.
print("\(all.count) \(onScreen.count) \(real.count)")
