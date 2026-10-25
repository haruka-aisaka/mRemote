# E2E テスト（Mac ホスト）

シミュレータの mRemote から、この Mac で動かしたテスト用の
[macos-rdp-server](https://github.com/haruka-aisaka/macos-rdp-server)（`127.0.0.1:3390`）へつなぎ、
アプリの使い方そのままで確かめる。

```sh
deno run -A e2e/mac-host/e2e.ts                     # ビルドして全部
deno run -A e2e/mac-host/e2e.ts --no-build --only connect,display,tap
deno run -A e2e/mac-host/e2e.ts --simulator "iPhone 18 Pro"
```

前提: macos-rdp-server のフォークを `~/projects/forks/macos-rdp-server` に置き（`MACOS_RDP_SERVER` で変えられる）、
サーバを一度 `~/.macos-rdp/bin/macos-rdp-daemon` に入れて画面収録などを許可しておく。`brew install freerdp`、Deno。
テスト用サーバは本番（3389）とは別に起動し、終わったら止める。

| テスト | 確かめること |
|---|---|
| connect | プロファイル（1920×1080 固定）を作って接続すると、Mac にその大きさの Retina の仮想ディスプレイができ、メインになる |
| display | Mac の画面いっぱいに出した目印の窓が、四隅とも正しい位置・縦横比で映る（画面に合わせる）。メニューの表示倍率も「画面に合わせる」 |
| tap | タップした所が、Mac の同じ位置でクリックされる |
| keyboard | ソフトウェアキーボードで打った文字と、ラップトップデッキのキーが Mac の入力欄に届く |
| zoom-toggle | 「表示の移動だけ」でダブルタップして 100% にすると、メニューの表示倍率も 100% になり、画面が描き直されても 100% のまま |
| reopen | 切断して一覧から開き直すと、同じ仮想ディスプレイにつながり、初期倍率（画面に合わせる）で映る |

## 仕組み

- アプリは `AppUITests/LiveRDPUITests` の `testConnectAndHold` を、コマンドファイルで外から動かす
  （`shot`・`reveal`・`connected` などのコマンドはこのテストのために足した）
- Mac 側には目印の窓（サーバ側の `tests/e2e/e2e-target.swift`）を出す。決まった色の背景と四隅の色付きの四角、
  入力欄。アプリのスクリーンショットの色の範囲（`color-boxes.swift`）で、どこまで・どの向きで見えているかを、
  窓が書くクリックの位置と入力欄の文字で入力を確かめる
- 1920×1080 は iPhone の画面より大きいので、「画面に合わせる」なら四隅が全部見え、「100%」なら真ん中だけが見える
- iPhone Duo のシミュレータは閉じた状態（外側の画面）で動く。`simctl io screenshot` は内側の画面を撮って
  真っ黒になるので、スクリーンショットはテストの中で撮る

## 自動化できないこと

- ハードウェアキーボード: XCTest の `typeKey` で合成したキーは、シミュレータではアプリに届かない
  （入力診断の受信が 0 件のまま）。キーコードで送る経路はラップトップデッキのキーで代わりに確かめる
- 音: シミュレータでは確かめない（サーバ側の E2E で、正弦波が崩れずに届くことを確かめている）

結果とスクリーンショットは `/tmp/mremote-e2e/run/` に残る。
