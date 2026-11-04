//
//  BrowserViewController.swift
//  Kotone — 再生を担う WKWebView と、それを直接見られるブラウザ画面
//
//  rev.56 で GeckoView から WKWebView に置き換えた。
//
//  目的は「使えるブラウザ」ではなく「切り分けできること」。
//  ここで見ているページが、そのまま背面で音楽を再生している
//  （MusicHostViewController が alpha を落として敷いている）。
//
//  WKWebView は WebEngine が 1 枚だけ持っている。この画面は
//  それをツールバーの下に貼り、ナビゲーションの通知を受ける。
//
//  ログイン状態（Cookie）は WKWebsiteDataStore.default() に残るので、
//  YouTube Music へのログインはこの画面で一度行えばよい。
//

import UIKit
import WebKit

final class BrowserViewController: UIViewController {

    // MARK: - WebKit

    private var webView: WKWebView { WebEngine.shared.webView }
    private var observations: [NSKeyValueObservation] = []

    // MARK: - UI

    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private lazy var backButton = makeToolButton("chevron.backward", #selector(goBack))
    private lazy var forwardButton = makeToolButton("chevron.forward", #selector(goForward))
    private lazy var reloadButton = makeToolButton("arrow.clockwise", #selector(reloadPage))
    private lazy var desktopButton = makeToolButton("desktopcomputer", #selector(toggleDesktopMode))
    /// 音楽 UI へ戻る。設定画面の「ブラウザ画面を開く」と対になる導線。
    private lazy var backToMusicButton = makeToolButton("music.note.house", #selector(backToMusic))
    private lazy var addonButton = makeToolButton("puzzlepiece.extension", #selector(showAddons))
    private lazy var logButton = makeToolButton("list.bullet.rectangle", #selector(showLog))
    private lazy var diagButton = makeToolButton("checklist", #selector(showDiagnostics))

    // MARK: - State

    private var usesDesktopMode = true
    /// 実際に送られている UA を 1 回だけ記録する（YouTube Music の対応ブラウザ判定の確認用）
    private var didLogUserAgent = false
    private let log = MeasurementLog.shared

    private static let homeURL = "https://music.youtube.com"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 自前のツールバーを持っているので、この画面ではナビゲーションバーを隠す。
        // 押した先（アドオン / 測定ログ / 診断）では表示する。
        navigationItem.largeTitleDisplayMode = .never

        webView.navigationDelegate = self
        webView.uiDelegate = self
        setUpInterface()
        observeWebView()

        // 拡張機能のイベント（再生状態・曲情報）を PlayerManager へ渡す。
        KotoneBridge.shared.onEvent = { [weak self] payload in
            PlayerManager.shared.applyBridgeEvent(payload)
            // timeupdate は 1 秒おきに来るのでログには出さない。
            if payload["event"] as? String != "timeupdate" {
                let summary = payload.keys.sorted()
                    .map { "\($0)=\(payload[$0] ?? "nil")" }
                    .joined(separator: " ")
                self?.log.append(.bridge, "event \(summary)")
            }
        }

        // 取り込んだ拡張機能を有効にしたら、再生用ページに効かせるため読み直す（rev.59）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadForExtensions),
            name: .kotoneReloadPlayerPage,
            object: nil
        )

        // content script は読み込み済みの拡張機能の分しか注入されないので、
        // 拡張機能を読み込み終えてから最初のページを開く。
        Task { @MainActor in
            await WebEngine.shared.start()
            self.load(Self.homeURL)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 押した先の画面では戻るボタンが要るので表示に戻す。
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.progressView.setProgress(Float(web.estimatedProgress), animated: true) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.urlField.text = web.url?.absoluteString }
            },
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in
                    let title = web.title ?? ""
                    self?.title = title.isEmpty ? "Kotone" : title
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.backButton.isEnabled = web.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.forwardButton.isEnabled = web.canGoForward }
            },
        ]
    }

    // MARK: - 読み込み

    private func load(_ text: String) {
        guard let string = normalizedURL(from: text), let url = URL(string: string) else { return }
        urlField.text = string
        webView.load(URLRequest(url: url))
        log.append(.nav, "load \(string)")
    }

    private func normalizedURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        // about: / data: などスキームだけの形も URL として扱う。
        // rev.15 では about:blank が検索クエリに化けていた。
        for scheme in ["about:", "data:", "javascript:"] where trimmed.hasPrefix(scheme) {
            return trimmed
        }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? trimmed
            return "https://duckduckgo.com/?q=\(q)"
        }
        return "https://\(trimmed)"
    }

    // MARK: - Actions

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reloadPage() { webView.reload() }

