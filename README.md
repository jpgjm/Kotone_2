# Kotone

WKWebView 上で YouTube Music の公式 Web プレイヤーを動かす iOS 向け音楽プレイヤー。

> **名前は仮です。** `./scripts/rename.sh <NewName> <com.new.bundleid>` で変更できます。

---

## これは何か

ネイティブの UI（ViviMusic 由来の SwiftUI）で操作し、裏に敷いた WKWebView が
`music.youtube.com` の公式プレイヤーで再生します。ページとの連携は同梱の
拡張機能 **Kotone Bridge**（WKWebExtension）が担います。

rev.55 までは Gecko（Reynard のビルド済みエンジン）でしたが、Gecko は子プロセスを
App Extension（`Reynard Helper.appex`）として起動するため、ゲストの App Extension を
起動できない **LiveContainer では動きませんでした**。rev.56 で WKWebView +
WKWebExtension（iOS 18.4 以上）に置き換え、App Extension を持たない単一のアプリにしました。

| | rev.55（Gecko） | rev.56（WKWebView） |
|---|---|---|
| LiveContainer | ✖（子プロセスの appex を起動できない） | ○（appex なし） |
| アプリの大きさ | 約 280 MB のエンジンを同梱 | エンジンは iOS 側 |
| JIT | 無し（インタプリタ） | iOS 側の WebKit が持つ |
| 拡張機能 | AMO の署名済み .xpi | フォルダか ZIP を「ファイル」から取り込む |
| ページとの連携 | ローカル HTTP の迂回路 | ネイティブメッセージング |
| 通信の書き換え（webRequest） | 可 | 不可（declarativeNetRequest のルールのみ） |
| 音声出力の加工 | cubeb を差し替える構想 | 不可（ページ内の Web Audio まで） |

## 免責

本プロジェクトは Google LLC、YouTube、およびそれらの関連会社と一切関係がなく、
承認も推奨も受けていません。各サービス名・商標は識別目的でのみ言及しています。
個人利用を目的とした非商用の実験的プロジェクトです。

---

## 由来と謝辞

