import SwiftUI

/// What the app cannot do on iPadOS/iOS and what to do instead. The source
/// text is docs/help-limitations.md; change both together.
struct HelpView: View {
    var body: some View {
        List {
            Section {
                row("Command+Tab", "App 切り替えに使われます。Win+Tab はキーバーの Win を押してから Tab。")
                row("Command+Space", "Spotlight に使われます。Win+Space はキーバーの Win を押してから Space。")
                row("Command+H", "ホーム画面に使われます。Win+H はキーバーの Win を押してから H。")
                row("Globe（地球儀）キー", "iPadOS のショートカットに使われ、Windows へは送りません。")
                row("Control+Space", "iPadOS の入力切替に設定されていると届きません。キーバーの Ctrl を押してから Space。")
                row("Caps Lock", "iPadOS の「ハードウェアキーボード」設定で Caps Lock による入力切替がオンだと、英字入力の切替に使われます。")
                row("Ctrl+Alt+Del", "RDP では Windows がセキュリティ画面を出しません。代わりにキーバーで Ctrl と Alt を押してから End（Ctrl+Alt+End）。")
            } header: {
                Text("iPadOS が先に使うキー")
            } footer: {
                Text("iPad の Command キーは Windows キーとして送るため、Windows キーを含むショートカットの一部が届きません。キーバーの修飾キーは 1 回押すと次の 1 キーだけ、2 回押すと固定、3 回目で解除です。")
            }

            Section {
                Text("別のアプリに切り替える、ホーム画面に戻る、画面をロックすると、押していたキーとボタンは離され、音声は止まります。")
                Text("しばらくすると OS が接続を閉じることがあります。戻ったときに切断されていたら「再接続」を押してください。RDP の切断はサインアウトではないので、同じデスクトップに戻ります。")
                Text("入力と音声は、表に出ているセッションだけに届きます。")
            } header: {
                Text("バックグラウンドに移ったとき")
            }

            Section {
                Text("Windows の「設定 > 時刻と言語 > 言語と地域」で日本語の「言語のオプション」を開き、Microsoft IME の「キーボード オプション > キーとタッチのカスタマイズ」で「キーの割り当て」をオンにし、無変換キーを「IME-オフ」、変換キーを「IME-オン」にします。サインインし直すと効きます。")
            } header: {
                Text("英数/かなで Windows の IME を切り替える")
            } footer: {
                Text("英数は無変換、かなは変換として送ります。")
            }
        }
        .navigationTitle("送れないキーとバックグラウンド")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("help-screen")
    }

    private func row(_ key: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
