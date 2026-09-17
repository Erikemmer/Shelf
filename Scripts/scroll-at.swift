// Scrolls at a point on screen, so a screenshot can show a panel further down
// than its first screenful.
//
// Why this exists: `Scripts/screenshots.sh` used to ask System Events to
// "scroll down at {120, 400}". There is no such command — System Events can
// click and it can type, but it cannot scroll. The line failed silently (the
// script sent AppleScript's errors to /dev/null), and the sidebar shot came out
// byte-identical to the library shot for as long as anybody looked at it.
//
// A scroll wheel event goes to whatever is under the *cursor*, so the cursor is
// warped to the point, the events are posted, and the cursor is put back where
// it was — a person watching sees the pointer flick and return.
//
// Needs the Accessibility permission for whatever runs it (posting events is
// exactly what that permission governs). Read-only in the sense that matters:
// it scrolls a view, it does not click anything.
//
// Usage: swift Scripts/scroll-at.swift <x> <y> [clicks] [lines-per-click]
//   x, y      in screen points, origin top-left, as AppleScript and
//             `screencapture` count them
//   clicks    negative scrolls down (the direction a wheel turns to move
//             content up), default -12
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: scroll-at.swift <x> <y> [clicks] [lines-per-click]\n".utf8))
    exit(2)
}
let point = CGPoint(x: arguments[0], y: arguments[1])
let clicks = Int(arguments.count > 2 ? arguments[2] : -12)
let linesPerClick = Int32(arguments.count > 3 ? arguments[3] : 3)

guard let source = CGEventSource(stateID: .hidSystemState) else {
    FileHandle.standardError.write(Data("no event source – is Accessibility granted?\n".utf8))
    exit(3)
}

let cursorWasAt = CGEvent(source: nil)?.location ?? .zero
CGWarpMouseCursorPosition(point)
// The warp and the first event in the same instant sometimes arrive at the old
// window; a tick of a second is enough and is not noticeable.
usleep(150_000)

let step: Int32 = clicks < 0 ? -linesPerClick : linesPerClick
for _ in 0..<abs(clicks) {
    guard
        let event = CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: step, wheel2: 0,
            wheel3: 0)
    else { continue }
    event.location = point
    event.post(tap: .cghidEventTap)
    usleep(20_000)
}

usleep(150_000)
CGWarpMouseCursorPosition(cursorWasAt)
print("scrolled \(clicks) click(s) at \(Int(point.x)),\(Int(point.y))")
