# 要件トレーサビリティ

## 1. 使い方

本表は [requirements.md](requirements.md) の全機能要件を、主設計、予定 test case、実装 phase に結び付ける。test ID は実装時の test plan/issue 名にも使い、完了時は CI または手動試験記録への link を追加する。

本表は対応関係を示すもので、実装完了を示すものではない。Phase 0 の実装範囲と Gate 状態は
[`phase0/README.md`](../phase0/README.md) および個別 test record を正とし、外部環境で未実施の
項目をソースや Simulator の結果だけで `PASS` にしない。

## 2. 接続・セッション・描画

| 要件 | 主設計 | 予定 test ID / test-plan 節 | Phase |
|---|---|---|---|
| CON-01 | [UI §3–4](ui-flow.md)、[Data §2](data-and-security.md) | `CON-CRUD-01` / Test §2.3 | 1 |
| CON-02 | [UI §4](ui-flow.md)、[Data §2](data-and-security.md) | `CON-PERSIST-01` / Test §2.1–2.3 | 1 |
| CON-03 | [UI §5](ui-flow.md)、[Architecture §11](architecture.md) | `CON-ERROR-01` / Test §2.2–2.3 | 2 |
| CON-04 | [Data §5](data-and-security.md)、[UI §5](ui-flow.md) | `CON-TRUST-01` / Test §11 | 0, 2 |
| SES-01 | [Architecture §7.2](architecture.md)、[UI §7](ui-flow.md) | `SES-MULTI-01` / Test §2.2, §7 | 4 |
| SES-02 | [UI §3, §6](ui-flow.md)、[Architecture §7.2](architecture.md) | `SES-LIST-01` / Test §2.2 | 4 |
| SES-03 | [UI §3, §7](ui-flow.md) | `SES-STATE-01` / Test §2.3 | 1, 4 |
| SES-04 | [Architecture §7](architecture.md) | `SES-ISOLATE-01` / Test §7, §12 | 4 |
| DSP-01 | [Architecture §6](architecture.md)、[UI §6](ui-flow.md) | `DSP-VIEWPORT-01` / Test §2.1, §7 | 2 |
| DSP-02 | [Architecture §6](architecture.md)、[Input §8.2](input-design.md) | `DSP-RESIZE-01` / Test §6–7 | 2 |
| DSP-03 | [Architecture §6](architecture.md) | `DSP-DAMAGE-01` / Test §2.2, §7 | 2 |

## 3. キーボード・ポインター

| 要件 | 主設計 | 予定 test ID / test-plan 節 | Phase |
|---|---|---|---|
| KEY-01 | [Input §3–6](input-design.md) | `KEY-HOLD-01`, `KEY-CHORD-01` / Test §5 | 3 |
| KEY-02 | [Input §6](input-design.md) | `KEY-EISU-01`, `KEY-KANA-01`, `KEY-IME-01` / Test §5 | 0, 3 |
| KEY-03 | [Input §4.1](input-design.md) | `KEY-IME-02` / Test §5 | 0, 3 |
| KEY-04 | [Input §5](input-design.md) | `KEY-DUP-01`, `KEY-DUP-02`, `KEY-SOURCE-01` / Test §5 | 3 |
| KEY-05 | [Input §5, §7](input-design.md)、[Architecture §10](architecture.md) | `KEY-FOCUS-01`, `KEY-LIFE-01` / Test §5, §12 | 3 |
| KEY-06 | [Input §4.3, §10](input-design.md) | `KEY-RESERVED-01` / Test §5 | 3, 6 |
| PTR-01 | [Input §8.1–8.3](input-design.md) | `PTR-BUTTON-01` / Test §6 | 3 |
| PTR-02 | [Input §8.4](input-design.md) | `PTR-SCROLL-01` / Test §6 | 3 |
| PTR-03 | [Input §8.2](input-design.md)、[Architecture §6](architecture.md) | `PTR-COORD-01` / Test §2.1, §6 | 3 |

## 4. 音声・クリップボード

| 要件 | 主設計 | 予定 test ID / test-plan 節 | Phase |
|---|---|---|---|
| AUD-01 | [Architecture §8](architecture.md) | `AUD-PLAY-01` / Test §8 | 5 |
| AUD-02 | [Architecture §8](architecture.md) | `AUD-ROUTE-01`, `AUD-FOCUS-01` / Test §8 | 5 |
| CLP-01 | [Architecture §9](architecture.md)、[UI §6.2](ui-flow.md) | `CLP-LOCAL-01` / Test §9 | 5 |
| CLP-02 | [Architecture §9](architecture.md)、[UI §6.2](ui-flow.md) | `CLP-REMOTE-01` / Test §9 | 5 |
| CLP-03 | [Architecture §9](architecture.md)、[Data §6](data-and-security.md) | `CLP-LOOP-01`, `CLP-PRIVACY-01` / Test §9 | 5 |

## 5. UI・後半機能・拡張性

| 要件 | 主設計 | 予定 test ID / test-plan 節 | Phase |
|---|---|---|---|
| UI-01 | [UI §3, §8](ui-flow.md) | `UI-LIST-01` / Test §2.3 | 1 |
| UI-02 | [UI §4](ui-flow.md) | `UI-EDITOR-01` / Test §2.3 | 1 |
| UI-03 | [UI §6–7](ui-flow.md) | `UI-WORKSPACE-01` / Test §2.2–2.3 | 1, 4 |
| SFT-01 | [Input §10](input-design.md)、[UI §9](ui-flow.md) | `SFT-POC-01`, `SFT-LOCAL-01`, `SFT-SWITCH-01` / Test §10 | 6 |
| SFT-02 | [Input §10.3](input-design.md)、[UI §9](ui-flow.md) | `SFT-REMOTE-01`, `SFT-MOD-01` / Test §10 | 6 |
| EXT-01 | [Architecture §2–5](architecture.md) | `EXT-DEPENDENCY-01`（target import rule/build test） | 1 |
| EXT-02 | [Architecture §3–4](architecture.md)、[Roadmap Phase 8](roadmap.md) | `EXT-FAKE-SSH-01`（factory/surface 差替 test） | 1 |

## 6. Release 時の更新規則

- 要件変更時は、同じ commit で本表、test plan、roadmap を更新する。
- Must 要件は少なくとも一つの自動または再現可能な手動 test record を必要とする。
- Phase 0 で確定する FreeRDP version、source policy、keyboard layout/type、端末別 session 保証数は ADR へ記録し、本表から link する。
- Later 要件も v1 完了対象にする場合は release gate へ昇格し、実機 test record を付ける。
