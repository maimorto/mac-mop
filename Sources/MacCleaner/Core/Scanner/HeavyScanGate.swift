import Foundation

/// Lets only one home-wide filesystem walk run at a time. Several of them in
/// parallel (Duplicates, Large & Old Files, Project Junk) fight over the disk
/// and multiply peak memory without finishing sooner.
actor HeavyScanGate {
    static let shared = HeavyScanGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await work()
        release()
        return result
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
