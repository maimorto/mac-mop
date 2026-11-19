import Foundation

public enum FileSizeFormatter {
    /// Sizes in the chosen interface language ("0 KB", never "Zero KB"),
    /// not the system one: decimal separator and unit names follow the app.
    public static func format(_ bytes: UInt64) -> String { format(Int64(clamping: bytes)) }

    public static func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(UIText.locale))
    }

    public static func shortFormat(_ bytes: UInt64) -> (value: String, unit: String) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = false
        formatter.allowsNonnumericFormatting = false
        let value = formatter.string(fromByteCount: Int64(bytes))

        let unitFormatter = ByteCountFormatter()
        unitFormatter.countStyle = .file
        unitFormatter.includesCount = false
        let unit = unitFormatter.string(fromByteCount: Int64(bytes))

        return (value, unit)
    }
}
