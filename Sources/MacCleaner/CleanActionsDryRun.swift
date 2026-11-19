import AppKit
import SwiftUI
import MacCleanerKit

// "Prova senza pulire": a dry run of exactly what a clean would move to the
// Trash, built with the same routing and safety rules as
// `CleanActions.executeUserClean`, plus the report of what the real clean
// left in place.

/// What the last clean skipped by safety rules, for the done screen.
@MainActor
@Observable
final class CleanSafetyReport {
    static let shared = CleanSafetyReport()

    private(set) var skips: [CleanSafety.Skip] = []
    private(set) var finishedAt: Date?

    private init() {}

    func begin() {
        skips = []
        finishedAt = nil
    }

    func finish(_ skips: [CleanSafety.Skip]) {
        self.skips += skips
        finishedAt = Date()
        // The first real clean has happened: later ones skip the simulation
        // unless the Settings toggle asks for it every time.
        UserDefaults.standard.set(true, forKey: CleanSafety.hasCleanedDefaultsKey)
    }

    /// Skips of a clean that just finished (a done screen opened later
    /// must not show another module's report).
    var recentSkips: [CleanSafety.Skip] {
        guard let finishedAt, Date().timeIntervalSince(finishedAt) < 120 else { return [] }
        return skips
    }
}

extension CleanActions {
    /// Whether the next clean must show the simulation first.
    static var needsDryRun: Bool {
        let d = UserDefaults.standard
        return CleanSafety.needsDryRun(hasCleanedBefore: d.bool(forKey: CleanSafety.hasCleanedDefaultsKey),
                                       alwaysDryRun: d.bool(forKey: CleanSafety.dryRunDefaultsKey))
    }

    /// Simulates `executeUserClean(results:selectedItems:engine:)` without
    /// touching anything: same routing, same parent pruning, same per-item
    /// safety checks. Runs off the main thread (it stats every item).
    static func plan(results: [ScanResult], selectedItems: Set<URL>) async -> CleanSafety.Plan {
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path(percentEncoded: false) })
        }
        return await Task.detached(priority: .userInitiated) {
            var routed = Set<URL>()
            var byCategory: [(ScanCategory, FileItem)] = []
            for result in results {
                for item in result.items where selectedItems.contains(item.url) && routed.insert(item.url).inserted {
                    byCategory.append((result.category, item))
                }
            }
            // Same ancestor pruning as the real clean, per action group.
            let kept = Set(CleanActions.prunedToParents(byCategory.map(\.1)).map(\.url))
            let guardian = SafetyGuard()
            var entries: [(category: ScanCategory, bytes: UInt64, path: String, skip: CleanSafety.SkipReason?)] = []
            for (category, item) in byCategory where kept.contains(item.url) {
                let skip: CleanSafety.SkipReason?
                if CleanSafety.action(for: category) == .trash {
                    skip = CleaningEngine.safetySkipReason(
                        item, protectUserData: CleanSafety.enforcesProtectedUserData(for: category, path: item.url.path(percentEncoded: false)),
                        running: running, safetyGuard: guardian)
                        ?? (FileManager.default.fileExists(atPath: item.url.path(percentEncoded: false)) ? nil : .missing)
                } else {
                    skip = nil
                }
                entries.append((category, item.size, item.url.path(percentEncoded: false), skip))
            }
            return CleanSafety.plan(entries)
        }.value
    }
}

// MARK: - Views

