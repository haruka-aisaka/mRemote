# 実装ロードマップ

## 1. 進め方

最も不確実な FreeRDP の iOS build、Japanese scan code、描画/音声 bridge、複数セッションのメモリを先に実機で潰す。UI を作り込んだ後に native core の制約が判明しない順序にする。

検証の規模は [`README.md`](README.md) の「開発体制と試験スケール」に従う。個人開発なので、
反復回数と端末マトリクスは現実的な水準に落とし、そのぶん自動テストと記録に寄せる。

2026-10-07 時点の方針: 実機・Windows での確認を後回しにして Phase 6 まで実装を先行した。
各 phase の「実装状況」表の **未実施** が、実機/Windows 環境で消化する残りである。

期間ではなく exit criteria で phase を区切る。各 phase で未完の native resource、入力押下状態、秘密データが残らない teardown test を加える。Phase 0 の `GO` は個人基準で native core を採用する判断であり、製品/互換性/リリースの承認ではない。

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

### Core Gate（最初の実機 run）

1. device arm64 の bridge を含む harness を実機で起動できる。
2. NLA/TLS で実 Windows へ接続し、leaf/chain DER を `SecTrust` + SSL hostname policy で判定して challenge を扱える。
3. 英数→`0x7B`、かな→`0x79` の各 down/up が Windows 側で無変換/変換として認識される（数回の実機確認で足りる。KeyEcho による 10 cycle の機械判定は Phase 3 で行う）。
4. 対象 press で `super.presses*` を呼ばず、iPadOS IME/入力ソース UI を起動しない (`KEY-IME-02`)。
5. 接続停止・破棄後に callback/wait が残らず、再接続して crash/hang しない。

### 結果（2026-09-05: GO）

基準構成（iPad mini 第 7 世代 + Apple Magic Keyboard JIS + Windows 11 一台）で Core Gate の
7 行すべてが実機で PASS した。判定と繰り越し事項は [`phase0/README.md`](../phase0/README.md)
に記録してある。

### Gate

- FreeRDP を安全に停止/破棄できない、DER を authoritative trust 判定へ渡せない、必須 Japanese key event を送れない、または `KEY-IME-02` を満たせない場合は、その版/方式を採用しない。
- 合格後は個人基準で native core を採用し、Phase 1/2 へ進む。版変更、bridge 修正、代替 RDP core 評価が必要な場合だけ Core Gate を再実施する。
- pointer、4K、channel/audio、複数 session、archive/SBOM、多端末 matrix は実装済みの先行資産として残し、それぞれ Phase 3〜7 または対応機能の実装時に検証する。

## 3. Phase 1 — アプリ基盤と接続先

### 実装

- module/target 構成、DI、OSLog category（`Packages/mRemoteKit/` の SwiftPM package: `SessionCore` / `Persistence` / `AppleAdapters`）
- `ConnectionProfile`、RDP payload、global settings、migration
- Keychain credential repository、trust repository
- 接続先一覧、空状態、追加/編集/複製/削除 sheet
- `RemoteSession` interface、SessionManager actor、FakeRemoteSession
- Settings と dependency licenses 画面

### Exit criteria（2026-09-05: 達成）

- fake session で一覧→接続→全画面→一覧復帰→切断の UI test が通る。→ `AppUITests/ConnectionFlowUITests`
- password が profile store/log へ保存されない。→ Keychain 保存と、document へ混入しないことの test
- schema v1 と migration test の土台がある。→ `SchemaMigrator` と `SchemaMigratorTests`
- SSH session factory を将来登録できる依存方向になっている。→ `SessionFactoryRegistry`

### この phase で意図的に残したもの

- ライセンス画面は静的リスト。`ThirdParty/` の notice からの生成は Phase 7
- String Catalog への文言分離、VoiceOver/Dynamic Type の確認は Phase 7
- session workspace のリモート描画は placeholder。実描画は Phase 2

## 4. Phase 2 — 単一 RDP セッション

### 実装

