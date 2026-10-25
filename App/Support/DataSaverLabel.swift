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

    /// Whether it is on right now, and why.
    static func status(policy: DataSaverPolicy, active: Bool, constrained: Bool) -> String {
        switch (policy, active) {
        case (.automatic, true): return String(localized: "いまは有効です（モバイル回線または低データモードのため）。音声を圧縮し、Retina の画面を半分の画素数で送ります。")
        case (.automatic, false): return String(localized: "いまは無効です（モバイル回線・低データモードになると有効になります）。")
        case (_, true): return String(localized: "有効です。音声を圧縮し、Retina の画面を半分の画素数で送ります。")
        case (_, false): return String(localized: "無効です。")
        }
    }
}
