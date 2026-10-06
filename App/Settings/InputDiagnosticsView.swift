import SwiftUI
import InputCore

/// Counters from the focused session's keyboard arbiter, and the opt-in
/// trace of non-character keys. Nothing here can show what was typed.
struct InputDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment

    private var center: InputDiagnosticsCenter { environment.inputDiagnostics }

    var body: some View {
        Form {
            Section {
                Toggle("非文字キーを記録", isOn: Binding(
                    get: { center.isTraceRequested },
                    set: { center.setTraceRequested($0) }
                ))
                .accessibilityIdentifier("input-trace-toggle")
                if let end = center.traceEndsAt {
                    Text("\(end.formatted(date: .omitted, time: .shortened)) に自動で停止します")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("英数/かな、変換/無変換、修飾キーなど文字を生まないキーだけを、メモリ上に最大 \(InputDiagnostics.traceCapacity) 件記録します。保存も送信もしません。")
            }

            Section("結果") {
                ForEach(InputOutcome.allCases, id: \.self) { outcome in
                    LabeledContent(Self.label(outcome), value: "\(center.latest.count(outcome))")
                }
            }

            Section("一括解放") {
                ForEach(InputReleaseReason.allCases, id: \.self) { reason in
                    LabeledContent(Self.label(reason), value: "\(center.latest.count(reason))")
                }
            }

            if !center.latest.trace.isEmpty {
                Section("記録") {
                    ForEach(center.latest.trace.reversed(), id: \.sequence) { entry in
                        HStack {
                            Text(Self.keyName(entry.usage)).font(.body.monospaced())
                            Text(entry.transition == .down ? "↓" : "↑")
                            Spacer()
                            Text(entry.source == .uiKit ? "UIKit" : "GC")
                                .foregroundStyle(.secondary)
                            Text(Self.label(entry.outcome))
                                .foregroundStyle(entry.outcome == .forwarded ? .primary : Color.orange)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("入力診断")
        .accessibilityIdentifier("input-diagnostics-screen")
    }

    static func label(_ outcome: InputOutcome) -> String {
        switch outcome {
        case .forwarded: return "送信"
        case .duplicate: return "重複 down"
        case .orphan: return "対応のない up"
        case .otherSource: return "別経路（未採用）"
        case .quarantined: return "解放後の押下"
        case .gated: return "入力停止中"
        }
    }

    static func label(_ reason: InputReleaseReason) -> String {
        switch reason {
        case .gateClosed: return "入力停止"
        case .focusLost: return "フォーカス喪失"
        case .pressesCancelled: return "押下キャンセル"
        case .keyboardDisconnected: return "キーボード切断"
        case .sourcePolicyChanged: return "経路設定の変更"
        case .surfaceRemoved: return "画面終了"
        }
    }

    static func keyName(_ usage: UInt16) -> String {
        switch usage {
        case 0x90: return "かな"
        case 0x91: return "英数"
        case 0x87: return "ろ"
        case 0x88: return "カタカナ"
        case 0x89: return "¥"
        case 0x8A: return "変換"
        case 0x8B: return "無変換"
        case 0x94: return "半/全"
        case 0x39: return "CapsLock"
        case 0xE0: return "L-Ctrl"
        case 0xE1: return "L-Shift"
        case 0xE2: return "L-Opt"
        case 0xE3: return "L-Cmd"
        case 0xE4: return "R-Ctrl"
        case 0xE5: return "R-Shift"
        case 0xE6: return "R-Opt"
        case 0xE7: return "R-Cmd"
        default: return String(format: "0x%02X", usage)
        }
    }
}