- FreeRDP bridge の connect/cancel/disconnect/error mapping
- NLA/TLS、credential challenge、certificate UI
- software framebuffer→Metal dirty-region 描画
- Fit/100%、pinch、pan、回転。DISP 対応時の動的解像度、非対応時の local scaling/再接続
- connection status/retry
- scene inactive privacy cover と lifecycle 処理
- Phase 0 harness の `ServerTrustEvaluator` を `RDPProtocol` へ移設

### Exit criteria

- 対象 Windows へ接続し、30 分操作して crash/leak/UI hang がない。
- 接続全段階をキャンセル可能で、20 回の connect/disconnect test に耐える。
- 証明書を無言で受理せず、fingerprint 変更を検出する。
- （Phase 0 からの繰り越し）bridge の sanitizer stress を実施する。

### 実装状況

| 項目 | 状態 |
|---|---|
| bridge connect/cancel/disconnect、error mapping | 実装済み。`RDPErrorMapper` が bridge status と FreeRDP error code を `RemoteSessionError` へ写像する |
| NLA/TLS、credential challenge、certificate UI | 実装済み。`SessionChallengeSheet` |
| software framebuffer→Metal dirty-region 描画 | 実装済み。`LatestDesktopFrameStore` と `RemoteDesktopView` |
| Fit/100%、pinch、pan、回転、DISP 動的解像度 | 実装済み。`ViewportTransform` |
| scene inactive privacy cover と lifecycle | 実装済み |
| ポインター入力（hover/左右 button/drag/wheel） | 実装済み。Phase 3 から前倒し。`InputCore` の `PointerInputRouter` |
| キーボード入力（UIKit `presses*`、英数/かな、client 側 key repeat） | 実装済み。Phase 3 から前倒し。`InputCore` の `KeyboardInputRouter` と `RDPProtocol` の `RDPScanCodeMapper` |
| 接続全段階のキャンセル、20 回 connect/disconnect | 自動試験済み。`AppTests/RDPRemoteSessionTests` |
| 証明書の無言受理なし、fingerprint 変更検出 | 自動試験済み。`CertificateReviewPolicyTests` |
| 実 Windows への 30 分操作 | **未実施**。実機試験が必要 |
| bridge の sanitizer stress | 実施済み（2026-09-05）。下記 |

### bridge sanitizer stress の記録（2026-09-05）

Phase 0 から繰り越した項目。`unavailable`/mock backend の contract test 一式を
Address+UndefinedBehavior と Thread の両 sanitizer で実行し、いずれも clean。

| 構成 | 結果 |
|---|---|
| `-DMR_BRIDGE_SANITIZER=address` | 5/5 pass |
| `-DMR_BRIDGE_SANITIZER=thread` | 5/5 pass |
| `-DMR_BRIDGE_SANITIZER=address -DMR_BRIDGE_CERTIFICATE_TESTS=ON` | 6/6 pass（PEM parser 込み） |

実行環境: macOS 26.0 (arm64)、Apple clang（Xcode 27.0 / 27A5194q）、CMake 4.4.3。

この繰り越しのために `contract_tests.c` へ `concurrent stop and call stress` を追加した。
既存の drain test は順序を 1 回ずつ確認するもので、sanitizer が探すべき競合
（challenge wait とその wake の間に入る stop、run が return する最中に届く send、
既に消えた challenge への response）は再現しない。新テストは run と並行して別 thread から
25 反復 × 64 回の send/respond/cancel/stop を撃つ。destroy は両 thread の join 後にだけ呼ぶ。
これは Swift 側 `RDPNativeCallGate` が提供する外部 gate と同じ契約である。

再現手順は [`bridge/README.md`](../bridge/README.md) にある。

### この phase で意図的に残したもの

- ポインターとキーボードの**送信経路**は Phase 3 の範囲だったが、実機で何も試せなく
  なるため前倒しした。`InputCore`（`PointerInputRouter`/`KeyboardInputRouter`/
  `ScrollWheelAccumulator`/key repeat）と `RDPProtocol` の `RDPScanCodeMapper` が
  ここで入る。source は UIKit の `presses*` と indirect pointer だけで、`GCKeyboard`、
  `GCMouse`、usage ごとの source policy、`KeyboardEventArbiter` は Phase 3 のまま。
  KeyEcho による英数/かな 10 cycle の機械判定も Phase 3 のままである。
