import SessionCore

/// What the pickers call each stream quality.
enum StreamQualityLabel {
    static func text(_ quality: StreamQuality) -> String {
        switch quality {
        case .automatic: return String(localized: "自動（モバイル回線では低画質）")
        case .high: return String(localized: "高画質（60fps）")
        case .balanced: return String(localized: "標準（30fps）")
        case .low: return String(localized: "低画質・省データ（15fps）")
        }
    }
}
