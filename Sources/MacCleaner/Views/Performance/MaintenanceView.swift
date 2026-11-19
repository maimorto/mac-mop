import SwiftUI
import MacCleanerKit

struct MaintenanceView: View {
    @State private var taskStates: [MaintenanceTask: TaskState] = [:]
    @State private var executor = MaintenanceExecutor()
    /// When non-nil, the confirmation alert is presented for this task.
    @State private var taskAwaitingConfirmation: MaintenanceTask?

    enum TaskState {
        case idle
        case running
        case completed(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                ForEach(MaintenanceTask.allCases.filter { $0.severity != .advanced }) { task in
                    taskRow(task)
                }
            } header: {
                Text(KMR.t("Operazioni sicure", "Safe tasks"))
            } footer: {
                HStack {
                    Text(KMR.t("Non cambiano nulla di importante e si possono ripetere quando vuoi.",
                               "They change nothing important and can be repeated anytime."))
                    Spacer()
                    Button(L10n.tr("运行安全任务", "Run Safe Tasks", "Запустить безопасные задачи")) { runSafeTasks() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Section {
                ForEach(MaintenanceTask.allCases.filter { $0.severity == .advanced }) { task in
                    taskRow(task)
                }
            } header: {
                Text(KMR.t("Operazioni avanzate", "Advanced tasks"))
            } footer: {
                Text(KMR.t("Ricostruiscono indici di sistema e possono rallentare il Mac per qualche ora. Ognuna chiede conferma.",
                           "They rebuild system indexes and can slow your Mac down for a few hours. Each one asks for confirmation."))
            }
        }
        .formStyle(.grouped)
        .alert(
            L10n.tr("运行 \(taskAwaitingConfirmation?.title ?? "")？", "Run \(taskAwaitingConfirmation?.title ?? "")?", "Запустить \(taskAwaitingConfirmation?.title ?? "")?"),
            isPresented: Binding(
                get: { taskAwaitingConfirmation != nil },
                set: { if !$0 { taskAwaitingConfirmation = nil } }
            ),
            presenting: taskAwaitingConfirmation
        ) { task in
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) {
                taskAwaitingConfirmation = nil
            }
            Button(L10n.tr("仍要运行", "Run Anyway", "Всё равно запустить"), role: .destructive) {
                let captured = task
                taskAwaitingConfirmation = nil
                runTask(captured)
            }
        } message: { task in
            Text(task.sideEffects)
        }
    }

    private func taskRow(_ task: MaintenanceTask) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: task.icon, color: task.severity == .advanced ? KMR.orange : Color(nsColor: .systemBlue), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                if case .failed(let message) = taskStates[task] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(KMR.orange)
                        .lineLimit(2)
                } else {
                    Text(task.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            statusView(for: task)
                .transition(.opacity.combined(with: .scale))
            Button(KMR.t("Esegui", "Run")) { didTapRun(task) }
                .disabled(isRunning(task))
                .help(task.severity == .advanced
                      ? L10n.tr("可能带来持续数小时的影响——将打开确认窗口", "Has multi-hour side effects — opens a confirmation", "Может влиять на систему несколько часов — откроется окно подтверждения")
                      : L10n.tr("运行此任务", "Run this task", "Запустить эту задачу"))
        }
        .animation(.smooth, value: isRunning(task))
    }

    @ViewBuilder
    private func statusView(for task: MaintenanceTask) -> some View {
        switch taskStates[task] {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.primary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        case .idle, .none:
            EmptyView()
        }
    }

    private func isRunning(_ task: MaintenanceTask) -> Bool {
        if case .running = taskStates[task] { return true }
        return false
    }

    /// Routes through the severity check: safe tasks run immediately,
    /// advanced tasks pop the confirmation alert first.
    private func didTapRun(_ task: MaintenanceTask) {
        switch task.severity {
        case .safe:
            runTask(task)
        case .advanced:
            taskAwaitingConfirmation = task
        }
    }

    private func executeAndStore(_ task: MaintenanceTask) async {
        taskStates[task] = .running
        let result = await executor.execute(task)
        if result.success {
            taskStates[task] = .completed(result.output)
        } else {
            taskStates[task] = .failed(result.error ?? L10n.tr("未知错误", "Unknown error", "Неизвестная ошибка"))
        }
    }

    private func runTask(_ task: MaintenanceTask) {
        Task { await executeAndStore(task) }
    }

    /// Bulk button runs ONLY safe tasks, and runs them SEQUENTIALLY. Several
    /// safe tasks need admin (purge, periodic). Sequential order keeps the
    /// UI status per-task; the in-process AppleScript runner then reuses the
    /// cached admin password so the user types it once.
    private func runSafeTasks() {
        let safeTasks = MaintenanceTask.allCases.filter { $0.severity == .safe }
        Task {
            for task in safeTasks {
                await executeAndStore(task)
            }
        }
    }
}
