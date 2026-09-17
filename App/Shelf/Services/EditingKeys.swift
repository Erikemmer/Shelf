import AppKit

/// The editing keys – 1–5, 0, R, T – watched at the window rather than at a
/// view.
///
/// ## Why not a menu shortcut
///
/// Measured, and the reason for [ADR 0006](../../../docs/adr/0006-editing-keys-are-not-menu-shortcuts.md):
/// a menu key equivalent goes through `-[NSMenu performKeyEquivalent:]`, and a
/// held key spends 31 % of its time in `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS`
/// calling `usleep` on the main thread and another 27 % highlighting the menu
/// bar. A plain digit would also be swallowed before the search field saw it,
/// so "1984" could not be typed into it.
///
/// ## Why not `.onKeyPress` on the grid either
///
/// That was Sprint 2a's answer and it worked while the grid was the only thing
/// worth focusing. Sprint 2b put nine text fields in the inspector, and after
/// one of them had been typed in, the accessibility tree reported focus on the
/// *window* and on no control at all. In that state the grid's `.onKeyPress`
/// never fires, so 1–5, 0, R and T were dead — and could not be revived by
/// clicking a cover, because the grid's own `@FocusState` still said `true` and
/// assigning `true` to it is not a change. Measured five times out of five: a
/// tag typed through T landed zero times.
///
/// A local event monitor does not care where SwiftUI thinks focus is. It sees
/// the key before anything dispatches it, and it has exactly one rule to get
/// right: **keep its hands off text being typed**. That is a question with a
/// definite answer — is the window's first responder a field editor — rather
/// than a guess about focus.
@MainActor
final class EditingKeyMonitor {
    /// Returns true when the key was used, which is what stops it travelling on.
    private var handle: ((String) -> Bool)?
    private var monitor: Any?

    /// Starts watching, or replaces the handler if it is already watching.
    func start(_ handle: @escaping (String) -> Bool) {
        self.handle = handle
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A `Bool` comes back out of the isolated block and the event does
            // not: `NSEvent` is not `Sendable`, so returning one across the
            // boundary does not compile under strict concurrency. The block
            // itself runs on the main thread – AppKit dispatches events there
            // and nowhere else – which is what `assumeIsolated` states.
            let used = MainActor.assumeIsolated { Self.shared?.consume(event) ?? false }
            // `nil` swallows the event; returning it lets it travel on.
            return used ? nil : event
        }
        Self.shared = self
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handle = nil
        if Self.shared === self { Self.shared = nil }
    }

    /// The monitor's block cannot capture `self` strongly without keeping this
    /// object alive for the process's life, and a `weak` capture inside an
    /// `@Sendable` block that hops actors is worse. One window, one monitor.
    private static weak var shared: EditingKeyMonitor?

    private func consume(_ event: NSEvent) -> Bool {
        guard !isTypingIntoText else { return false }
        // ⌘, ⌥ and ⌃ belong to the menus. ⇧ is allowed through, because a
        // shifted digit is still that digit on some layouts.
        let claimed: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: claimed) else {
            return false
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return false
        }
        return handle?(characters) ?? false
    }

    /// Whether something is being typed into. While a SwiftUI `TextField` is
    /// being edited the window's first responder is its *field editor*, an
    /// `NSTextView` – so this is one question with a definite answer, and the
    /// search field, every inspector field and the tag field are all covered by
    /// it without being listed.
    private var isTypingIntoText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return false
    }
}
