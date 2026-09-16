import Foundation

/// In which order the background warmer walks through a library, and which
/// neighbours the grid prefetches.
///
/// Both start at the book in view and spread outwards in rings, so the part of
/// the library the user can reach next is ready first. A strict run from book 1
/// would leave someone who jumps to the end waiting for everything before it.
///
/// Copied from Selector. The one difference in intent: browsing a library moves
/// both ways about equally, where culling photos runs forward – but the
/// forward lean costs nothing and keeps the two apps' behaviour identical, so
/// it stays until a measurement says otherwise.
public enum WarmOrder {
    /// Indices ordered by distance from `index`, the centre first.
    ///
    /// At equal distance the later book wins (`index + 1` before `index - 1`).
    /// `radius` limits how far the rings reach; `nil` covers the whole library.
    /// Out-of-range centres are clamped, so a selection that a filter just hid
    /// still produces a sane order.
    public static func indices(around index: Int, count: Int, radius: Int? = nil) -> [Int] {
        guard count > 0 else { return [] }
        let centre = min(max(index, 0), count - 1)
        let reach = radius.map { max($0, 0) } ?? count

        var result = [centre]
        var distance = 1
        while distance <= reach && result.count < count {
            if centre + distance < count { result.append(centre + distance) }
            if centre - distance >= 0 { result.append(centre - distance) }
            distance += 1
        }
        return result
    }

    /// How much of a warming window lies ahead of the selection.
    public static let forwardShare = 2.0 / 3.0

    /// The `size` books worth holding in memory around `index`, in the order
    /// they should be warmed (nearest first, forward first).
    ///
    /// Near the start or the end of a library the window does not shrink – the
    /// share that does not fit moves to the other side, so the budget stays used.
    public static func window(around index: Int, count: Int, size: Int) -> [Int] {
        guard count > 0, size > 0 else { return [] }
        let centre = min(max(index, 0), count - 1)
        let neighbours = min(size, count) - 1

        var ahead = Int((Double(neighbours) * forwardShare).rounded())
        var behind = neighbours - ahead
        let roomAhead = count - 1 - centre
        let roomBehind = centre
        if ahead > roomAhead {
            behind = min(roomBehind, behind + ahead - roomAhead)
            ahead = roomAhead
        } else if behind > roomBehind {
            ahead = min(roomAhead, ahead + behind - roomBehind)
            behind = roomBehind
        }

        var result = [centre]
        for distance in 1...max(ahead, behind, 1) {
            if distance <= ahead { result.append(centre + distance) }
            if distance <= behind { result.append(centre - distance) }
        }
        return result
    }
}
