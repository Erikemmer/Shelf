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
// Usage: swift Scripts/window-count.swift <pid>   →  "5 1"
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

guard CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) != nil else {
    FileHandle.standardError.write(Data("could not read the window list\n".utf8))
    exit(3)
}

print("\(documentWindows(.optionAll).count) \(documentWindows(.optionOnScreenOnly).count)")
