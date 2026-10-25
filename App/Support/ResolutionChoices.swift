import SwiftUI
import SessionCore

/// What every resolution picker offers: 自動, then the fixed sizes under
/// 横長 and 縦長 (docs/changes/2026-10-25-resolution-presets.md).
enum ResolutionChoices {
    static let groups: [(heading: String?, options: [ResolutionPolicy])] = [
        (nil, [.adaptive]),
        (String(localized: "横長"), ResolutionPolicy.landscapePresets),
        (String(localized: "縦長"), ResolutionPolicy.portraitPresets),
    ]
}

/// The rows of a picker whose selection is the policy itself.
struct ResolutionPickerRows: View {
    var body: some View {
        ForEach(ResolutionChoices.groups.indices, id: \.self) { index in
            let group = ResolutionChoices.groups[index]
            if let heading = group.heading {
                Section(heading) { rows(group.options) }
            } else {
                rows(group.options)
            }
        }
    }

    private func rows(_ options: [ResolutionPolicy]) -> some View {
        ForEach(options, id: \.self) { policy in
            Text(Formatting.resolutionLabel(policy)).tag(policy)
        }
    }
}
