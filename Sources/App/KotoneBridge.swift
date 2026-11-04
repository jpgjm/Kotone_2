//
//  KotoneBridge.swift
//  Kotone — Swift ⇔ Kotone Bridge（拡張機能）の窓口
//
//  rev.56 で Gecko 版の KotoneBridge（connectNative）と KotoneHTTPBridge
//  （127.0.0.1 のポーリング）を置き換えた。
//  WKWebExtension ではネイティブメッセージングがそのまま使えるので、
//  HTTP の迂回路は要らない。
//
//  ---------------------------------------------------------------------
//  経路
//
//    Swift  --port.sendMessage-->  background.js
//    background.js  --tabs.sendMessage-->  content.js  (--CustomEvent--> page.js)
//    content.js  --runtime.sendMessage-->  background.js
//    background.js  --port.postMessage-->  Swift
//
//  メッセージは JSON にできるオブジェクトをそのまま送る（Gecko 時代の
//  「文字列にしないと空辞書になる」問題は WebKit には無い）。
//
//    Swift → 拡張機能   { type, requestId, payload? }
//    拡張機能 → Swift   { type: "reply", requestId, result, error }
//                       { type: "event", tabId, payload }
//                       { type: "hello", version }
//                       { type: "log", level, message }
//  ---------------------------------------------------------------------
//
//  ---------------------------------------------------------------------
//  background は常駐しない
//
//  background は service_worker ではなく scripts（ページ）。rev.57 で変更。
//  WebKit の connectNative は呼び出し元のページが必要で、service_worker では
//  undefined が返って接続できなかった（background.js 冒頭参照）。
//
//  iOS では常駐の background が許されない（WebKit の WebExtension.cpp:
//  "A non-persistent background is required on iOS and iPadOS."）。
//  WebKit は、ポートが開いていても 2 分間やり取りが無いと
//  background を落とす（WebExtensionContextCocoa.mm
//  unloadBackgroundContentIfPossible: delayForInactivePorts = 2 min）。
//
//  再生中は timeupdate が毎秒流れるので落ちない。一時停止のまま
//  2 分経つと落ち、ポートが切れる。次に操作するときに
//  loadBackgroundContent で起こし、background.js の先頭で
//  connectNative し直してもらう（ensureConnected）。
//  ---------------------------------------------------------------------
//

import Foundation
import WebKit

struct KotoneBridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class KotoneBridge {

    static let shared = KotoneBridge()

    /// 同梱拡張機能の context。WebEngine が読み込み時に設定する。
    weak var context: WKWebExtensionContext?

    /// 拡張機能からのイベント（再生状態・曲情報など）の受け手。
    var onEvent: (([String: Any]) -> Void)?

    private var port: WKWebExtension.MessagePort?
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextRequestId = 1
    private(set) var connectedAt: Date?
    private(set) var extensionVersion: String?

    private let log = MeasurementLog.shared

    var isExtensionConnected: Bool {
        guard let port else { return false }
        return !port.isDisconnected
    }

    private init() {}

    // MARK: - 接続

    /// WebEngine の connectUsing から呼ばれる。
    func attach(_ newPort: WKWebExtension.MessagePort) {
        if let old = port, !old.isDisconnected {
            log.append(.bridge, "新しいポートが来たので古いポートを閉じる")
            old.disconnect()
        }
        newPort.messageHandler = { [weak self] message, error in
            Task { @MainActor in self?.receive(message, error: error) }
        }
        newPort.disconnectHandler = { [weak self, weak newPort] error in
            Task { @MainActor in
                guard let self, let newPort, self.port === newPort else { return }
                self.detach(reason: error.map { WebEngine.describe($0) } ?? "background が終了")
            }
        }
        port = newPort
        connectedAt = Date()
        log.append(.bridge, "拡張機能が接続しました（app=\(newPort.applicationIdentifier ?? "nil")）")
    }

