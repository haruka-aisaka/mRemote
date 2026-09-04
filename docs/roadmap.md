# 実装ロードマップ

## 1. 進め方

最も不確実な FreeRDP の iOS build、Japanese scan code、描画/音声 bridge、複数セッションのメモリを先に実機で潰す。UI を作り込んだ後に native core の制約が判明しない順序にする。

期間ではなく exit criteria で phase を区切る。各 phase で未完の native resource、入力押下状態、秘密データが残らない teardown test を加える。

## 2. Phase 0 — Go/No-Go スパイク

### 成果物

- 固定 commit の FreeRDP/WinPR を生成する再現可能な build script
- device `arm64` と Simulator 向け静的 XCFramework
- opaque handle を使う最小 C bridge
- 1 枚の UIKit/Metal RDP surface を持つ技術 harness
- Windows 側 scan code 観測用 `KeyEcho`
- host/local IME mode を切り替える最小 `UITextInput` proxy harness
- 端末機種、OS build、キーボード機種/接続方式、iPadOS 関連設定を記録した入力基準環境
- dependency license 一覧/SBOM の原型

### 検証

1. NLA/TLS で実 Windows へ接続し、leaf/chain DER を `SecTrust` + SSL hostname policy で判定して challenge を扱える。
2. BGRA desktop update を Metal に表示し、1080p/4K の基礎値を測れる。
3. 英数→`0x7B`、かな→`0x79` の down/up を Windows 側で確認できる。
4. usage ごとに UIKit/GCKeyboard の送信元を固定し、遅延 secondary event でも二重送信しない。
5. 対象 press で `super.presses*` を呼ばず、iPadOS IME/入力ソース UI を起動しない (`KEY-IME-02`)。
6. ASCII capable proxy が host IME mode でローカル日本語 IME を抑止できる (`SFT-POC-01`)。
7. mouse 左右 click/drag/wheel の down/up/cancel を実機で lossless に取得でき、UIKit または GCMouse の単一送信経路として固定して送れる。
8. 全 add-in を静的 link し、`cliprdr`/`rdpsnd` SVC と `drdynvc` 上の `disp` DVC を negotiate して実データを往復できる。
9. `rdpsnd` backend が PCM だけを advertise し、wave confirm を含む callback 契約を確認できる。
10. 2〜3 session の framebuffer/renderer/codec/worker memory baseline を得る。
11. Release archive に private API、動的 plugin、不正 architecture がない。

### Gate

- FreeRDP を安全に停止/破棄できない、DER を authoritative trust 判定へ渡せない、必須 Japanese key event を送れない、または `KEY-IME-02` を満たせない場合は、その版/方式を採用しない。
- 版変更、bridge 修正、代替 RDP core 評価の順で再判断する。
- 合格後に FreeRDP version、codec/channel set、最低 OS を ADR として固定する。

## 3. Phase 1 — アプリ基盤と接続先

### 実装

- module/target 構成、DI、OSLog category
- `ConnectionProfile`、RDP payload、global settings、migration
- Keychain credential repository、trust repository
- 接続先一覧、空状態、追加/編集/複製/削除 sheet
- `RemoteSession` interface、SessionManager actor、FakeRemoteSession
- Settings と dependency licenses 画面

### Exit criteria

- fake session で一覧→接続→全画面→一覧復帰→切断の UI test が通る。
- password が profile store/log へ保存されない。
- schema v1 と migration test の土台がある。
- SSH session factory を将来登録できる依存方向になっている。

## 4. Phase 2 — 単一 RDP セッション

### 実装

- FreeRDP bridge の connect/cancel/disconnect/error mapping
- NLA/TLS、credential challenge、certificate UI
- software framebuffer→Metal dirty-region 描画
- Fit/100%、pinch、pan、回転。DISP 対応時の動的解像度、非対応時の local scaling/再接続
- remote cursor、connection status/retry
- scene inactive privacy cover と lifecycle 処理

### Exit criteria

- 対象 Windows へ接続し、30 分操作して crash/leak/UI hang がない。
- 接続全段階をキャンセル可能で、100 回の connect/disconnect test に耐える。
- 証明書を無言で受理せず、fingerprint 変更を検出する。

## 5. Phase 3 — 物理入力とポインター

### 実装

- `RemoteInputView` first responder と UIKit keyboard capture
- GCKeyboard lifecycle、usage ごとの静的 source policy、`KeyboardEventArbiter`
- HID-to-RDP mapping、Japanese layout/type negotiation
- focused-session input gate、`releaseAll`
- hover、左右 button/drag、縦横 wheel、ViewportTransform
- scroll 反転/global override
- redacted input diagnostics

### Exit criteria

- KEY-EISU-01/KEY-KANA-01 の各 100 回が実機/Windows で合格する。
- local IME の候補/文字が混入せず、focus/lifecycle 操作で押下残りがない。
- Apple JIS と PC JIS、mouse と trackpad の必須 matrix が合格する。

## 6. Phase 4 — 複数セッション

### 実装

- session ごとの FreeRDP instance/worker/frame store
- 実行中 section、session switcher、状態 badge
- focused session の atomic switch と stale generation 排除
- 非表示 session の presentation 縮退、memory warning policy
- reconnect と scene restoration policy