- **remote cursor の形状**は送れない。C ABI に pointer/cursor callback が無く、追加には
  ABI 変更と XCFramework の再生成が要る。ポインター自体が Phase 3 の担当なので、cursor
  shape の transport はそこで ABI 追加として設計する。現状はサーバー側描画に依存する。
- 自動再接続 (`ReconnectPolicy.automatic`) は設定値としては存在するが、再接続の実行は
  Phase 4 の scene restoration と同じ policy で扱う。

## 5. Phase 3 — 物理入力とポインター

### 実装

- GCKeyboard/GCMouse 経路、usage ごとの静的 source policy、`KeyboardEventArbiter`
- Phase 0 harness の `InputRouter` を `InputCore` へ移設（harness は入力回帰の治具として残す）
- `releaseAll` の source 横断 quarantine（Phase 2 は UIKit 単一 source ぶんのみ）
- Japanese layout/type negotiation（Phase 2 は scan code 送信のみ）
- focused-session input gate（Phase 2 は単一セッションの scene/state gate のみ）
- scroll 反転の global override（Phase 2 はセッション中の切り替えのみ）
- remote cursor shape の C ABI 追加（pointer callback）と描画
- redacted input diagnostics

Phase 2 で前倒し済み: `RemoteInputView` の first responder と UIKit keyboard capture、
`RDPScanCodeMapper`（HID-to-Set-1）、`ScrollWheelAccumulator`、hover/左右 button/drag/
縦横 wheel、`ViewportTransform`、client 側 key repeat。

### Exit criteria

- KEY-EISU-01/KEY-KANA-01 の各 10 回が実機/Windows で合格する。
- local IME の候補/文字が混入せず、focus/lifecycle 操作で押下残りがない。
- 手元の Apple JIS キーボードと利用可能なポインターで合格する。PC JIS と他のポインターは入手できた時点で追加検証とし、未検証であることを文書に残す。

### 実装状況（2026-10-07、シミュレータ確認まで）

実機確認を後回しにして Phase 6 まで先に進める方針になったため、ここでの「済み」は
実装と自動試験、シミュレータでの起動確認までを指す。

