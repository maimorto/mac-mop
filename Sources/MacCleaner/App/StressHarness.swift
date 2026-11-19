import SwiftUI
import Darwin

/// Debug-only stress test, enabled with KMR_STRESS=<report path>.
/// Runs every module's read-only scan, switches pages randomly while scans
/// run, watches the main thread for hangs and samples memory, then writes a
/// report and quits. It never triggers a cleanup.
@MainActor
final class StressHarness {
    private final class Watchdog: @unchecked Sendable {
        let lock = NSLock()
        var hangs: [(at: Double, ms: Int, module: String)] = []
        var maxMs = 0
        var module = ""
        var running = true
        let start = Date()

        func setModule(_ m: String) { lock.withLock { module = m } }
        func stop() -> ([(at: Double, ms: Int, module: String)], Int) {
            lock.withLock { running = false; return (hangs, maxMs) }
        }

        func run() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock(); let go = running; lock.unlock()
                    if !go { return }
                    let sent = Date()
                    let sem = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { sem.signal() }
                    if sem.wait(timeout: .now() + 0.25) == .timedOut {
                        sem.wait()
                        let ms = Int(Date().timeIntervalSince(sent) * 1000)
                        lock.lock()
                        hangs.append((Date().timeIntervalSince(start), ms, module))
                        maxMs = max(maxMs, ms)
                        lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func run(appState: AppState, reportPath: String) async {
        let dog = Watchdog()
        dog.run()
        var memory: [Double] = []
        var log: [String] = []
        func note(_ s: String) { log.append(String(format: "%7.1fs ", Date().timeIntervalSince(dog.start)) + s) }
        func select(_ item: SidebarItem) {
            appState.selectedSidebarItem = item
            dog.setModule(item.deepLinkID)
        }
        let sampler = Task { @MainActor in
            while !Task.isCancelled { memory.append(footprintMB()); try? await Task.sleep(for: .seconds(1)) }
        }
        var modules = SidebarItem.allCases.filter { ![.settings, .shredder, .storageExtras].contains($0) }
        if let only = ProcessInfo.processInfo.environment["KMR_STRESS_ONLY"] {
            let ids = Set(only.split(separator: ",").map(String.init))
            modules = modules.filter { ids.contains($0.deepLinkID) }
        }

        if ProcessInfo.processInfo.environment["KMR_STRESS_MODE"] == "sequential" {
            let wait = Double(ProcessInfo.processInfo.environment["KMR_STRESS_WAIT"] ?? "") ?? 25
            for item in modules {
                select(item)
                try? await Task.sleep(for: .milliseconds(700))
                let before = footprintMB()
                let hangsBefore = dog.lock.withLock { dog.hangs.count }
                appState.requestScanShortcut()
                try? await Task.sleep(for: .seconds(wait))
                let after = footprintMB()
                let newHangs = dog.lock.withLock { Array(dog.hangs[hangsBefore...]) }
                note(String(format: "%@: mem %.0f -> %.0f MB (+%.0f), hangs %d, worst %d ms",
                            item.deepLinkID, before, after, after - before, newHangs.count, newHangs.map(\.ms).max() ?? 0))
            }
        } else {
        for round in 1...2 {
            note("round \(round): scanning every module")
            for item in modules {
                select(item)
                try? await Task.sleep(for: .milliseconds(700))
                appState.requestScanShortcut()
                note("scan requested: \(item.deepLinkID)")
                try? await Task.sleep(for: .milliseconds(1200))
            }
            note("round \(round): random switching x300")
            for _ in 0..<300 {
                guard let item = modules.randomElement() else { break }
                select(item)
                try? await Task.sleep(for: .milliseconds(30))
            }
            note("round \(round): letting scans finish")
            for _ in 0..<45 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        }
        sampler.cancel()
        let (hangs, maxMs) = dog.stop()

        var out = "STRESS REPORT\n"
        out += "duration: \(Int(Date().timeIntervalSince(dog.start)))s\n"
        out += "hangs >250ms: \(hangs.count), worst: \(maxMs)ms\n"
        out += String(format: "memory MB: start %.0f, peak %.0f, end %.0f\n", memory.first ?? 0, memory.max() ?? 0, memory.last ?? 0)
        out += "hangs by module:\n"
        var byModule: [String: (Int, Int)] = [:]
        for h in hangs { let v = byModule[h.module] ?? (0, 0); byModule[h.module] = (v.0 + 1, max(v.1, h.ms)) }
        for (m, v) in byModule.sorted(by: { $0.value.1 > $1.value.1 }) { out += "  \(m): \(v.0) hangs, worst \(v.1)ms\n" }
        out += "worst hangs:\n"
        for h in hangs.sorted(by: { $0.ms > $1.ms }).prefix(15) { out += String(format: "  t=%.1fs %dms in %@\n", h.at, h.ms, h.module) }
        out += "log:\n" + log.joined(separator: "\n") + "\n"
        try? out.write(toFile: reportPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
