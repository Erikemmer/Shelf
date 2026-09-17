// Prints the CGWindowID of a process's largest on-screen window, which is what
// `screencapture -l` wants. Read-only, and needs no permission of its own – the
// permission `screencapture` needs is a separate matter.
//
// Largest rather than first: a process owns several layer-0 windows (see
// window-count.swift), and the one a person would call "the window" is the big
// one.
//
// Usage: swift Scripts/window-id.swift <pid>
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id.swift <pid>\n".utf8))
    exit(2)
}

let list =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let mine = list.filter {
    $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0
}

func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return (bounds["Width"] as? Double ?? 0) * (bounds["Height"] as? Double ?? 0)
}

guard let largest = mine.max(by: { area($0) < area($1) }),
    let id = largest[kCGWindowNumber as String] as? Int
else {
    FileHandle.standardError.write(Data("no on-screen window for pid \(pid)\n".utf8))
    exit(3)
}
print(id)
