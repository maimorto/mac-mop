import SwiftUI
import AppKit
import MacCleanerKit

/// Grouped results for the Duplicates module. Each set shows the copy we keep
/// (the "original", marked KEPT and with no checkbox — it can never be selected
/// for deletion) above its removable copies, which are pre-checked. The binding
/// only ever holds the URLs of removable copies, so the original is structurally
/// impossible to delete: it isn't in the list the cleaner operates on.
struct DuplicateGroupsList: View {
    let groups: [DuplicateDisplayGroup]
    @Binding var selectedItems: Set<URL>
    // Owned by the parent (DuplicatesView): this view is rebuilt through an
    // AnyView each time a checkbox toggles, which can reset local @State. Keep
    // the expand/collapse set upstream so groups don't fold on every click.
    @Binding var expanded: Set<UUID>

    /// One List row per element (header, kept original or copy) so the List
    /// stays lazy: a ForEach whose element expands to a variable number of
    /// rows makes SwiftUI build every group up front, which stalled the UI on
    /// scans with thousands of sets.
    private enum Row: Identifiable {
        case header(DuplicateDisplayGroup)
        case original(FileItem)
        case copy(FileItem)

        struct ID: Hashable { let kind: UInt8; let id: UUID }

        var id: ID {
            switch self {
            case .header(let g): ID(kind: 0, id: g.id)
            case .original(let f): ID(kind: 1, id: f.id)
            case .copy(let f): ID(kind: 2, id: f.id)
            }
        }
    }

    private var rows: [Row] {
        var out: [Row] = []
        out.reserveCapacity(groups.count)
        for group in groups {
            out.append(.header(group))
            guard expanded.contains(group.id) else { continue }
            out.append(.original(group.original))
            out.append(contentsOf: group.duplicates.map(Row.copy))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider().opacity(0.3)
            List(rows) { row in
                rowView(row)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .task {
            // Perf repro (KMR_REVIEW_EXPAND=all): open every set.
            if ProcessInfo.processInfo.environment["KMR_REVIEW_EXPAND"] == "all" { expanded = Set(groups.map(\.id)) }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .header(let group):
            DuplicateGroupHeaderRow(
                group: group,
                isExpanded: expanded.contains(group.id),
                allExtrasSelected: group.duplicates.allSatisfy { selectedItems.contains($0.url) },
                onToggleExpand: { toggleExpand(group.id) },
                onToggleAll: { toggleAll(group) }
            )
        case .original(let item):
            DuplicateOriginalRow(item: item)
        case .copy(let item):
            DuplicateCopyRow(item: item, isSelected: selectedItems.contains(item.url), onToggle: { toggle(item.url) })
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("每组都会保留一个副本，且永远不会被移除。", "One copy of every set is kept and can never be removed.", "В каждой группе сохраняется одна копия — удалить её нельзя."))
                    .font(.callout.weight(.medium))
                Text(L10n.tr("标记为“保留”的行受保护，只会删除勾选的副本。", "Rows marked KEPT are protected. Only the checked copies are deleted.", "Строки с меткой «ОСТАВЛЕНО» защищены. Удаляются только отмеченные копии."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(allExpanded ? L10n.tr("全部折叠", "Collapse all", "Свернуть все") : L10n.tr("全部展开", "Expand all", "Развернуть все")) {
                if allExpanded { expanded.removeAll() }
                else { expanded = Set(groups.map(\.id)) }
            }
            .buttonStyle(.link)
            .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var allExpanded: Bool {
        !groups.isEmpty && expanded.count == groups.count
    }

    private func toggleExpand(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) }
            else { expanded.insert(id) }
        }
    }

    private func toggle(_ url: URL) {
        if selectedItems.contains(url) { selectedItems.remove(url) }
        else { selectedItems.insert(url) }
    }

    /// Select-all / deselect-all for one set's removable copies. Never touches
    /// the original (it isn't in `duplicates`).
    private func toggleAll(_ group: DuplicateDisplayGroup) {
        let urls = Set(group.duplicates.map(\.url))
        if urls.isSubset(of: selectedItems) { selectedItems.subtract(urls) }
        else { selectedItems.formUnion(urls) }
    }
}

private struct DuplicateGroupHeaderRow: View {
    let group: DuplicateDisplayGroup
    let isExpanded: Bool
    let allExtrasSelected: Bool
    let onToggleExpand: () -> Void
    let onToggleAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? KMR.t("Nascondi le copie", "Hide the copies") : KMR.t("Mostra le copie", "Show the copies"))
            .accessibilityLabel(isExpanded ? KMR.t("Nascondi le copie", "Hide the copies") : KMR.t("Mostra le copie", "Show the copies"))

            // Select-all for this set's removable copies.
            Toggle(isOn: Binding(get: { allExtrasSelected }, set: { _ in onToggleAll() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            HStack(spacing: 8) {
                Image(systemName: "plus.square.on.square")
                    .foregroundStyle(.secondary)
                Text(group.original.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            Spacer()

            Text(L10n.tr("\(group.copyCount) 个副本", "\(group.copyCount) copies", "\(group.copyCount) \(L10n.russianPlural(group.copyCount, one: "копия", few: "копии", many: "копий"))"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text(L10n.tr("可节省 \(group.formattedWastedSpace)", "saves \(group.formattedWastedSpace)", "можно освободить \(group.formattedWastedSpace)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
        }
    }
}

private struct DuplicateOriginalRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.green)
                .frame(width: 20)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L10n.tr("保留", "KEPT", "ОСТАВЛЕНО"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(0.85)
        .contextMenu {
            FileContextMenuItems(url: item.url)
        }
    }
}

private struct DuplicateCopyRow: View {
    let item: FileItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Visual only — the whole row is the hit target (onTapGesture),
            // so hit-testing here is disabled to avoid a double toggle.
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .allowsHitTesting(false)
            .frame(width: 20)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.on.doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            FileContextMenuItems(url: item.url)
        }
    }
}
