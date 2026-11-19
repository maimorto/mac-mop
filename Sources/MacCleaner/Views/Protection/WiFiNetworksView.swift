import SwiftUI
import MacCleanerKit

struct WiFiNetworksView: View {
    @AppStorage("removeBackgroundColors") private var removeBackgroundColors = false
    @State private var networks: [PreferredWiFiNetwork] = []
    @State private var selected: Set<PreferredWiFiNetwork.ID> = []
    @State private var isLoading = true
    @State private var isForgetting = false
    @State private var errorMessage: String?
    @State private var pendingForget: [PreferredWiFiNetwork]?
    private let client = PreferredWiFiClient.live()
    @State private var currentSSID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("已保存的 Wi-Fi", "Saved Wi-Fi", "Сохранённые сети Wi-Fi"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr(
                        "移除不再使用的已保存网络，减少被追踪的可能。需要管理员权限。",
                        "Remove saved networks you no longer use to shrink your tracking surface. Administrator access is required.",
                        "Удаляйте сохранённые сети, которыми больше не пользуетесь — так меньше данных для отслеживания. Нужны права администратора."
                    ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label(L10n.tr("刷新", "Refresh", "Обновить"), systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isForgetting)
                .help(L10n.tr("重新读取已保存的网络", "Reload saved networks", "Заново прочитать сохранённые сети"))

                Button(L10n.tr("忘记所选", "Forget Selected", "Забыть выбранные")) {
                    pendingForget = selectedNetworks
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selected.isEmpty || isLoading || isForgetting)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                            .tint(.primary)
                        Text(L10n.tr("正在读取已保存的网络…", "Reading saved networks…", "Чтение сохранённых сетей…"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let errorMessage, networks.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text(errorMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                } else if networks.isEmpty {
                    VStack {
                        Spacer()
                        Text(L10n.tr("没有已保存的 Wi-Fi 网络", "No saved Wi-Fi networks", "Нет сохранённых сетей Wi-Fi"))
                            .foregroundStyle(.tertiary)
                            .font(.body)
                        Spacer()
                    }
                } else {
                    List(networks) { net in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(net.id) },
                                set: { on in
                                    if on { selected.insert(net.id) }
                                    else { selected.remove(net.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            Image(systemName: "wifi")
                                .foregroundStyle(.secondary)
                                .font(.callout)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(net.ssid)
                                    .font(.body.weight(.medium))
                                if net.ssid == currentSSID {
                                    Text(KMR.t("Connesso ora", "Connected now"))
                                        .font(.caption)
                                        .foregroundStyle(KMR.green)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                }
            }
            .kmrGroupedBox()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task {
            await reload()
            let r = await Shell.run("/usr/sbin/ipconfig", ["getsummary", "en0"], timeout: 5)
            currentSSID = r.output.split(separator: "\n").first { $0.contains(" SSID : ") }
                .map { String($0.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) }
        }
        .respondsToModuleShortcuts(onScan: { Task { await reload() } }, canScan: !isLoading && !isForgetting)
        .alert(
            L10n.tr("忘记所选网络？", "Forget selected networks?", "Забыть выбранные сети?"),
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { nets in
            Button(L10n.tr("取消", "Cancel", "Отмена"), role: .cancel) { pendingForget = nil }
            Button(L10n.tr("忘记", "Forget", "Забыть"), role: .destructive) {
                let captured = nets
                pendingForget = nil
                Task { await forget(captured) }
            }
        } message: { nets in
            Text(L10n.tr(
                "将从这台 Mac 移除 \(nets.count) 个已保存的 Wi-Fi 网络。macOS 会要求管理员权限。正在使用的网络被移除后可能断开连接。",
                "Saved Wi-Fi networks to remove from this Mac: \(nets.count). macOS will ask for administrator access. Forgetting the network you are on may disconnect you.",
                "С этого Mac будет удалено \(nets.count) \(L10n.russianPlural(nets.count, one: "сохранённая сеть Wi-Fi", few: "сохранённые сети Wi-Fi", many: "сохранённых сетей Wi-Fi")). macOS запросит права администратора. Если забыть текущую сеть, соединение может оборваться."
            ))
        }
        .alert(L10n.tr("已保存的 Wi-Fi", "Saved Wi-Fi", "Сохранённые сети Wi-Fi"),
               isPresented: Binding(get: { errorMessage != nil && !networks.isEmpty },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button(L10n.tr("好", "OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var selectedNetworks: [PreferredWiFiNetwork] {
        networks.filter { selected.contains($0.id) }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        let result = await client.listNetworks()
        switch result {
        case .success(let list):
            networks = list
            selected = selected.intersection(Set(list.map(\.id)))
        case .failure(let error):
            networks = []
            selected = []
            errorMessage = error.localizedMessage
        }
        isLoading = false
    }

    private func forget(_ nets: [PreferredWiFiNetwork]) async {
        guard !isForgetting else { return }
        isForgetting = true
        let result = await client.forget(nets)
        switch result {
        case .success:
            selected.subtract(nets.map(\.id))
            await reload()
        case .failure(let error):
            if error != .adminCancelled {
                errorMessage = error.localizedMessage
            }
            await reload()
        }
        isForgetting = false
    }
}
