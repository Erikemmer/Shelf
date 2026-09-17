// Clicks at a point on screen, so a script can press a button or a cover that
// has no keyboard route to it.
//
// The same shape as `Scripts/scroll-at.swift` and for the same reason: System
// Events can click "at" a point, but only through a coordinate space that has
// caught this project out before, and a real CGEvent is what a mouse sends.
// The cursor is warped to the point, the events are posted, and the cursor is
// put back – a person watching sees the pointer flick and return.
//
// Needs the Accessibility permission for whatever runs it.
//
// Usage: swift Scripts/click-at.swift <x> <y> [right]
//   x, y    screen points, origin top-left
//   right   posts a right-click instead, for a context menu
import CoreGraphics
import Foundation

let words = Array(CommandLine.arguments.dropFirst())
let numbers = words.compactMap(Double.init)
guard numbers.count >= 2 else {
    FileHandle.standardError.write(Data("usage: click-at.swift <x> <y> [right]\n".utf8))
    exit(2)
}
let point = CGPoint(x: numbers[0], y: numbers[1])
let isRight = words.contains("right")
let down: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
let up: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
let button: CGMouseButton = isRight ? .right : .left
let wasAt = CGEvent(source: nil)?.location ?? .zero

func post(_ type: CGEventType) {
    guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    else { return }
    // Without this the event carries click state 0, which is "the mouse moved
    // while a button happened to be down", not "somebody clicked". AppKit
    // delivers it and SwiftUI's tap gesture ignores it – so the pointer visibly
    // jumps to the cover, the click is posted, and nothing at all is selected.
    // An hour of "the fix does not work" was this line missing.
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

// A move first: a window that has not seen the pointer arrive can treat the
// button-down as landing outside itself.
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?
    .post(tap: .cghidEventTap)

CGWarpMouseCursorPosition(point)
// Without this the click can arrive before the window server has moved the
// cursor, and it lands wherever the pointer used to be.
CGAssociateMouseAndMouseCursorPosition(1)
usleep(120_000)
post(down)
usleep(40_000)
post(up)
usleep(120_000)
CGWarpMouseCursorPosition(wasAt)
