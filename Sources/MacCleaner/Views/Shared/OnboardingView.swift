import SwiftUI
import MacCleanerKit

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(KMR.t("Chiudi (Esc)", "Close (Esc)"))
                .accessibilityLabel(KMR.t("Chiudi", "Close"))
            }
            .padding()

            Spacer()

            // Step content
            TabView(selection: $currentStep) {
                welcomeStep.tag(0)
                fdaStep.tag(1)
                featuresStep.tag(2)
                readyStep.tag(3)
            }
            .tabViewStyle(.automatic)

            Spacer()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button(L10n.tr("返回", "Back", "Назад")) { withAnimation { currentStep -= 1 } }
                        .buttonStyle(.bordered)
                }

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < 3 {
                    Button(L10n.tr("下一步", "Next", "Далее")) { withAnimation { currentStep += 1 } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L10n.tr("开始使用", "Get Started", "Начать")) { isPresented = false }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        // Keep the navigation visible; the permissions step scrolls inside
        // the available space for longer translations and smaller displays.
        .frame(width: 600)
        .frame(minHeight: 480, idealHeight: 540, maxHeight: 620)
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "leaf.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text(L10n.tr("欢迎使用 \(MCConstants.appName)", "Welcome to \(MCConstants.appName)", "Добро пожаловать в \(MCConstants.appName)"))
                .font(.largeTitle.weight(.bold))

            Text(L10n.tr("以开源方式让你的 Mac 保持干净、快速和安全。", "The open-source way to keep your Mac clean, fast, and secure.", "Инструмент с открытым исходным кодом для чистоты, быстродействия и безопасности вашего Mac."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    private var fdaStep: some View {
        CleanupPermissionsView()
    }

    private var featuresStep: some View {
        VStack(spacing: 20) {
            Text(L10n.tr("\(MCConstants.appName) 可以做什么", "What \(MCConstants.appName) Can Do", "Возможности \(MCConstants.appName)"))
                .font(.title.weight(.bold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                featureCard("trash.circle", L10n.tr("系统垃圾", "System Junk", "Системный мусор"), L10n.tr("清理缓存、日志和临时文件", "Clean caches, logs, and temp files", "Очистка кэшей, журналов и временных файлов"))
                featureCard("shield.lefthalf.filled", L10n.tr("恶意软件扫描", "Malware Scan", "Проверка на вредоносное ПО"), L10n.tr("检测并移除威胁", "Detect and remove threats", "Поиск и удаление угроз"))
                featureCard("xmark.app", L10n.tr("卸载器", "Uninstaller", "Удаление приложений"), L10n.tr("彻底移除应用", "Completely remove apps", "Полное удаление приложений"))
                featureCard("chart.pie", L10n.tr("空间透视", "Space Lens", "Карта диска"), L10n.tr("可视化磁盘使用情况", "Visualize disk usage", "Визуализация использования диска"))
                featureCard("plus.square.on.square", L10n.tr("重复文件", "Duplicates", "Дубликаты"), L10n.tr("查找重复文件", "Find duplicate files", "Поиск дубликатов"))
                featureCard("gauge.with.dots.needle.67percent", L10n.tr("性能", "Performance", "Производительность"), L10n.tr("优化你的 Mac", "Optimize your Mac", "Оптимизация Mac"))
            }
            .frame(maxWidth: 450)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text(L10n.tr("一切就绪！", "You're All Set!", "Всё готово!"))
                .font(.largeTitle.weight(.bold))

            Text(L10n.tr("点击“智能扫描”即可一键清理 Mac，也可以在侧边栏探索各个模块。", "Click Smart Scan to clean your Mac with one click, or explore individual modules in the sidebar.", "Нажмите «Умное сканирование», чтобы очистить Mac одним действием, или выберите отдельный модуль на боковой панели."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .foregroundStyle(.primary)
                .clipShape(Circle())
            Text(text)
                .font(.body)
        }
    }

    private func featureCard(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
