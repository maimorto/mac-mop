import SwiftUI
import AppKit
import MacCleanerKit

// "Security check": 24 of the Mac's protections with their current state,
// why each matters and how to fix it (Settings pane, copyable command, or a
// fix the app runs after an explicit password prompt). Ideas from Pareto
// Security and Mergen; the checks are read-only and never ask for a
// password.

@MainActor
@Observable
final class SecurityCheckModel {
    var results: [SecurityCheckResult] = []
    var checking = false
    var lastRun: Date?
    var message: String?

    func run() async {
        guard !checking else { return }
        checking = true
        let found = await Task.detached(priority: .userInitiated) { await SecurityChecklistProbe.evaluate() }.value
        withAnimation(.smooth) { results = found }
        lastRun = Date()
        checking = false
    }

    func adminFix(_ kind: SecurityCheckKind) async {
        guard let command = SecurityChecklist.guide(for: kind).adminFix else { return }
        if await Shell.runAsAdmin(command) {
            await run()
        } else {
            message = KMR.t("Operazione annullata o non riuscita.", "Cancelled or failed.")
        }
    }
}

struct SecurityCheckView: View {
    @State private var model = SecurityCheckModel()
    @State private var expanded: Set<SecurityCheckKind> = []

    var body: some View {
        ZStack {
            if model.results.isEmpty && (model.checking || model.lastRun == nil) {
                ScanProgressRing(progress: 0, phase: KMR.t("Controllo delle protezioni…", "Checking protections…"), indeterminate: true)
                    .environment(\.currentModule, .securityCheck)
                    .transition(.immersive)
            } else if model.results.isEmpty {
                // The check finished without results: never leave a spinner up.
                ContentUnavailableView {
                    Label(KMR.t("Controllo non riuscito", "Check didn't complete"), systemImage: "exclamationmark.shield")
                } description: {
                    Text(KMR.t("Non è stato possibile leggere lo stato delle protezioni del Mac.",
                               "The Mac's protection status couldn't be read."))
                } actions: {
                    Button(KMR.t("Riprova", "Try Again")) { Task { await model.run() } }
                        .buttonStyle(.borderedProminent)
                }
                .transition(.immersive)
            } else {
                results.transition(.immersive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.immersiveScreen, value: model.results.isEmpty)
        .task { if model.results.isEmpty { await model.run() } }
        .respondsToModuleShortcuts(onScan: { Task { await model.run() } }, canScan: !model.checking)
        .alert(KMR.t("Controllo sicurezza", "Security check"),
               isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var results: some View {
        Form {
            summary
            ForEach(SecurityCheckKind.Group.allCases, id: \.self) { group in
                let rows = model.results.filter { $0.kind.group == group }
                if !rows.isEmpty {
                    Section(group.title) {
                        ForEach(rows) { result in row(result) }
                    }
                }
            }
            Section {
                Button(KMR.t("Controlla di nuovo", "Check again")) { Task { await model.run() } }
                    .disabled(model.checking)
            } footer: {
                Text(KMR.t("I controlli leggono solo le impostazioni e non chiedono mai la password. Alcune correzioni la chiedono: lo trovi scritto sul pulsante.",
                           "The checks only read settings and never ask for a password. Some fixes do: the button says so."))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Summary

    private var summary: some View {
        let score = SecurityChecklist.score(model.results)
        let fails = model.results.filter { $0.state == .fail }.count
        let warnings = model.results.filter { $0.state == .warning }.count
        let color: Color = score >= 85 ? KMR.green : score >= 60 ? KMR.orange : KMR.red
        return Section {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(color.opacity(0.18), lineWidth: 8)
                    Circle().trim(from: 0, to: Double(score) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(score)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(score)))
                }
                .frame(width: 64, height: 64)
                .animation(.smooth, value: score)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(KMR.t("Punteggio \(score) su 100", "Score \(score) out of 100"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(fails == 0 && warnings == 0 ? KMR.t("Il Mac è ben protetto", "Your Mac is well protected")
                         : fails > 0 ? KMR.t("Da sistemare: \(fails)", "To fix: \(fails)")
                         : KMR.t("Da migliorare: \(warnings)", "Could be better: \(warnings)"))
                        .font(.headline)
                    Text(KMR.t("Punteggio di sicurezza: \(score) su 100 · Controlli: \(model.results.count)",
                               "Security score: \(score) out of 100 · Checks: \(model.results.count)"))
                        .font(.callout).foregroundStyle(.secondary)
                    if fails > 0 && warnings > 0 {
                        Text(KMR.t("Da migliorare: \(warnings)", "Could be better: \(warnings)")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.checking { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Rows

    private func tint(_ state: SecurityCheckState) -> Color {
        switch state {
        case .pass: KMR.green
        case .warning: KMR.orange
        case .fail: KMR.red
        case .info: .blue
        case .unknown: KMR.gray
        }
    }

    private func stateSymbol(_ state: SecurityCheckState) -> String {
        switch state {
        case .pass: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .fail: "xmark.circle.fill"
        case .info: "info.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    @ViewBuilder private func row(_ result: SecurityCheckResult) -> some View {
        let isOpen = expanded.contains(result.kind)
        Button {
            withAnimation(.smooth(duration: 0.25)) {
                if isOpen { expanded.remove(result.kind) } else { expanded.insert(result.kind) }
            }
        } label: {
            HStack(spacing: 10) {
                IconTile(symbol: result.kind.symbol, color: tint(result.state), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.kind.title)
                    Text([result.status, result.note].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Label(result.state.label, systemImage: stateSymbol(result.state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint(result.state))
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen { SecurityGuideView(result: result, model: model) }
    }
}

private struct SecurityGuideView: View {
    let result: SecurityCheckResult
    let model: SecurityCheckModel
    @State private var copied = false
    @State private var confirmFix = false

    var body: some View {
        let guide = SecurityChecklist.guide(for: result.kind)
        VStack(alignment: .leading, spacing: 8) {
            Text(guide.why).font(.callout).foregroundStyle(.secondary)
            if result.needsAttention || result.state == .unknown || result.state == .info {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step)
                        }
                        .font(.callout)
                    }
                }
            }
            HStack(spacing: 8) {
                if let command = guide.command, result.needsAttention {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button(copied ? KMR.t("Copiato", "Copied") : KMR.t("Copia", "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                if guide.adminFix != nil, result.needsAttention {
                    Button(KMR.t("Risolvi (richiede la password)…", "Fix (asks for password)…")) { confirmFix = true }
                        .controlSize(.small)
                        .confirmationDialog(KMR.t("Correggere «\(result.kind.title)»?", "Fix “\(result.kind.title)”?"), isPresented: $confirmFix) {
                            Button(KMR.t("Correggi", "Fix")) { Task { await model.adminFix(result.kind) } }
                        } message: {
                            Text(KMR.t("macOS ti chiederà la password di amministratore per cambiare questa impostazione.",
                                       "macOS will ask for your administrator password to change this setting."))
                        }
                }
                if let pane = guide.paneURL, let url = URL(string: pane) {
                    Button(KMR.t("Apri Impostazioni", "Open Settings")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.leading, 36)
        .padding(.vertical, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
