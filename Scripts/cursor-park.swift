// Moves the mouse pointer somewhere harmless, and nothing else.
//
// Why it exists: the screenshots are taken with `screencapture -R`, which
// photographs the *screen* — so whatever the pointer is hovering over is in the
// picture. A Sprint 5 shot came out with a Dock item's tooltip across the
// bottom of the window because the pointer had been left down there by the
// scroll before it.
//
// Needs the Accessibility permission, like every other script here that posts
// an event. It moves the pointer; it clicks nothing.
//
// Usage: swift Scripts/cursor-park.swift [x] [y]
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let x = Double(arguments.first ?? "") ?? 8
let y = arguments.count > 1 ? Double(arguments[1]) ?? 8 : 8

guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
else {
    FileHandle.standardError.write(Data("could not make a mouse event\n".utf8))
    exit(1)
}
move.post(tap: .cghidEventTap)
print("cursor parked at \(Int(x)),\(Int(y))")