| 出所 | 利用範囲 | ライセンス |
|---|---|---|
| ViviMusic（自作） | ネイティブ UI と InnerTube（`Sources/Vivi/`） | — |
| [pear-devs/pear-desktop](https://github.com/pear-devs/pear-desktop) | ページの状態の読み方（`getState().queue`）、プラグイン設計 | MIT |
| [th-ch/youtube-music](https://github.com/th-ch/youtube-music) | pear-desktop の上流 | MIT |

本プロジェクト全体は **GPL-3.0** です（`LICENSE`）。MIT 部分の表示は `THIRD_PARTY_NOTICES.md`。

---

## 構成

```
.
├─ project.yml              XcodeGen 定義（ターゲットはアプリ本体だけ）
├─ .github/workflows/
│   └─ build.yml            未署名 IPA を生成
├─ Extension/               Kotone Bridge（WKWebExtension、MV3）
│   ├─ manifest.json
│   ├─ background.js        Swift との窓口（connectNative）
│   ├─ content.js           ページの DOM を読む・操作する（隔離ワールド）
│   └─ page.js              ページの JS 変数を読む（MAIN world）
├─ Sources/
│   ├─ App/                 独自
│   │   ├─ WebEngine.swift          WKWebView 1 枚と WKWebExtensionController
│   │   ├─ KotoneBridge.swift       拡張機能とのメッセージング
│   │   ├─ AddonController.swift    取り込んだ拡張機能の保存・読み込み
│   │   ├─ PlayerManager.swift      Views が使う再生インタフェース
│   │   ├─ BrowserViewController    ブラウザ画面（再生中のページそのもの）
│   │   └─ …
│   └─ Vivi/                ViviMusic から取り込んだ UI と InnerTube
├─ scripts/                 検査（波括弧・シンボル）と改名
└─ docs/VIVIMUSIC.md        ViviMusic 取り込み内容と PlayerManager の契約
```

### 経路

```
SwiftUI（Vivi）→ PlayerManager → KotoneBridge
   --port.sendMessage--> background.js --tabs.sendMessage--> content.js --CustomEvent--> page.js
                                                              │
   <--port.postMessage-- background.js <--runtime.sendMessage-┘（再生状態・曲情報・位置）
```

- WKWebView は 1 枚だけ。ブラウザ画面で見ているページが背面で再生を担当します。
- 拡張機能の `tabs` API には、アプリが実装した 1 ウィンドウ・1 タブ（`KotoneWindow` / `KotoneTab`）だけが見えます。
- iOS では拡張機能の background が常駐しません。WebKit は 2 分間やり取りの無い background を落とすので、
  一時停止のまま 2 分経つと接続が切れます。次に操作したときに `KotoneBridge` が起こし直します。

---

## ビルド

```bash
xcodegen generate
open Kotone.xcodeproj
```

CI（`.github/workflows/build.yml`）が未署名 IPA を作ります。署名は SideStore / LiveContainer 側で行います。

## インストール

- SideStore で直接入れても、LiveContainer に入れても動く構成です。
- YouTube Music へのログインは、設定 → 診断 →「ブラウザ画面を開く」で表示されるページで行います。
  Cookie は WKWebView の既定の保存領域に残ります。

## 拡張機能を追加する

ブラウザ画面の 🧩 →「『ファイル』から取り込む…」で、展開済みのフォルダ（`manifest.json` があるもの）か
ZIP を選びます。取り込む前に、拡張機能が求める権限とサイトの一覧が出ます。

- Chrome Web Store の `.crx` はそのままでは読めません（ZIP にしてください）。
- 拡張機能は再生中のページでも動きます。ページを壊すものは入れないでください。
- 実行中に追加の権限を求められても許可しません（取り込み時に承諾した分だけ）。

### uBlock Origin Lite（rev.59）

**Safari 版**を取り込んでください。uBOL-home リポジトリの `chromium/` は Chromium 向けで、
WebKit 向けのルール補正と回避処理が入っていません。

1. `scripts/build-ubol-safari.sh` で `uBOLite_<版>.safari.zip` を作る（Linux / macOS、node・jq・zip が必要）
2. 🧩 で古い uBlock Origin Lite を削除してから、ZIP を取り込む
3. アプリを終了して起動し直す（初回はルールの変換に時間がかかる。起動後 30 秒ほど待つ）
4. ブラウザ画面で `https://ublockorigin.github.io/uBOL-home/tests/test-filters.html` を開き、
   タイルが緑になるかを見る。診断画面の拡張機能の行で `dnr=true allURLs=true`、
   `background 起動: ✅` を確かめる

取り込んだ拡張機能の base URL は `safari-web-extension://<id>/`（Safari 向けの処理を選ばせるため）。

---

## 実機で確かめること（rev.56）

| # | 項目 | 見る場所 |
|---|---|---|
| 1 | LiveContainer で起動し、`music.youtube.com` が表示される | ブラウザ画面 |
| 2 | Kotone Bridge が読み込まれ、疎通テストが通る（`pageWorld = 1` なら page.js も動いている） | 🧩 → ブリッジ疎通テスト |
| 3 | 曲名・アーティストが音楽 UI に出る | ミニプレイヤー |
| 4 | 画面を消しても・ホームに戻っても再生が続く | — |
| 5 | ロック画面の曲名と操作（Kotone の Now Playing と WebKit 自身の表示のどちらが出るか） | ロック画面 |
| 6 | 一時停止のまま 3 分置いてから再生ボタンが効く（background の起こし直し） | 測定ログ `未接続のため background を起動します` |
| 7 | ループ / シャッフルの状態が読める | 🧩 → ブリッジ疎通テスト |
| 8 | 拡張機能（例: uBlock Origin Lite）を取り込み、広告が消える | 🧩 |