    private func detach(reason: String) {
        port = nil
        connectedAt = nil
        log.append(.bridge, "拡張機能との接続が切れました: \(reason)")
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: KotoneBridgeError("拡張機能との接続が切れました（\(reason)）"))
        }
    }

    /// 切れていたら background を起こして、接続し直すのを待つ。
    private func ensureConnected() async throws {
        if isExtensionConnected { return }
        guard let context else {
            throw KotoneBridgeError("Kotone Bridge が読み込まれていません（診断画面を確認）")
        }
        log.append(.bridge, "未接続のため background を起動します")
        // rev.56 の実機ログで、background.js が読み込み中に例外を出したとき
        // 完了ハンドラが 14 秒以上呼ばれなかった（2026-11-04 21:45:23 / 21:45:37）。
        // 呼ばれないまま待ち続けると操作がすべて止まるので、10 秒で打ち切る。
        if let loadError = await WebEngine.loadBackground(context, timeout: 10) {
            let text = WebEngine.describe(loadError)
            let errors = context.errors.map { WebEngine.describe($0) }.joined(separator: " / ")
            log.append(.error, "[bridge] loadBackgroundContent 失敗: \(text)。拡張機能のエラー: \(errors.isEmpty ? "なし" : errors)")
            throw KotoneBridgeError("拡張機能の background を起動できません（\(text)）")
        }
        // background.js は読み込み直後に connectNative する。最大 5 秒待つ。
        for _ in 0..<50 {
            if isExtensionConnected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw KotoneBridgeError("background を起動しましたが 5 秒以内に接続されませんでした")
    }

    // MARK: - 受信

    private func receive(_ message: Any?, error: Error?) {
        if let error {
            log.append(.error, "[bridge] 受信エラー: \(WebEngine.describe(error))")
            return
        }
        guard let dict = message as? [String: Any], let type = dict["type"] as? String else {
            log.append(.error, "[bridge] 形式の違うメッセージ: \(String(describing: message))")
            return
        }
        switch type {
        case "reply":
            guard let id = (dict["requestId"] as? NSNumber)?.intValue,
                  let continuation = pending.removeValue(forKey: id) else {
                log.append(.bridge, "宛先の無い reply: \(dict["requestId"] ?? "nil")")
                return
            }
            if let text = dict["error"] as? String {
                continuation.resume(throwing: KotoneBridgeError(text))
            } else {
                let result = dict["result"]
                continuation.resume(returning: result is NSNull ? nil : result)
            }

        case "event":
            let payload = (dict["payload"] as? [String: Any]) ?? [:]
            onEvent?(payload)

        case "hello":
            extensionVersion = dict["version"] as? String
            log.append(.bridge, "hello v\(extensionVersion ?? "?")")

        case "log":
            let level = dict["level"] as? String ?? "info"
            let text = dict["message"] as? String ?? ""
            log.append(level == "error" ? .error : .bridge, "[ext] \(text)")

        default:
            log.append(.bridge, "未知のメッセージ: \(type)")
        }
    }

    // MARK: - 送信

    /// background.js にコマンドを送り、返事を待つ。
    ///
    /// background 側も個別に時間制限を持つ（通常 15 秒、resolveAudio は 25 秒）。
    /// こちらはそれより長く待ち、background が落ちて返事が来ない場合だけ諦める。
    func request(_ type: String, payload: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Any? {
        try await ensureConnected()
        guard let port else { throw KotoneBridgeError("拡張機能が接続していません") }

        let id = nextRequestId
        nextRequestId += 1
        var message: [String: Any] = ["type": type, "requestId": id]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            port.sendMessage(message) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.fail(id, KotoneBridgeError("\(type) を送れません（\(WebEngine.describe(error))）"))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.fail(id, KotoneBridgeError("\(type) が \(Int(timeout)) 秒で応答しません"))
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        log.append(.error, "[bridge] \(error.localizedDescription)")
        continuation.resume(throwing: error)
    }

    // MARK: - 再生制御
    //
    // PlayerManager（ViviMusic の Views が使う契約）の土台。
    // content.js の commands と 1 対 1 で対応する。

    @discardableResult
    func play() async throws -> Any? { try await request("play") }

    @discardableResult
    func pause() async throws -> Any? { try await request("pause") }

    @discardableResult
    func togglePlayPause() async throws -> Any? { try await request("toggle") }

    @discardableResult
    func next() async throws -> Any? { try await request("next") }

    @discardableResult
    func previous() async throws -> Any? { try await request("previous") }

    @discardableResult
    func seek(to position: TimeInterval) async throws -> Any? {
        try await request("seek", payload: ["position": position])
    }

    @discardableResult
    func setVolume(_ volume: Double) async throws -> Any? {
        try await request("setVolume", payload: ["volume": volume])
    }

    /// ページのループボタンを 1 回押す。off → all → one → off と巡回する。
    @discardableResult
    func cycleRepeat() async throws -> Any? { try await request("cycleRepeat") }

    /// ループ状態を指定の値にする。必要な回数だけボタンを押す。
    @discardableResult
    func setRepeat(_ mode: String) async throws -> Any? {
        try await request("setRepeat", payload: ["mode": mode])
    }

    /// ページのシャッフルボタンを押す。
    @discardableResult
    func toggleShuffle() async throws -> Any? { try await request("toggleShuffle") }

    /// 音声 URL を取る。ページのコンテキストで fetch するので、
    /// Cookie と署名済み URL がそのまま使える。
    @discardableResult
    func resolveAudio(videoId: String) async throws -> Any? {
        try await request("resolveAudio", payload: ["videoId": videoId])
    }

    /// URL をページに渡して再生させる（ページ内遷移）。
    @discardableResult
    func openURL(_ url: String) async throws -> Any? {
        try await request("openURL", payload: ["url": url])
    }

    /// ページ自身が持っている再生情報を調べる。ダウンロード経路の切り分け用。
    @discardableResult
    func playerResponseInfo() async throws -> Any? {
        try await request("playerResponseInfo")
    }

    /// ページの現在状態を取る
    @discardableResult
    func probe() async throws -> Any? { try await request("probe") }
}
