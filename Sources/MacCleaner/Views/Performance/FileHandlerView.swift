import SwiftUI
import AppKit
import MacCleanerKit

struct FileHandlerView: View {
    @StateObject private var viewModel = FileHandlerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: search + restore button
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField(L10n.tr("搜索文件类型或应用...", "Search file type or app...", "Поиск по типу файла или приложению..."),
                          text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(action: {
                    viewModel.loadBackups()
                    viewModel.showRestoreSheet = true
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("版本历史", "Version history", "История версий"))
                Button(action: { viewModel.loadHandlers() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("刷新", "Refresh", "Обновить"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                    .tint(.primary)
                Spacer()
            } else if viewModel.handlers.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("没有自定义的文件打开方式", "No custom file associations", "Нет пользовательских связей типов файлов"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if viewModel.filteredHandlers.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("没有找到匹配的结果", "No matching results", "Совпадений не найдено"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(viewModel.filteredHandlers) { handler in
                        HandlerRowView(
                            handler: handler,
                            appInfo: viewModel.getAppInfo(for: handler),
                            onDelete: { viewModel.deleteHandler(handler) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $viewModel.showRestoreSheet) {
            restoreSheet
        }
        .alert(L10n.tr("错误", "Error", "Ошибка"), isPresented: $viewModel.showError) {
            Button("OK") { viewModel.showError = false }
        } message: {
            Text(viewModel.errorMessage ?? L10n.tr("发生未知错误", "An unknown error occurred", "Произошла неизвестная ошибка"))
        }
        .onAppear { viewModel.loadHandlers() }
    }

    // MARK: - Restore Sheet

    private var restoreSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("还原版本", "Restore Version", "Восстановить версию"))
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.showRestoreSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(KMR.t("Chiudi (Esc)", "Close (Esc)"))
                .accessibilityLabel(KMR.t("Chiudi", "Close"))
            }
            .padding()

            Divider()

            if viewModel.backups.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("没有可用的备份", "No backups available", "Нет доступных резервных копий"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List {
                    ForEach(Array(viewModel.backups.enumerated()), id: \.offset) { _, url in
                        BackupRowView(
                            url: url,
                            isRestoring: viewModel.isRestoring,
                            onRestore: { viewModel.restoreBackup(from: url) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 320)
    }
}

// MARK: - Backup Row

private struct BackupRowView: View {
    let url: URL
    let isRestoring: Bool
    let onRestore: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.body.weight(.medium))
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRestore) {
                Text(L10n.tr("还原", "Restore", "Восстановить"))
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(isRestoring)
        }
        .padding(.vertical, 2)
    }

    private var formattedDate: String {
        // Filename: launchservices-2026-06-26T11_12_26+08_00.plist
        // Underscores were originally colons (filesystem-safe encoding).
        let isoStr = url.lastPathComponent
            .replacingOccurrences(of: "launchservices-", with: "")
            .replacingOccurrences(of: ".plist", with: "")
            .replacingOccurrences(of: "_", with: ":")
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFmt.date(from: isoStr) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .medium
            return display.string(from: date)
        }
        return url.lastPathComponent
    }
}

// MARK: - Row View

private struct HandlerRowView: View {
    let handler: HandlerEntry
    let appInfo: (name: String, icon: NSImage)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // App Icon
            if let info = appInfo {
                Image(nsImage: info.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "app.dashed")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
            }

            // File Type
            VStack(alignment: .leading, spacing: 2) {
                Text(handler.fileTypeDescription)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                if let ct = handler.contentType {
                    Text("UTI: \(ct)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if handler.urlScheme != nil {
                    Text(L10n.tr("URL Scheme", "URL Scheme", "URL-схема"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // App Name
            if let info = appInfo {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(info.name)
                        .font(.body)
                    if let bid = handler.appBundleIdentifier {
                        Text(bid)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(L10n.tr("未知应用", "Unknown app", "Неизвестное приложение"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("删除此关联（自动备份当前版本）", "Remove (auto-backup created)", "Удалить связь (резервная копия создастся автоматически)"))
            .accessibilityLabel(L10n.tr("删除此关联（自动备份当前版本）", "Remove (auto-backup created)", "Удалить связь (резервная копия создастся автоматически)"))
        }
        .padding(.vertical, 2)
    }
}