| 項目 | 状態 |
|---|---|
| GCKeyboard 経路と usage ごとの静的 source policy | 実装済み。`HardwareKeyboardMonitor` が `GCKeyboard.coalesced` を観測し、`InputCore` の `KeyboardEventArbiter` が usage ごとに一つの source だけを remote へ通す。基準 policy は全 usage が UIKit（Phase 0 の実機結果） |
| `releaseAll` の source 横断 quarantine | 実装済み。解放時に物理的に押されていた usage を隔離し、その押下の up/再 down を送らない。gate を開くときは `GCKeyboard` の `isPressed` で隔離を照合し直す |
| Japanese layout/type negotiation | 実装済み。bridge ABI 2 の `keyboard_profile`。日本語は 0x411/type 7、US は 0x409/type 4、自動は FreeRDP 既定のまま |
| focused-session input gate | 実装済み。`SessionManager` の focus を `AppEnvironment.focusedSessionID` に写し、focus 外の surface は gate が閉じる |
| scroll 反転の global override | 既存の `Inheritable<ScrollDirection>`（グローバル既定 + 接続先ごとの上書き）とセッション中の切替で満たしている |
| remote cursor shape | 実装済み。bridge の pointer class が BGRA へ変換し、surface はリモート倍率で描いたレイヤーをローカルポインタに追従させ、システムポインタを隠す。サーバーからの位置ワープは iPadOS が許さないため無視する |
| redacted input diagnostics | 実装済み。設定 > 入力診断。常時の集計と、非文字キー限定・メモリのみ・10 分で自動停止する記録 |
| GCMouse | 採用しない。Phase 0 で UIKit の indirect pointer が左右ボタン・ドラッグ・ホイールを取れており、二経路を混ぜない原則（入力設計 8.1）に従う |
| KEY-EISU-01/KEY-KANA-01 各 10 回（KeyEcho） | **未実施**。実機と Windows が必要 |
| 押下残りの実機確認（focus/lifecycle） | **未実施**。自動試験（`KeyboardEventArbiterTests`）のみ |

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

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| session ごとの FreeRDP instance/worker/frame store | Phase 2 の構造のまま成立（セッションごとに `RDPRemoteSession` と専用 worker）。上限は `SessionManager.sessionLimit = 3` |
| 実行中 section、session switcher、状態 badge | 実装済み。一覧の「実行中」、フローティングボタンのメニュー sheet の切替一覧、`SessionStateBadge`（色だけに頼らずアイコン付き） |
| focused session の atomic switch と stale generation 排除 | 実装済み。`AppEnvironment.switchTo` で focus を移し、旧 surface は gate 閉で押下を解放、新 surface は `.id` で作り直す。generation は Phase 2 から session が保持 |
| 非表示 session の presentation 縮退 | 実装済み。frame store が最後の全面フレームを保持し、戻ったときに即描画（従来は次の更新まで黒） |
| memory warning policy | 実装済み。非 focus セッションの保持フレームだけを捨て、接続は切らない |
| reconnect と scene restoration policy | 実装済み。接続済みだったセッションが再試行可能なエラーで落ちたら 1/2/4 秒で最大 3 回（`ReconnectSchedule`）。前景復帰時にも判定。認証失敗等は再試行しない。あわせて状態機械に `connected → failed` を追加した（従来は通信断後も `connected` のまま残っていた） |
| 通常 tap は既存セッションへ戻る／明示操作だけが多重接続 | 実装済み。一覧の context menu「新しいセッションで接続」 |
| 2×1080p で 30 分、切替・入力分離・個別切断 | 自動試験（`MultiSessionTests`）で focus・個別切断・再接続を確認。**実機 30 分は未実施** |
| network stall が他 session/UI を止めない | 構造上はセッションごとの worker で隔離。**実測は未実施** |
| memory baseline と supported session guidance | **未実施**。実機計測が必要 |

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

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| iOS `RDPSND_DEVICE_PLUGIN`、PCM-only negotiation | 実装済み。bridge 独自の `mremote` サブシステム（addin provider で登録）が 16-bit PCM 1〜2ch だけを受け、`mr_rdpsnd` の focus gate を通す。Wave Confirm は FreeRDP core が送る |
| session 別 SPSC ring、共通 AVAudioEngine | 実装済み。`mr_pcm_ring`（C、lock-free）をセッションごとに持ち、`AudioCoordinator` が focus 中のセッションの ring だけを `AVAudioSourceNode` で再生する。render callback は lock・確保・actor hop をしない |
| route/interruption | 実装済み。interruption 終了と `AVAudioEngineConfigurationChange` で再構築。background で停止 |
| focused session だけを再生 | 実装済み。bridge 側で非 focus の PCM を捨て、切替時は新 ring の backlog を破棄 |
| `cliprdr` の format-list/request/response | 実装済み（bridge ABI 2）。ローカル→リモートは offer、リモート→ローカルは request。MS-RDPECLIP どおり capability の後に空の format list を送るようにした |
| NUL 終端 UTF-16LE `CF_UNICODETEXT` | 実装済み。`ClipboardTextCodec`（CRLF 変換、埋め込み NUL 拒否、受信は最初の NUL まで、不正サロゲートは U+FFFD） |
| clipboard direction、user-initiated paste/copy | 実装済み。メニューの `PasteButton`（OS の貼り付け許可ダイアログを出さない）と「端末へコピー」。貼り付け chord（Ctrl+V）はこの操作のときだけ送る |
| loop/size protection | 実装済み。4 MiB 上限、10 秒タイムアウト、受信直後の同一テキストは再 offer しない |
| 44.1/48 kHz test tone、route 変更後の復帰 | **未実施**。Windows からの実音が必要 |
| ASCII/日本語/絵文字の双方向 copy | codec と fake session での自動試験のみ。**Windows との往復は未実施** |

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

### 実装状況（2026-10-07、シミュレータ確認まで）

