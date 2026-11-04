//
// page.js — Kotone Bridge（ページ側、MAIN world、rev.56）
//
// content.js は隔離ワールドで動くため、ページの JS が要素に生やした
// プロパティ（ytmusic-player-bar の getState など）や window の変数
// （ytInitialPlayerResponse）が見えない。
// Gecko では content.js から wrappedJSObject で届いたが、WebKit には無い。
//
// manifest の content_scripts で "world": "MAIN" を指定して、このファイルを
// ページと同じワールドに入れる（WebKit の WebExtension.cpp が "world" を解釈する）。
// content.js とは CustomEvent でやり取りする。
// ワールドをまたぐと detail のオブジェクトは渡らないことがあるので、
// detail は必ず JSON 文字列にする。
//
//   content.js → page.js   "kotone:request"   detail = JSON {id, type}
//   page.js → content.js   "kotone:response"  detail = JSON {id, result, error}
//

(() => {
  if (window.__kotonePageBridge) return;
  window.__kotonePageBridge = true;

  /// ページの Redux ストアからキューの状態を読む。pear-desktop と同じ場所。
  ///   src/providers/song-info-front.ts:66
  ///     document.querySelector('ytmusic-player-bar').getState().queue.repeatMode
  function queueState() {
    const candidates = [];
    const bar = document.querySelector("ytmusic-player-bar");
    if (bar) candidates.push(bar);
    const right = document.querySelector("#right-controls .repeat");
    if (right && right.__dataHost) candidates.push(right.__dataHost);

    for (const target of candidates) {
      if (typeof target.getState !== "function") continue;
      const state = target.getState();
      if (state && state.queue) {
        // キューの中身は循環参照を含みうるので、使う値だけ取り出す
        const q = state.queue;
        return {
          repeatMode: q.repeatMode === undefined ? null : q.repeatMode,
          shuffleEnabled: typeof q.shuffleEnabled === "boolean" ? q.shuffleEnabled : null,
          isShuffled: typeof q.isShuffled === "boolean" ? q.isShuffled : null,
        };
      }
    }
    return null;
  }

  const handlers = {
    ping: () => ({ pong: true }),
    queueState: () => queueState(),
    // ページ自身が持っている再生情報。JSON 由来のデータなのでそのまま返せる。
    initialPlayerResponse: () => window.ytInitialPlayerResponse || null,
  };

  window.addEventListener("kotone:request", (ev) => {
    let req;
    try {
      req = JSON.parse(ev.detail);
    } catch (e) {
      console.error("[kotone/page] 要求を読めません", e);
      return;
    }
    let result = null;
    let error = null;
    const handler = handlers[req.type];
    if (!handler) {
      error = "unknown page command: " + req.type;
    } else {
      try {
        result = handler(req);
      } catch (e) {
        error = String((e && e.message) || e);
      }
    }
    let detail;
    try {
      detail = JSON.stringify({ id: req.id, result, error });
    } catch (e) {
      detail = JSON.stringify({ id: req.id, result: null, error: "結果を JSON にできません: " + e });
    }
    window.dispatchEvent(new CustomEvent("kotone:response", { detail }));
  });

  console.log("[kotone/page] MAIN world script loaded");
})();
