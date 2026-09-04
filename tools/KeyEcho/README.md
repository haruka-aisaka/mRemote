# KeyEcho

Windows が受信した low-level keyboard event を記録する、mRemote Phase 0 用の
scan-code observer です。英数/かなが RDP 越しに次の値として down/up 各 1 回だけ
届くことを確認します。

| iPad 側 | 期待する Windows event |
|---|---|
| 英数 (`HID 0x91`) | `scan=0x7B`, `vk=0x1D (VK_NONCONVERT)` |
| かな (`HID 0x90`) | `scan=0x79`, `vk=0x1C (VK_CONVERT)` |

## Build

Windows 10/11 の Developer Command Prompt で実行します。

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release
```

生成物は `build/Release/KeyEcho.exe` です。Win32 API だけを使い、MSVC runtime も
静的 link するため、対象 Windows へ追加 runtime を導入せず実行できます。

## 反復試験（既定 10 回）

1. KeyEcho を RDP 接続先で起動し、ウィンドウを表示したままにします。
2. `ログ消去` を押し、iPad 側の RDP surface に入力 focus があることを確認します。
3. 英数だけを完全に押して離す操作を 10 回行い、`eisu.jsonl` として保存します。
4. 再び `ログ消去` を押し、かなだけを同様に 10 回行い、`kana.jsonl` として保存します。
5. 各 run で対象が `down 10 / up 10 / repeat 0 / mismatch 0`、非対象が 0 であることを確認します。
6. 両 JSONL と SHA-256 を Phase 0 の test record に添付します。

Mac または Windows 上で JSONL を機械判定できます（`jq` が必要です）。第 2 引数が期待回数で、
script 自体の既定は 100 ですが、本プロジェクトの試験規模は 10 回です（`docs/README.md`
の「開発体制と試験スケール」）。

```bash
tools/KeyEcho/analyze-keyecho.sh eisu.jsonl 10 eisu
tools/KeyEcho/analyze-keyecho.sh kana.jsonl 10 kana
```

第3引数の既定 `both` は従来どおり一つのログに両キーを含む簡易確認用です。Gate evidence
では物理キーと scan code の帰属を取り違えないよう、上記の独立 run を使います。

metadata/event の必須 field、sequence の連続性、単調時刻の非減少も先に検証します。その後、
期待回数、down/up、repeat、orphan up、mapping mismatch、最後の押下残りを検査し、不合格なら
非 0 で終了します。Gate 用の単一キー run では対象外 scan code も拒否します。短い動作確認では
第 2 引数で期待回数を変更できます。

`repeat` は同じ scan code の up より前に複数 down を観測した回数です。意図的な長押し
では増えるので、反復試験では各キーを短く明確に離してください。なお client 側の key repeat は
LANG1/LANG2 を対象外にしているため、英数/かなの期待値は `repeat 0` のままです。`mismatch` は期待する
scan code に対する Windows virtual-key が変換/無変換ではなかった回数です。

JSON Lines の先頭行は Windows build とコンピューター名を持つ metadata、以降の各行は
単調時刻、down/up、scan code、extended、virtual-key、injected flag を持つ event です。
各行を単独の JSON object として機械比較できます。テスト専用ツールなので全キーを記録します。
本番アプリの診断ログへこの方式を流用しないでください。