/// The simulation sheet: what would go to the Trash, per category, and what
/// the safety rules would leave in place. Nothing moves until "Sposta nel
/// Cestino".
struct DryRunSummarySheet: View {
    let plan: CleanSafety.Plan?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @AppStorage(CleanSafety.dryRunDefaultsKey) private var alwaysDryRun = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text(KMR.t("Prova senza pulire", "Dry run"))
                    .font(.title2.weight(.semibold))
                Text(KMR.t("Ecco esattamente cosa succederebbe. Non è stato ancora toccato nulla.",
                           "Here is exactly what would happen. Nothing has been touched yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)

            if let plan {
                Form {
                    Section {
                        LabeledContent(KMR.t("Andrebbero nel Cestino", "Would go to the Trash")) {
                            Text("\(plan.totalCount.formatted()) · \(FileSizeFormatter.format(plan.totalBytes))")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                    } footer: {
                        Text(KMR.t("Tutto resta recuperabile dal Cestino finché non lo svuoti.",
                                   "Everything stays recoverable from the Trash until you empty it."))
                    }
                    if !plan.lines.isEmpty {
                        Section(KMR.t("Per categoria", "By category")) {
                            ForEach(plan.lines) { line in
                                LabeledContent {
                                    Text("\(line.count.formatted()) · \(FileSizeFormatter.format(line.bytes))")
                                        .monospacedDigit()
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(line.category.displayName)
                                            if line.action != .trash {
                                                Text(line.action == .thinInPlace
                                                     ? KMR.t("Ridotti sul posto, non spostati", "Slimmed in place, not moved")
                                                     : KMR.t("Eliminati per sempre (svuota il Cestino)", "Deleted for good (empties the Trash)"))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } icon: {
                                        IconTile(symbol: line.action == .trash ? "trash.fill" : "scissors", color: .accentColor)
                                    }
                                }
                            }
                        }
                    }
                    if !plan.skips.isEmpty {
                        Section {
                            ForEach(plan.skipCounts, id: \.reason) { entry in
                                LabeledContent {
                                    Text(entry.count.formatted()).monospacedDigit()
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.reason.countLabel(entry.count))
                                            Text(entry.reason.explanation)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        IconTile(symbol: SafetySkipsSummary.symbol(entry.reason),
                                                 color: SafetySkipsSummary.color(entry.reason))
                                    }
                                }
                            }
                            DisclosureGroup(KMR.t("Mostra percorsi", "Show paths")) {
                                ForEach(plan.skips.prefix(200), id: \.self) { skip in
                                    Text(skip.path)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help(skip.path)
                                }
                            }
                        } header: {
                            Text(KMR.t("Lasciati dove sono dalle regole di sicurezza", "Left in place by the safety rules"))
                        }
                    }
                    Section {
                        Toggle(KMR.t("Mostra questa prova prima di ogni pulizia", "Show this dry run before every clean"),
                               isOn: $alwaysDryRun)
                    }
                }
                .formStyle(.grouped)
            } else {
                ProgressView(KMR.t("Controllo degli elementi…", "Checking the items…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button(KMR.t("Annulla", "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(KMR.t("Sposta nel Cestino", "Move to Trash"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled((plan?.totalCount ?? 0) == 0)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 520)
        .frame(minHeight: 400, idealHeight: 520, maxHeight: 560)
    }
}

/// Done-screen lines: "Elementi saltati perché cambiati: 3", etc.
struct SafetySkipsSummary: View {
    let skips: [CleanSafety.Skip]

    var body: some View {
        // "Already gone" is not news.
        let entries = CleanSafety.counts(skips).filter { $0.reason != .missing }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries, id: \.reason) { entry in
                    Label {
                        Text(entry.reason.countLabel(entry.count))
                    } icon: {
                        Image(systemName: Self.symbol(entry.reason))
                            .foregroundStyle(Self.color(entry.reason))
                    }
                    .help(entry.reason.explanation)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    static func symbol(_ reason: CleanSafety.SkipReason) -> String {
        switch reason {
        case .missing: "questionmark.folder.fill"
        case .changed: "arrow.triangle.2.circlepath"
        case .inUse: "app.badge.fill"
        case .protectedData: "lock.shield.fill"
        case .protectedPath: "lock.fill"
        }
    }

    static func color(_ reason: CleanSafety.SkipReason) -> Color {
        switch reason {
        case .missing: .gray
        case .changed: .orange
        case .inUse: .blue
        case .protectedData: .green
        case .protectedPath: .gray
        }
    }
}
