import SwiftUI

/// Which modules are scanning right now and which have finished, so tabs and
/// the sidebar can show a spinner / green dot when the user switches away.
/// Fed by ScanProgressRing appearing and disappearing.
@MainActor
@Observable
final class ScanActivity {
    static let shared = ScanActivity()

    enum State: Equatable { case running, done }

    private(set) var states: [SidebarItem: State] = [:]
    private var runCount: [SidebarItem: Int] = [:]

    private init() {}

    func begin(_ item: SidebarItem) {
        runCount[item, default: 0] += 1
        if states[item] != .running { states[item] = .running }
    }

    func end(_ item: SidebarItem) {
        let n = max(0, runCount[item, default: 0] - 1)
        runCount[item] = n
        if n == 0 { states[item] = .done }
    }

    func state(_ item: SidebarItem) -> State? { states[item] }

    /// Group summary: running wins over done.
    func state(_ group: NavGroup) -> State? {
        let s = group.items.compactMap { states[$0] }
        if s.contains(.running) { return .running }
        return s.isEmpty ? nil : .done
    }
}

/// Small status mark: a mini spinner while working, a green dot when done.
struct ScanStatusMark: View {
    let state: ScanActivity.State?
    var onAccent = false

    var body: some View {
        Group {
            switch state {
            case .running:
                ProgressView()
                    .controlSize(.mini)
                    .tint(onAccent ? .white : nil)
                    .help(KMR.t("Scansione in corso", "Scanning"))
            case .done:
                Circle()
                    .fill(onAccent ? Color.white : KMR.green)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 0.5))
                    .help(KMR.t("Scansione completata", "Scan finished"))
            case nil:
                EmptyView()
            }
        }
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(duration: 0.35, bounce: 0.35), value: state)
    }
}
