import SessionCore

/// The names of the 省データ choices (docs/changes/2026-10-25-data-saver.md).
enum DataSaverLabel {
    static func text(_ policy: DataSaverPolicy) -> String {
        switch policy {
        case .automatic: return String(localized: "自動（モバイル回線・低データモードで有効）")
        case .always: return String(localized: "常に")
        case .never: return String(localized: "使わない")
        }
    }
}