    /// 拡張機能を取り込んだ・有効にした直後。再生中は止めないよう読み直さない。
    @objc private func reloadForExtensions() {
        guard webView.url != nil else { return }
        if PlayerManager.shared.isPlaying {
            log.append(.addon, "拡張機能を反映する再読み込みを見送り（再生中）。止めてから ↻ で読み直してください")
            return
        }
        webView.reload()
        log.append(.addon, "拡張機能を反映するため再読み込み: \(webView.url?.absoluteString ?? "-")")
    }

    /// 表示モード（デスクトップ / モバイル）は次の遷移から効く
    /// （decidePolicyFor の WKWebpagePreferences で指定する）。
    @objc private func toggleDesktopMode() {
        usesDesktopMode.toggle()
        updateDesktopButton()
        webView.reload()
        log.append(.info, "content mode -> \(usesDesktopMode ? "desktop" : "mobile")")
    }

    @objc private func backToMusic() {
        NotificationCenter.default.post(name: .kotoneShowMusicUI, object: nil)
    }

    @objc private func showAddons() {
        navigationController?.pushViewController(AddonsViewController(), animated: true)
    }

    @objc private func showLog() {
        navigationController?.pushViewController(MeasurementLogViewController(), animated: true)
    }

    @objc private func showDiagnostics() {
        navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
    }

    private func updateDesktopButton() {
        desktopButton.setImage(
            UIImage(systemName: usesDesktopMode ? "desktopcomputer" : "iphone"),
            for: .normal
        )
    }

    // MARK: - Layout

    private func makeToolButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func setUpInterface() {
        urlField.borderStyle = .roundedRect
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        urlField.delegate = self

        progressView.progress = 0
        progressView.alpha = 0

        let bar = UIStackView(arrangedSubviews: [
            backToMusicButton, backButton, forwardButton, reloadButton, urlField,
            desktopButton, addonButton, logButton, diagButton,
        ])
        bar.axis = .horizontal
        bar.spacing = 4
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for v in [bar, progressView, webView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            progressView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        backButton.isEnabled = false
        forwardButton.isEnabled = false
        updateDesktopButton()
    }

    private func finishProgress() {
        UIView.animate(withDuration: 0.25) { self.progressView.alpha = 0 } completion: { _ in
            self.progressView.setProgress(0, animated: false)
        }
    }
}

// MARK: - UITextFieldDelegate

extension BrowserViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        load(textField.text ?? "")
        return true
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.preferredContentMode = usesDesktopMode ? .desktop : .mobile
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log.append(.nav, "page start \(webView.url?.absoluteString ?? "-")")
        UIView.animate(withDuration: 0.15) { self.progressView.alpha = 1 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.append(.nav, "page stop success=true — \(MeasurementLog.memoryFootprint())")
        if !didLogUserAgent {
            didLogUserAgent = true
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, error in
                self?.log.append(.info, "userAgent = \(value ?? error.map { WebEngine.describe($0) } ?? "-")")
            }
        }
        PlayerManager.shared.navigationDidFinish(success: true)
        // ページを開き直すとループ状態がページ側の値に戻るので、
        // Kotone 側の表示を実態に合わせる。
        PlayerManager.shared.syncRepeatModeFromPage()
        finishProgress()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.append(.error, "page stop success=false: \(WebEngine.describe(error))")
        PlayerManager.shared.navigationDidFinish(success: false)
        finishProgress()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        log.append(.error, "page start failed: \(WebEngine.describe(error))")
        PlayerManager.shared.navigationDidFinish(success: false)
        finishProgress()
    }

    /// ページのプロセス（WebContent）が落ちた。メモリ不足で kill されることがある。
    /// WKWebView は白紙のまま残るので、開いていたページを読み直す。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.append(.error, "*** WebContent process TERMINATED — \(MeasurementLog.memoryFootprint()) → 再読み込み ***")
        PlayerManager.shared.applyPlaybackState(isPlaying: false)
        webView.reload()
    }
}

// MARK: - WKUIDelegate
//
// ページに勝手なダイアログを出させない。Gecko 時代の PromptDelegate と同じ方針で、
// alert は閉じ、confirm は肯定、prompt は空で返す（ログには残す）。

extension BrowserViewController: WKUIDelegate {

    /// target="_blank" や window.open。タブは 1 つなので同じ画面で開く。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            log.append(.nav, "新しいウィンドウ要求を同じ画面で開く: \(navigationAction.request.url?.absoluteString ?? "-")")
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        log.append(.nav, "alert: \(message) → 閉じる")
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        log.append(.nav, "confirm: \(message) → 肯定")
        completionHandler(true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        log.append(.nav, "prompt: \(prompt) → 応答せず閉じる")
        completionHandler(nil)
    }
}