### Exit criteria

- 2×1080p session を必須として 30 分接続し、切替、入力分離、個別切断が成立する。3 session は基準端末で目標測定する。
- 1 session の network stall/error が他 session/UI を止めない。
- memory baseline に基づく supported session guidance を決める。

## 7. Phase 5 — 音声・クリップボード

### 実装

- iOS `RDPSND_DEVICE_PLUGIN`、PCM-only negotiation、session 別 SPSC ring、共通 AVAudioEngine、route/interruption
- focused session だけを再生する audio policy
- `cliprdr` の format-list/request/response、NUL 終端 UTF-16LE `CF_UNICODETEXT`、UIPasteboard adapter
- clipboard direction、user-initiated paste/copy、loop/size protection

### Exit criteria

- 44.1/48 kHz の test tone が安定再生され、route/interruption 後に復帰する。
- session 切替で音声が混ざらない。
- ASCII/日本語/絵文字を双方向に copy でき、許可 UI を過剰に出さない。
- clipboard/audio 本文が log/disk に残らない。

## 8. Phase 6 — ソフトウェアキーボード

この phase は後半だが、`InputMode` の経路分離と小さな `UITextInput` 技術検証は Phase 0〜3 で済ませる。

### 実装

1. 拡張キーバー: Esc、Tab、Ctrl、Alt、Shift、Win、矢印、Delete、変換、無変換
2. host IME mode: ASCII を scan code 化、virtual modifier の one-shot/lock
3. local IME mode: marked text 表示、確定文字だけを Unicode event で送信。不成立文字は明示 clipboard paste
4. mode/global default/profile override、session 中の切替
5. software keyboard の回転、予測変換、絵文字、削除、composition edge case

### Exit criteria

- local IME mode で未確定文字が host へ漏れず、確定文字が一度だけ届く。
- host IME mode で変換/無変換と Ctrl 等が正しい down/up になる。
- mode 切替、keyboard close、session 切替で marked text/modifier が残らない。

## 9. Phase 7 — リリース仕上げ

- accessibility、String Catalog、日本語/英語文言
- エラー/help、予約 shortcut と background 制約の説明
- performance/energy/thermal tuning、network condition test
- security review、fuzz/negative test、privacy manifest/用途説明
- dependency vulnerability/license/SBOM、暗号輸出申告
- TestFlight 実機 matrix、crash/metric triage
- release gate と既知制約の承認

## 10. Phase 8 — SSH 拡張（将来）

RDP v1 の後、次を新規 module として追加する。

- `SSHConfiguration` と credential/host key trust
- `SSHRemoteSession`（接続 lifecycle/state/event）
- terminal presentation、PTY size、terminal keyboard mapping
- protocol-specific 接続 form section

再利用するもの:

- profile list/CRUD、Keychain、session manager/switcher
- global navigation、error/log infrastructure
- focus と複数 session の policy

再利用しないもの:

- RDP scan code mapping、pointer、Metal bitmap renderer
- `rdpsnd`/`cliprdr` channel（SSH terminal の clipboard は別 adapter）

## 11. Risk register

| Risk | 影響 | 早期検出/対策 |
|---|---|---|
| FreeRDP の iOS build/静的 add-in が版依存 | 必須 channel が動かない | Phase 0 で版固定前に SVC/DVC negotiation とデータ往復、bridge に版差を隔離 |
| 英数 key-up/keyboard 個体差 | IME key が押下残り/非対応 | KeyEcho と実機 matrix、usage ごとの固定 source policy、releaseAll |
| iPadOS 予約 shortcut | Windows 操作の一部が送れない | 実測した compatibility 表と virtual key bar |
| 4K×複数 session の memory | jetsam | dirty region、buffer 数制御、非表示 texture 解放、実測後 guidance |
| rdpsnd backend/codec | 音切れ・工数増 | Phase 0 で PCM-only device callback/wave confirm、Phase 5 で SPSC ring |
| pasteboard permission | UX 悪化 | 常時 read をせず user-initiated control、direction setting |
| background suspension | 接続が切れる | 維持を保証せず復帰検査/再接続。UI に明記 |
| C callback/challenge teardown race | crash/use-after-free/deadlock | callback data の即時 copy、opaque bridge、generation、全終了経路で wait を wake、idempotent stop、sanitizer stress test |
| license/codec 条件 | App Store 配布不可 | 最小 dependency、SBOM、codec 追加を release gate 化 |

## 12. 実装開始前に確定する既定値

回答がなくても次の仮定で Phase 0 を開始できる。

| 論点 | 現在の仮定 |
|---|---|
| 最低 OS | iPadOS/iOS 17.0 |
| 配布 | App Store |
| 音声 | remote playback のみ。microphone なし |
| clipboard | 明示操作の bidirectional `CF_UNICODETEXT`。自動監視、画像/ファイルなし |
| multi-session | 前景中 2 session 必須、3 session 目標。background 維持保証なし |
| RD Gateway/RemoteApp | v1 MVP 外 |
| local IME mode | 確定文字を Unicode keyboard event、不成立文字を明示 paste。host IME OFF を案内 |

方針が異なる場合、影響が大きいのは音声入力、RD Gateway、最低 OS、clipboard file transfer の四点である。
