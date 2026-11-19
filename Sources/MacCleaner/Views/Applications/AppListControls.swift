import SwiftUI
import AppKit
import MacCleanerKit

/// Search field + "Sort by" menu + "Filters" menu for the app lists, laid
/// out like a Finder toolbar row. Labels never wrap: menus size to their
/// title, and on narrow windows the search field moves to its own line.
struct AppListControls<Trailing: View>: View {
    @Binding var options: AppListOptions
    @Binding var search: String
    /// Offer the "not opened for…" filter (Unused Apps has its own period).
    var showsIdleFilter = true
    var showsAppleFilter = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchField.frame(minWidth: 180, idealWidth: 260, maxWidth: .infinity)
                menus
                trailing().fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                searchField.frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    menus
                    Spacer(minLength: 0)
                    trailing().fixedSize()
                }
            }
        }
    }

    private var searchField: some View {
        NativeSearchField(text: $search, prompt: KMR.t("Cerca per nome, sviluppatore o ID", "Search by name, developer or ID"))
            .frame(height: 24)
    }

    private var menus: some View {
        HStack(spacing: 8) {
            sortMenu
            filterMenu
        }
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Picker(KMR.t("Ordina per", "Sort by"), selection: Binding(get: { options.sort }, set: { options.setSort($0) })) {
                ForEach(AppSortKey.allCases) { key in
                    Label(key.label, systemImage: key.symbol).tag(key)
                }
            }
            .pickerStyle(.inline)
            Section {
                Picker(KMR.t("Ordine", "Order"), selection: $options.ascending) {
                    Text(options.sort.orderLabel(ascending: options.sort.defaultAscending)).tag(options.sort.defaultAscending)
                    Text(options.sort.orderLabel(ascending: !options.sort.defaultAscending)).tag(!options.sort.defaultAscending)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(KMR.t("Ordina per: \(options.sort.label)", "Sort by: \(options.sort.label)"), systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .help(options.sort.orderLabel(ascending: options.ascending))
    }

    private var filterMenu: some View {
        let count = options.activeFilterCount
        return Menu {
            if showsAppleFilter {
                Toggle(KMR.t("Nascondi le app di Apple", "Hide Apple apps"), isOn: $options.hideApple)
            }
            Picker(KMR.t("Dimensione", "Size"), selection: $options.size) {
                ForEach(AppSizeFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Section(KMR.t("Provenienza", "Source")) {
                ForEach(AppSourceFilter.allCases) { source in
                    Toggle(source.label, isOn: Binding(
                        get: { options.sources.contains(source) },
                        set: { on in if on { options.sources.insert(source) } else { options.sources.remove(source) } }))
                }
                Toggle(KMR.t("Solo Intel (usano Rosetta)", "Intel only (use Rosetta)"), isOn: $options.intelOnly)
            }
            if showsIdleFilter {
                Picker(KMR.t("Ultimo utilizzo", "Last opened"), selection: $options.idle) {
                    ForEach(AppIdleFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            }
            if count > 0 {
                Divider()
                Button(KMR.t("Azzera i filtri", "Clear filters")) { options = options.clearingFilters }
            }
        } label: {
            Label(count > 0 ? KMR.t("Filtri: \(count)", "Filters: \(count)") : KMR.t("Filtri", "Filters"),
                  systemImage: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
    }
}

extension AppListControls where Trailing == EmptyView {
    init(options: Binding<AppListOptions>, search: Binding<String>, showsIdleFilter: Bool = true, showsAppleFilter: Bool = true) {
        self.init(options: options, search: search, showsIdleFilter: showsIdleFilter, showsAppleFilter: showsAppleFilter) { EmptyView() }
    }
}

/// "Showing 12 of 180 · Clear filters" under the controls when something is hidden.
struct AppListFilterSummary: View {
    let shown: Int
    let total: Int
    let hasFilters: Bool
    let clear: () -> Void

    var body: some View {
        if shown != total || hasFilters {
            HStack(spacing: 8) {
                Text(KMR.t("Mostrate: \(shown) su \(total)", "Showing: \(shown) of \(total)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if hasFilters {
                    Button(KMR.t("Azzera i filtri", "Clear filters"), action: clear)
                        .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .lineLimit(1)
        }
    }
}

/// AppKit's search field: magnifier, clear button, Esc to clear.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.controlSize = .regular
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Natural height only, even when offered more (Form rows, VStacks).
        field.setContentHuggingPriority(.required, for: .vertical)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        weak var field: NSSearchField?
        private var focusObserver: NSObjectProtocol?

        init(text: Binding<String>) {
            self.text = text
            super.init()
            // ⌘F (Edit › Find): the visible page's field takes focus.
            focusObserver = NotificationCenter.default.addObserver(
                forName: SearchFocusClaim.notification, object: nil, queue: nil) { [weak self] note in
                guard let claim = note.object as? SearchFocusClaim, !claim.claimed,
                      let field = self?.field, SearchFocusClaim.isVisible(field) else { return }
                claim.claimed = true
                field.window?.makeFirstResponder(field)
            }
        }

        deinit {
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Page header (title + subtitle on the left, controls on the right). When
/// the window is too narrow the controls move under the text instead of
/// squeezing labels into hyphenated fragments ("Perio-do").
struct AppsPageHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                titleBlock.frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity, alignment: .leading)
                controls().fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                controls().fixedSize()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

extension AppListFacts {
    /// "Opened 12 Mar 2025" / "Never opened (per Spotlight)" for row captions.
    static func lastOpenedText(_ date: Date?) -> String {
        guard let date else { return KMR.t("Ultima apertura sconosciuta", "Last opened: unknown") }
        let formatted = date.formatted(.dateTime.day().month(.abbreviated).year().locale(UIText.locale))
        return KMR.t("Aperta il \(formatted)", "Opened \(formatted)")
    }

    static func installedText(_ date: Date?) -> String {
        guard let date else { return KMR.t("Data di installazione sconosciuta", "Install date unknown") }
        let formatted = date.formatted(.dateTime.day().month(.abbreviated).year().locale(UIText.locale))
        return KMR.t("Installata il \(formatted)", "Installed \(formatted)")
    }
}
