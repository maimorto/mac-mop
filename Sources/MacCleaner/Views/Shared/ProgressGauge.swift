import SwiftUI
import MacCleanerKit

public struct SizeDisplay: View {
    let size: UInt64
    let label: String

    public init(size: UInt64, label: String = L10n.tr("待清理", "to clean up", "к очистке")) {
        self.size = size
        self.label = label
    }

    public var body: some View {
        let parts = FileSizeFormatter.shortFormat(size)
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.value)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text(parts.unit)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
