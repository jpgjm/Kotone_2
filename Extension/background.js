//
// background.js — Kotone Bridge（WKWebExtension 版、rev.56）
//
// Swift 側との窓口はここ 1 箇所に集約する。
// content script は Native Messaging を使えないため、必ずここを経由する。
//
// 経路:
//   Swift  --port.sendMessage-->  background（このファイル）
//   background  --tabs.sendMessage-->  content.js
//   content.js  --runtime.sendMessage-->  background
//   background  --port.postMessage-->  Swift
//
// Gecko 時代との違い:
//   * オブジェクトをそのまま送れる（Gecko は空辞書になったので JSON 文字列にしていた）
//   * 127.0.0.1 の HTTP ポーリングは不要になったので削除した
//   * iOS では background が常駐しない（MV3 なので非常駐）。
//     WebKit はポートのやり取りが 2 分無いと background を落とす。
//   * background は service_worker ではなく scripts（ページ）にする（rev.57）。
//     WebKit の runtime.connectNative は NeedsPageIdentifier 付きで、
//     呼び出し元のページが見つからないと undefined を返す
//     （Bindings/Scripts/CodeGeneratorExtensions.pm）。
//     rev.56 の service_worker では実機で
//     「TypeError: undefined is not an object」になり、接続できなかった。
//     落ちた後は Swift 側が loadBackgroundContent で起こし、
//     このファイルの先頭で connectNative し直す（KotoneBridge.swift 冒頭参照）。
//

const NATIVE_APP = "kotone";

let port = null;

// ---------------------------------------------------------------------------
// ログ。background の console は実機で見られないので Swift にも送る。
// ---------------------------------------------------------------------------

function log(level, ...args) {
  const text = args
    .map((a) => (typeof a === "string" ? a : (() => { try { return JSON.stringify(a); } catch (e) { return String(a); } })()))
    .join(" ");
  (level === "error" ? console.error : console.log)("[kotone]", text);
  if (port) {
    try {
      port.postMessage({ type: "log", level, message: text });
    } catch (e) {
      console.error("[kotone] log post failed", e);
    }
  }
}

/// 応答が返らないコマンドで Swift 側を待たせ続けないようにする。
function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(label + " が " + ms + "ms で応答しません")), ms)
    ),
  ]);
}

// ---------------------------------------------------------------------------
// ネイティブ接続
// ---------------------------------------------------------------------------

function connect() {
  if (port) return;
  try {
    port = browser.runtime.connectNative(NATIVE_APP);
  } catch (e) {
    port = null;
    console.error("[kotone] connectNative failed", e);
    return;
  }
  // WebKit は呼び出し元のページが見つからないと例外ではなく undefined を返す
  if (!port) {
    console.error("[kotone] connectNative returned " + port);
    port = null;
    return;
  }
  port.onMessage.addListener(handleNativeMessage);
  port.onDisconnect.addListener(() => {
    const err = browser.runtime.lastError;
    console.log("[kotone] native port disconnected", err && err.message);
    port = null;
    // Swift 側から切られた（新しいポートで置き換えた等）。
    // background が生きている間に Swift が操作すると、
    // loadBackgroundContent は「読み込み済み」で何もしないため、ここで張り直す。
    setTimeout(connect, 1000);
  });
  post({ type: "hello", version: browser.runtime.getManifest().version });
  log("info", "native port connected");
}

function post(payload) {
  if (!port) connect();
  if (!port) return false;
  try {
    port.postMessage(payload);
    return true;
  } catch (e) {
    console.error("[kotone] postMessage failed", e);
    port = null;
    return false;
  }
}

// ---------------------------------------------------------------------------
// content script との中継
// ---------------------------------------------------------------------------

// content script が入っているタブ。music だけでなく通常の YouTube も対象にする。
async function musicTabs() {
  return await browser.tabs.query({
    url: [
      "*://music.youtube.com/*",
      "*://www.youtube.com/*",
      "*://m.youtube.com/*",
    ],
  });
}

