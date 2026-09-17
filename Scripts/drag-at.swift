// Drags from one point on screen to another, so a script can prove that
// dropping a book on a shelf works.
//
// A drag is not a click with a different name. AppKit starts a drag session
// only after the button has gone down and the pointer has *moved far enough,
// slowly enough* for the view to recognise it – so a mouse-down immediately
// followed by a mouse-up somewhere else is a click on the first point and
// nothing else. This posts the in-between moves, which is the whole reason it
// is not two calls to `click-at.swift`.
//
// Needs the Accessibility permission for whatever runs it.
//
// Usage: swift Scripts/drag-at.swift <fromX> <fromY> <toX> <toY> [steps]
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: drag-at.swift <fromX> <fromY> <toX> <toY> [steps]\n".utf8))
    exit(2)
}
let from = CGPoint(x: arguments[0], y: arguments[1])
let to = CGPoint(x: arguments[2], y: arguments[3])
let steps = arguments.count > 4 ? max(4, Int(arguments[4])) : 24
let wasAt = CGEvent(source: nil)?.location ?? .zero

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { return }
    // Same reason as in `click-at.swift`: without a click state the event is
    // "the mouse moved with a button down" to everything that asks.
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

CGWarpMouseCursorPosition(from)
CGAssociateMouseAndMouseCursorPosition(1)
usleep(200_000)
post(.mouseMoved, at: from)
usleep(80_000)
post(.leftMouseDown, at: from)
// A pause on the spot: a drag that starts in the same frame as the press is
// read as a click by some views and as nothing at all by others.
usleep(250_000)

for step in 1...steps {
    let fraction = Double(step) / Double(steps)
    let point = CGPoint(
        x: from.x + (to.x - from.x) * fraction,
        y: from.y + (to.y - from.y) * fraction)
    post(.leftMouseDragged, at: point)
    usleep(30_000)
}
// On the target for a moment, so the drop target has a chance to light up and
// to register the pointer as being over it.
usleep(400_000)
post(.leftMouseDragged, at: to)
usleep(100_000)
post(.leftMouseUp, at: to)
usleep(300_000)
CGWarpMouseCursorPosition(wasAt)
