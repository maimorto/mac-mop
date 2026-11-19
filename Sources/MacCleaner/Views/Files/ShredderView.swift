import SwiftUI
import MacCleanerKit

struct ShredderView: View {
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @State private var filesToShred: [URL] = []
    @State private var eraseMode: SecureEraser.EraseMode = .standard
    @State private var isProcessing = false
    @State private var result: SecureEraser.EraseResult?
    @State private var confirmShred = false
    @State private var dropTargeted = false

    private let eraser = SecureEraser()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("文件粉碎", "Shredder", "Уничтожение файлов"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("安全擦除文件，使其无法恢复", "Securely erase files beyond recovery", "Безопасно стирайте файлы без возможности восстановления"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Spacer()

            if let result {
                VStack(spacing: 16) {
                    Image(systemName: result.errors.isEmpty
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(result.errors.isEmpty ? Color.primary : Color.orange)
                    Text(L10n.tr("已擦除 \(result.erasedCount) 个文件", "\(result.erasedCount) files erased", "\(result.erasedCount) \(L10n.russianPlural(result.erasedCount, one: "файл удалён", few: "файла удалено", many: "файлов удалено"))"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(FileSizeFormatter.format(result.totalSize))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    if let firstError = result.errors.first?.1 {
                        Text(firstError)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .textSelection(.enabled)

                        if result.errors.count > 1 {
                            Text(L10n.tr(
                                "以及另外 \(result.errors.count - 1) 个错误",
                                "Other errors: \(result.errors.count - 1)",
                                "И ещё \(result.errors.count - 1) \(L10n.russianPlural(result.errors.count - 1, one: "ошибка", few: "ошибки", many: "ошибок"))"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(L10n.tr("完成", "Done", "Готово")) {
                        self.result = nil
                        filesToShred = []
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
            } else if isProcessing {
                ProgressView(L10n.tr("正在粉碎文件...", "Shredding files...", "Уничтожение файлов..."))
                    .foregroundStyle(.primary)
                    .tint(.primary)
            } else if filesToShred.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "scissors")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text(L10n.tr("将文件拖放到此处进行粉碎", "Drop files here to shred them", "Перетащите сюда файлы для уничтожения"))
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Button(L10n.tr("选择文件", "Select Files", "Выбрать файлы")) {
                        selectFiles()
                    }
                    .buttonStyle(SuperEllipseButtonStyle(
                        gradient: ModuleTheme.files.gradient,
                        size: CGSize(width: 140, height: 44)
                    ))

                    modePicker
                        .padding(.top, 8)
                }
            } else {
                VStack(spacing: 16) {
                    Text(L10n.tr("已选择 \(filesToShred.count) 个文件", "\(filesToShred.count) files selected", "\(L10n.russianPlural(filesToShred.count, one: "Выбран", few: "Выбрано", many: "Выбрано")) \(filesToShred.count) \(L10n.russianPlural(filesToShred.count, one: "файл", few: "файла", many: "файлов"))"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    List(filesToShred, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc")
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                filesToShred.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(KMR.t("Togli dall'elenco", "Remove from the list"))
                            .accessibilityLabel(KMR.t("Togli \(url.lastPathComponent) dall'elenco", "Remove \(url.lastPathComponent) from the list"))
                        }
                        .help(url.path(percentEncoded: false))
                        .contextMenu {
                            FileContextMenuItems(url: url)
                            Divider()
                            Button(KMR.t("Togli dall'elenco", "Remove from the List")) { filesToShred.removeAll { $0 == url } }
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: 200)
                    .background {
                        if removeBackgroundColors { Color.clear }
                        else { Rectangle().fill(.ultraThinMaterial) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 40)

                    modePicker

                    HStack(spacing: 12) {
                        Button(KMR.t("Svuota elenco", "Clear List")) { filesToShred = [] }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        Button(KMR.t("Aggiungi…", "Add…")) { selectFiles(adding: true) }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        Button(L10n.tr("粉碎", "Shred", "Уничтожить")) {
                            confirmShred = true
                        }
                        .buttonStyle(SuperEllipseButtonStyle(
                            gradient: LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing),
                            size: CGSize(width: 140, height: 44)
                        ))
                    }
                }
                // Destructive and (except "Move to Trash") irreversible: always ask.
                .confirmationDialog(shredTitle, isPresented: $confirmShred, titleVisibility: .visible) {
                    Button(eraseMode == .standard ? KMR.t("Sposta nel Cestino", "Move to Trash") : KMR.t("Elimina per sempre", "Delete Forever"),
                           role: .destructive) { shred() }
                    Button(KMR.t("Annulla", "Cancel"), role: .cancel) {}
                } message: {
                    Text(eraseMode == .standard
                         ? KMR.t("Potrai recuperarli dal Cestino.", "You can get them back from the Trash.")
                         : KMR.t("Non si possono recuperare, nemmeno dal Cestino.", "They can't be recovered, not even from the Trash."))
                }
            }

            Spacer()
        }
        // Drop files or folders anywhere on the page.
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, result == nil, !isProcessing else { return false }
            filesToShred += files.filter { !filesToShred.contains($0) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var shredTitle: String {
        KMR.t("Distruggere \(filesToShred.count) elementi?", "Shred \(filesToShred.count) items?")
    }

    private var modePicker: some View {
        Picker(L10n.tr("模式", "Mode", "Режим"), selection: $eraseMode) {
            Text(L10n.tr("移到废纸篓", "Move to Trash", "В Корзину")).tag(SecureEraser.EraseMode.standard)
            Text(L10n.tr("永久删除", "Permanent Delete", "Безвозвратно")).tag(SecureEraser.EraseMode.permanent)
            Text(L10n.tr("安全擦除", "Secure Erase", "С перезаписью")).tag(SecureEraser.EraseMode.secure)
        }
        .pickerStyle(.segmented)
        // Hidden visually, kept for VoiceOver. Rendered inline, the label
        // gets width-starved by the fixed 360pt frame and wraps one letter
        // per line into a vertical "M o d e".
        .labelsHidden()
        .frame(width: 360)
    }

    private func selectFiles(adding: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            filesToShred = adding ? filesToShred + panel.urls.filter { !filesToShred.contains($0) } : panel.urls
        }
    }

    private func shred() {
        isProcessing = true
        Task {
            result = await eraser.erase(urls: filesToShred, mode: eraseMode)
            isProcessing = false
        }
    }
}