async function callContent(payload) {
  let tabs = await musicTabs();

  // YouTube を開いていなければ、そのタブを音楽版に書き換えて待つ。
  // 再生や一時停止はページ内の操作なので、別サイトに居ると届かない。
  if (!tabs.length) {
    const active = (await browser.tabs.query({ active: true }))[0];
    if (!active) throw new Error("操作できるタブがありません");

    log("info", "YouTube 外なので戻す:", active.url);
    await browser.tabs.update(active.id, { url: "https://music.youtube.com/" });

    // 読み込みと content script の注入を待つ
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 500));
      tabs = await musicTabs();
      if (tabs.length) break;
    }
    if (!tabs.length) throw new Error("YouTube に戻れませんでした");
  }
  // タブは 1 つだけ（WebEngine.swift）。複数あればアクティブなものを使う。
  const tab = tabs.find((t) => t.active) || tabs[0];
  return await browser.tabs.sendMessage(tab.id, payload);
}

// ページ遷移の直後は content script がまだ入っていない。
// 少し待って入り直すのを待つ。SPA 遷移でも再注入されることがある。
async function callContentWithRetry(payload, attempts = 4) {
  let lastError;
  for (let i = 0; i < attempts; i++) {
    try {
      return await callContent(payload);
    } catch (e) {
      lastError = e;
      const text = String((e && e.message) || e);
      const transient =
        text.includes("Receiving end does not exist") ||
        text.includes("message port closed") ||
        text.includes("を開いていません");
      if (!transient) throw e;
      log("info", "content script 待ち (" + (i + 1) + "/" + attempts + "): " + text);
      await new Promise((r) => setTimeout(r, 400));
    }
  }
  throw lastError;
}

// ---------------------------------------------------------------------------
// URL を開く。
//
// content script が入っていないページを開いたままでもエラーにしない。
// そのタブをそのまま目的の URL に書き換える。
// ---------------------------------------------------------------------------
async function openURL(url) {
  if (!url) throw new Error("url がありません");

  // 1. YouTube のタブがあれば content script に任せる（ページ内遷移）
  const tabs = await musicTabs();
  if (tabs.length) {
    try {
      return await callContentWithRetry({ type: "openURL", url });
    } catch (e) {
      log("info", "content 経由に失敗。タブを書き換える: " + String((e && e.message) || e));
    }
  }

  // 2. 無ければ現在のタブを書き換える
  const active = (await browser.tabs.query({ active: true }))[0]
    || (await browser.tabs.query({}))[0];
  if (!active) throw new Error("書き換えられるタブがありません");

  await browser.tabs.update(active.id, { url });
  return { ok: true, url, method: "tabs.update" };
}

// ---------------------------------------------------------------------------
// Swift からの指示
//
//   { type, requestId, payload? }  →  { type: "reply", requestId, result, error }
// ---------------------------------------------------------------------------

async function handleNativeMessage(msg) {
  if (!msg || typeof msg !== "object") {
    log("error", "形式の違うメッセージ:", msg);
    return;
  }

  let result = null;
  let error = null;
  try {
    if (msg.type === "ping") {
      result = { pong: true, at: Date.now(), version: browser.runtime.getManifest().version };
    } else if (msg.type === "openURL") {
      // 曲が実際に変わったかの確認に最大 2.5 秒、
      // content 経由が失敗したらタブ書き換えに回るので、その分を見込む
      result = await withTimeout(openURL(msg.payload && msg.payload.url), 15000, msg.type);
    } else if (msg.type === "content") {
      // 任意のコマンドを content script に中継する
      result = await withTimeout(callContentWithRetry(msg.payload || {}), 15000, msg.type);
    } else {
      result = await withTimeout(
        callContentWithRetry(Object.assign({ type: msg.type }, msg.payload || {})),
        // resolveAudio はネットワークを叩くので長めに取る。
        // それ以外も、YouTube 外から戻る場合は読み込みを待つ。
        msg.type === "resolveAudio" ? 25000 : 15000,
        msg.type
      );
    }
  } catch (e) {
    error = String((e && e.message) || e);
  }

  if (msg.requestId !== undefined) {
    post({
      type: "reply",
      requestId: msg.requestId,
      result: result === undefined ? null : result,
      error,
    });
  }
}

// content script からの自発的な通知（再生状態・曲情報）
browser.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || typeof msg !== "object") return;
  const tabId = sender.tab ? sender.tab.id : null;
  post({ type: "event", tabId, payload: msg });
});

connect();
