// Kotone Bridge（Extension/）の動作確認。WebKit は使わず jsdom でページを模す。
// ワールドの分離（page.js と content.js が別ワールド）は再現しない。
// やり取りの形（CustomEvent の JSON、background の中継）と非同期化の確認用。
//
//   npm i --prefix /tmp/jst jsdom@24
//   NODE_PATH=/tmp/jst/node_modules node scripts/test-extension.js Extension
const { JSDOM } = require("jsdom");
const fs = require("fs");
const ext = process.argv[2];
const results = [];
const check = (name, cond, extra) => { results.push((cond ? "PASS " : "FAIL ") + name + (extra ? " " + JSON.stringify(extra) : "")); };

(async () => {
  // ---------- content.js + page.js ----------
  const dom = new JSDOM(`<html><body><ytmusic-app></ytmusic-app><ytmusic-player-bar><div class="title ytmusic-player-bar">T</div></ytmusic-player-bar><video></video></body></html>`, { runScripts: "outside-only", url: "https://music.youtube.com/watch?v=x" });
  const w = dom.window;
  const bar = w.document.querySelector("ytmusic-player-bar");
  let repeat = "ALL";
  bar.getState = () => ({ queue: { repeatMode: repeat, shuffleEnabled: false, items: [] } });
  w.ytInitialPlayerResponse = { playabilityStatus: { status: "OK" }, videoDetails: { videoId: "x" }, streamingData: { adaptiveFormats: [{ mimeType: "audio/mp4", itag: 140, url: "u" }] } };
  Object.defineProperty(w.navigator, "mediaSession", { value: { metadata: { title: "Song", artist: "Art", album: "Alb", artwork: [{ src: "s" }, { src: "big" }] } } });
  let listener = null; const sent = [];
  w.browser = { runtime: { onMessage: { addListener: (f) => (listener = f) }, sendMessage: (m) => { sent.push(m); return Promise.resolve(); } } };
  w.eval(fs.readFileSync(ext + "/page.js", "utf8"));
  w.eval(fs.readFileSync(ext + "/content.js", "utf8"));
  const call = (msg) => listener(msg);

  const rs = await call({ type: "repeatState" });
  check("repeatState", rs.mode === "all" && rs.shuffle === false, rs);
  const probe = await call({ type: "probe" });
  check("probe.pageWorld", probe.pageWorld === true, { pageWorld: probe.pageWorld, track: probe.track });
  const pri = await call({ type: "playerResponseInfo" });
  check("playerResponseInfo", pri.found === true && pri.audioCount === 1 && pri.withUrl === 1, pri);
  const meta = sent.find((m) => m.type === "media");
  check("metadata event", meta && meta.title === "Song" && meta.artworkUrl === "big", meta);
  // setRepeat: clicking cycles ALL -> ONE
  const btn = w.document.createElement("div"); btn.className = "repeat";
  const rc = w.document.createElement("div"); rc.id = "right-controls"; rc.appendChild(btn); w.document.body.appendChild(rc);
  const order = ["NONE", "ALL", "ONE"];
  btn.addEventListener("click", () => { repeat = order[(order.indexOf(repeat) + 1) % 3]; });
  const sr = await call({ type: "setRepeat", mode: "one" });
  check("setRepeat one", sr.mode === "one" && sr.readable === true, sr);
  // 曲を開く前（<video> の src が空）は toggle を失敗にする
  let toggleError = null;
  try { await call({ type: "toggle" }); } catch (e) { toggleError = String(e.message || e); }
  check("toggle without source", toggleError === "曲が読み込まれていません", { toggleError });
  // page.js absent → null (unreadable), not "off"
  const dom2 = new JSDOM(`<html><body></body></html>`, { runScripts: "outside-only", url: "https://music.youtube.com/" });
  let l2 = null; dom2.window.browser = { runtime: { onMessage: { addListener: (f) => (l2 = f) }, sendMessage: () => Promise.resolve() } };
  dom2.window.eval(fs.readFileSync(ext + "/content.js", "utf8"));
  const rs2 = await l2({ type: "repeatState" });
  check("no page.js → mode null", rs2.mode === null, rs2);

  // ---------- background.js ----------
  const posted = []; let onPortMsg = null;
  const port = { onMessage: { addListener: (f) => (onPortMsg = f) }, onDisconnect: { addListener: () => {} }, postMessage: (m) => posted.push(m) };
  const tabsSent = [];
  global.browser = {
    runtime: { connectNative: () => port, getManifest: () => ({ version: "0.19.0" }), onMessage: { addListener: (f) => (global.bgOnMessage = f) }, lastError: null },
    tabs: { query: async () => [{ id: 7, url: "https://music.youtube.com/", active: true }], sendMessage: async (id, p) => { tabsSent.push([id, p]); return { ok: true, echo: p }; }, update: async () => ({}) },
  };
  eval(fs.readFileSync(ext + "/background.js", "utf8"));
  check("hello", posted[0] && posted[0].type === "hello" && posted[0].version === "0.19.0", posted[0]);
  await onPortMsg({ type: "seek", requestId: 3, payload: { position: 12 } });
  const reply = posted.find((m) => m.type === "reply" && m.requestId === 3);
  check("seek relayed", tabsSent[0][0] === 7 && tabsSent[0][1].type === "seek" && tabsSent[0][1].position === 12 && reply && reply.error === null, reply);
  await onPortMsg({ type: "ping", requestId: 4 });
  check("ping", posted.some((m) => m.type === "reply" && m.requestId === 4 && m.result.pong), null);
  global.bgOnMessage({ type: "video", event: "play" }, { tab: { id: 7 } });
  check("event forwarded", posted.some((m) => m.type === "event" && m.tabId === 7 && m.payload.event === "play"), null);

  console.log(results.join("\n"));
  process.exit(results.some((r) => r.startsWith("FAIL")) ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