| 項目 | 状態 |
|---|---|
| 拡張キーバー | 実装済み。Esc/Tab/Ctrl/Alt/Shift/Win/無変換/変換/矢印/Home/End/PgUp/PgDn/Del。システムキーボードの accessory view |
| host IME mode | 実装済み。ASCII キーボードの打鍵を、接続時の配列（日本語 106/109 か US）に合わせたキー位置で送る（`ASCIIKeystrokeMapper`） |
| virtual modifier の one-shot/lock | 実装済み。タップで 1 キー限定 → 固定 → オフ。表示は塗りと鍵アイコンで区別し色だけに頼らない。修飾キーは各キーの前後で down/up するため、リモートに押下状態が残らない |
| local IME mode | 実装済み。隠した `UITextView` を proxy にし、iPadOS の marked text をそのまま使う。未確定文字はキーバー上に表示するだけで送らず、確定した文字を UTF-16 単位の Unicode イベントで送る（bridge ABI 2）。Enter はキーとして送る |
| marked text 中の制約 | 実装済み。確定/キャンセルを表示し、修飾キー・拡張キー・モード切替を無効化。Esc は未確定文字のキャンセルに使う |
| mode/global default、session 中の切替 | 実装済み。設定の初期モード（スキーマ v2、v1 からの移行付き）とキーバーの切替 |
| keyboard close / session 切替で modifier を解放 | 実装済み |
| 送れない文字の明示 clipboard paste | クリップボード送信（Phase 5）で代替可能。キーバーからの自動誘導は未実装 |
| Windows 側で一度だけ届くこと、host IME での変換/無変換 | **未実施**。Windows が必要 |

### 追加: 折りたたみ端末のラップトップ姿勢（2026-10-07、シミュレータ確認まで）

iPhone Duo（Xcode 27.1 beta のシミュレータ）向け。仕様は docs/ui-flow.md 9.1。

調査で分かったこと:

- iOS 27.1 の `UIHingeInteraction` / SwiftUI `onHingeChange` は状態（closed / partiallyOpen / fullyOpen）と角度だけを返し、**ヒンジの画面上の位置は取れない**。
- Duo の内側ディスプレイは 669×951pt、カバーは 466×678pt で内側の半分に相当する。縦持ちで長辺を横切って中央で折れるため、「縦長 + partiallyOpen」をラップトップ姿勢とし、中央で分割する。
- シミュレータのヒンジ操作は DeviceHub.app の UI のみ。`simctl` / `devicectl` には無い。
- `UIHingeInteraction` は Xcode 27.0 の SDK に無いため `#if canImport(UIKit, _version: 9127.0.85)` で分岐。27.0 でもビルドは通り、ヒンジは常に「なし」になる。

| 項目 | 状態 |
|---|---|
| ヒンジ検出と上下分割 | 実装済み（`HingePostureReader`、`SessionWorkspaceView`）。surface は分割時も再生成しない |
| PC 配列キーボード（JIS / US） | 実装済み（`LaptopKeyboardLayout`、`LaptopKeyboardComposer`）。キー位置を HID usage で送る。押している間 down、リピート、修飾キーは同時押しとタップでの one-shot/lock の両方 |
| トラックパッド | 実装済み（`RelativePointerMotion`）。相対移動と加速、タップで左、2 本指タップで右、2 本指スクロール、左右ボタン、ズーム時の追従、トラックパッド移動時のカーソル描画 |
| 解放 | 実装済み。gate が閉じたとき、デッキが消えたときにキーとボタンをすべて解放 |
| メニューの表示切替 | 実装済み。折り曲げたとき / 常に表示 / 表示しない（セッション単位、保存しない） |
| テスト | 単体テスト（配列幅、scan code の有無、合成、相対移動）と UI テスト（常に表示でデッキが出る）が通過 |
| 実際に折り曲げたときの自動切替 | **未確認**。DeviceHub での操作が必要 |
| 実ホストでのキー・ポインター | **未実施**。Windows が必要（fake session には surface が無い） |

次にやること:

- **分割時の解像度の扱いをオプション化する。** 現状はデッキの表示・非表示で surface の高さが変わり、動的解像度に対応したホストには折り曲げるたびに解像度変更を要求する。これを「折り曲げるたびに解像度を変える」か「解像度は保ったまま描画側でスケールする」か選べるようにする。

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
