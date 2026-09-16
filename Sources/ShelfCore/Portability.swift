import Foundation

/// Runs a body inside an autorelease pool where there is one.
///
/// `autoreleasepool` is Darwin-only – it is not in swift-corelibs-foundation –
/// and the core builds on Linux, so the call sites cannot use it directly. This
/// was found by the Linux CI job on the first push, which is what that job is
/// for.
///
/// It is not decoration on Darwin. The chunks a `FileHandle` read hands back are
/// autoreleased, and a loop without a pool of its own holds every chunk of the
/// file until it ends: Selector measured 1.2 GB peak for a 7.4 GB folder, and
/// 28 MB with the pool. On Linux there is no autorelease to do, so the body
/// simply runs.
@inline(__always)
func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
        return try autoreleasepool(invoking: body)
    #else
        return try body()
    #endif
}
