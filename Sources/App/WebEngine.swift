//
//  WebEngine.swift
//  Kotone — WKWebView と WKWebExtension の土台
//
//  rev.56 で Gecko から置き換えた。
//
//  ---------------------------------------------------------------------
//  構成
//
//    WKWebExtensionController ─┬─ Kotone Bridge（同梱 Extension/）
//                              └─ 取り込んだ拡張機能（AddonController）
//            │
//    WKWebView（1 枚だけ）  ← 再生とブラウザ画面を兼ねる
//            │                 KotoneTab として拡張機能に見せる
//    KotoneWindow（1 つだけ）
//
//  WKWebView は 1 枚だけにする。Gecko 時代と同じく、ブラウザ画面で
//  見ているページがそのまま再生を担当する（MusicHostViewController 参照）。
//
//  拡張機能の tabs API は、アプリが WKWebExtensionTab / WKWebExtensionWindow
//  を実装して見せた範囲しか知らない。Kotone Bridge の background.js は
//  tabs.query / tabs.sendMessage / tabs.update を使うので、
//  KotoneTab が url / webView / loadURL を答える必要がある。
//
//  ログイン状態（Cookie）は WKWebsiteDataStore.default() に残る。
//  ---------------------------------------------------------------------
//

import UIKit
import WebKit

extension Notification.Name {
    /// 設定画面の「ブラウザ画面を開く」
    static let kotoneShowBrowser = Notification.Name("Kotone.showBrowser")
    /// ブラウザ画面から音楽 UI へ戻る
    static let kotoneShowMusicUI = Notification.Name("Kotone.showMusicUI")
    /// 拡張機能の一覧・状態が変わった
    static let kotoneExtensionsDidChange = Notification.Name("Kotone.extensionsDidChange")
    /// 取り込んだ拡張機能を有効にした。再生用ページを読み込み直して効かせる（rev.59）
    static let kotoneReloadPlayerPage = Notification.Name("Kotone.reloadPlayerPage")
}

// MARK: - 拡張機能に見せるウィンドウとタブ

final class KotoneWindow: NSObject, WKWebExtensionWindow {
    var tabs: [KotoneTab] = []

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.first }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

final class KotoneTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var window: KotoneWindow?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { webView.title }

    func url(for context: WKWebExtensionContext) -> URL? { webView.url }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

    func isSelected(for context: WKWebExtensionContext) -> Bool { true }

    /// background.js の tabs.update(id, { url }) がここに来る。
    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        MeasurementLog.shared.append(.nav, "tabs.update → load \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }
}

// MARK: - エンジン

@MainActor
final class WebEngine: NSObject {

    static let shared = WebEngine()

    let controller: WKWebExtensionController
    let window = KotoneWindow()
    /// 再生とブラウザ画面を兼ねる唯一の WKWebView
    let webView: WKWebView
    let playerTab: KotoneTab

    /// 同梱の Kotone Bridge。読み込みに失敗したら nil。
    private(set) var bridgeContext: WKWebExtensionContext?
    /// 同梱拡張機能の読み込みで出たエラー（診断画面で表示する）
    private(set) var bridgeLoadErrors: [String] = []

    /// 同梱拡張機能の context に固定で付ける ID。
    /// 保存領域（storage.local など）が起動ごとに変わらないようにする。
    static let bridgeIdentifier = "kotone-bridge"

    private var startTask: Task<Void, Never>?
    private let log = MeasurementLog.shared

    /// 取り込んだ拡張機能の base URL に使うスキーム（rev.59）。
    ///
    /// Safari 向けの拡張機能は、自分の URL が `safari-web-extension:` かどうかで
    /// Safari 用の処理に切り替える。uBlock Origin Lite は ext.js の webextFlavor で
    /// これを見ており、既定の `webkit-extension:` だと Chromium 扱いになって
    /// WebKit の不具合の回避（ルールセットの再有効化、strict block の無効化など）を通らない。
    /// 同梱の Kotone Bridge は既定のスキームのまま（変える理由が無い）。
    static let importedExtensionScheme = "safari-web-extension"

    private override init() {
        // base URL に使うスキームは、context を読み込む前に登録する（WKWebExtensionMatchPattern.h）。
        WKWebExtension.MatchPattern.registerCustomURLScheme(Self.importedExtensionScheme)

        let extensionController = WKWebExtensionController()
        controller = extensionController

        let config = WKWebViewConfiguration()
        config.webExtensionController = extensionController
        // 音楽アプリなので自動再生を常に許可し、インライン再生にする。
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        // デスクトップ版の方がプレイヤーの機能が揃っている（Gecko 時代と同じ方針）。
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // WKWebView の既定の UA には "Version/x Safari/y" が無く、YouTube Music が
        // 「お使いのブラウザ向けに最適化されていません」を出して開けない（rev.56 実機）。
        // Safari と同じ並びになるよう末尾を足す。Safari の Version は OS のメジャー版と同じ。
        config.applicationNameForUserAgent = Self.safariApplicationName()

        // super.init() の前は self のプロパティを読めないので、ローカルで組み立てる。
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        // 実機の Safari Web インスペクタ（Mac）から見られるようにする。
        web.isInspectable = true
        webView = web
        playerTab = KotoneTab(webView: web)
        super.init()

        playerTab.window = window
        window.tabs = [playerTab]
        controller.delegate = self

        // 拡張機能の実行時エラー（background.js の例外など）を測定ログに残す。
        // 診断画面は開いたときの値しか見えないので、起きた時刻を記録する。
        NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let context = note.object as? WKWebExtensionContext else { return }
                let name = context.webExtension.displayName ?? context.uniqueIdentifier
                for error in context.errors {
                    MeasurementLog.shared.append(.error, "[ext:\(name)] \(WebEngine.describe(error)) \((error as NSError).userInfo)")
                }
            }
        }
    }

    /// 拡張機能を読み込み、ウィンドウとタブを知らせる。何度呼んでも 1 回だけ走る。
    ///
    /// ページを読み込む前に終わらせる。content script は読み込み済みの
    /// context の分しか注入されないため。
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { @MainActor in
            log.append(.addon, "WebEngine 起動")
            await loadBridge()
            await AddonController.shared.loadInstalled(into: controller)

            controller.didOpenWindow(window)
            controller.didOpenTab(playerTab)
            controller.didFocusWindow(window)
            log.append(.addon, "読み込み済みの拡張機能: \(controller.extensionContexts.count) 個")

            // 取り込んだ拡張機能の準備を待ってから最初のページを開かせる（rev.59）。
            // WebKit は controller.load の後で、登録済みスクリプト（scripting.registerContentScripts の分）と
            // declarativeNetRequest のルールを非同期に読み込む（WebExtensionContextCocoa.mm の load、
            // WebExtensionContextAPIScriptingCocoa.mm の loadRegisteredContentScripts）。
            // 待たずにページを開くと document_start の注入に間に合わず、YouTube Music は
            // ページを読み直さない（SPA）ので、その起動中ずっと広告除去のスクリプトが効かない。
            await AddonController.shared.wakeEnabled()
        }
        startTask = task
        await task.value
    }

    // MARK: 同梱の Kotone Bridge

    private func loadBridge() async {
        guard let url = Bundle.main.url(forResource: "Extension", withExtension: nil) else {
            bridgeLoadErrors = ["アプリ内に Extension/ がありません（project.yml の resources を確認）"]
            log.append(.error, "[bridge] \(bridgeLoadErrors[0])")
            return
        }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: url)
            bridgeLoadErrors = ext.errors.map { $0.localizedDescription }
            for e in bridgeLoadErrors {
                log.append(.error, "[bridge] manifest: \(e)")
            }

            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = Self.bridgeIdentifier
            context.isInspectable = true
            Self.grantRequestedPermissions(context)
            try controller.load(context)

            bridgeContext = context
            KotoneBridge.shared.context = context
            log.append(
                .bridge,
                "Kotone Bridge 読み込み v\(ext.version ?? "?") "
                    + "MV\(ext.manifestVersion) "
                    + "background=\(ext.hasBackgroundContent) "
                    + "content=\(ext.hasInjectedContent)"
            )
        } catch {
            bridgeLoadErrors.append(error.localizedDescription)
            log.append(.error, "[bridge] 読み込み失敗: \(Self.describe(error))")
        }
    }

    /// background を起こして、読み込み完了を待つ。完了したら nil、失敗・時間切れならエラー。
    ///
    /// 完了ハンドラが呼ばれないまま止まることがある（rev.56 実機: background.js が
    /// 読み込み中に例外を出したとき 14 秒以上呼ばれなかった）ので、timeout で打ち切る。
    static func loadBackground(_ context: WKWebExtensionContext, timeout: TimeInterval) async -> Error? {
        let started = Date()
        let box = LoadResultBox()
        context.loadBackgroundContent { error in
            box.result = error.map { .failure($0) } ?? .success(())
        }
        while box.result == nil {
            if Date().timeIntervalSince(started) > timeout {
                return KotoneBridgeError("background の読み込みが \(Int(timeout)) 秒で完了しません")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if case .failure(let error) = box.result { return error }
        return nil
    }

    /// Safari の UA 末尾（例 "Version/27.0 Safari/605.1.15"）。
    static func safariApplicationName() -> String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "26"
        return "Version/\(major).0 Safari/605.1.15"
    }

    /// manifest が求める権限とホストをすべて許可する。
    ///
    /// 同梱の Kotone Bridge と、取り込み時に利用者が一覧を見て承諾した
    /// 拡張機能にだけ使う（AddonsViewController の確認ダイアログ）。
    static func grantRequestedPermissions(_ context: WKWebExtensionContext) {
        let ext = context.webExtension
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// NSError の domain / code / 下位エラーまでたどって 1 行にする。
    static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 4 {
            parts.append("\(e.domain)#\(e.code): \(e.localizedDescription)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " ← ")
    }

    // MARK: 画面の表示先

    /// 拡張機能のポップアップ・設定ページを出す先。最前面の画面。
    fileprivate func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// 拡張機能のページ（設定ページ・新しいタブ）を別の WKWebView で開く。
    ///
    /// 拡張機能のページは context の webViewConfiguration で作らないと
    /// browser.* API が使えない（WKWebExtensionContext.h）。
    func presentExtensionPage(_ url: URL, context: WKWebExtensionContext, title: String?) {
        guard let configuration = context.webViewConfiguration else {
            log.append(.error, "[addon] webViewConfiguration が nil（未読み込み？）: \(url)")
            return
        }
        let page = ExtensionPageViewController(url: url, configuration: configuration)
        page.title = title ?? context.webExtension.displayName
        let nav = UINavigationController(rootViewController: page)
        nav.modalPresentationStyle = .formSheet
        topViewController()?.present(nav, animated: true)
        log.append(.addon, "拡張機能のページを開く: \(url.absoluteString)")
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension WebEngine: WKWebExtensionControllerDelegate {

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        window
    }

    /// background.js の runtime.connectNative がここに来る。
    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard extensionContext === bridgeContext else {
            log.append(
                .addon,
                "connectNative を拒否: \(extensionContext.webExtension.displayName ?? "?") "
                    + "app=\(port.applicationIdentifier ?? "nil")"
            )
            completionHandler(KotoneBridgeError("この拡張機能からのネイティブ接続は受け付けていません"))
            return
        }
        KotoneBridge.shared.attach(port)
        completionHandler(nil)
    }

    /// runtime.sendNativeMessage がここに来る。Kotone Bridge は使っていない。
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        log.append(
            .bridge,
            "sendNativeMessage(\(applicationIdentifier ?? "nil")) from "
                + "\(extensionContext.webExtension.displayName ?? "?"): \(message)"
        )
        replyHandler(nil, KotoneBridgeError("sendNativeMessage は未対応です。connectNative を使ってください"))
    }

    /// tabs.create など。Kotone はタブを 1 つしか持たないので、
    /// 拡張機能のページだけ別画面で開き、それ以外は断る。
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let url = configuration.url else {
            completionHandler(nil, KotoneBridgeError("URL の無い新しいタブは開けません"))
            return
        }
        if url.scheme == extensionContext.baseURL.scheme {
            presentExtensionPage(url, context: extensionContext, title: nil)
            completionHandler(nil, nil)
        } else {
            log.append(.addon, "新しいタブを断る（タブは 1 つだけ）: \(url.absoluteString)")
            completionHandler(nil, KotoneBridgeError("Kotone は新しいタブを開けません"))
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL else {
            completionHandler(KotoneBridgeError("この拡張機能には設定ページがありません"))
            return
        }
        presentExtensionPage(url, context: extensionContext, title: "設定")
        completionHandler(nil)
    }

    /// ツールバーのボタン（uBlock Origin Lite のポップアップなど）。
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popup = action.popupViewController else {
            completionHandler(KotoneBridgeError("ポップアップがありません"))
            return
        }
        popup.modalPresentationStyle = .formSheet
        topViewController()?.present(popup, animated: true)
        log.append(.addon, "ポップアップ: \(context.webExtension.displayName ?? "?")")
        completionHandler(nil)
    }

    /// 実行中に追加の権限を求められたとき。取り込み時に承諾した分以外は断る。
    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        log.append(
            .addon,
            "追加の権限要求を断る: \(extensionContext.webExtension.displayName ?? "?") "
                + permissions.map(\.rawValue).sorted().joined(separator: ", ")
        )
        completionHandler([], nil)
    }
}

/// loadBackgroundContent の結果を待つための入れ物（完了ハンドラから書き、待つ側が読む）
private final class LoadResultBox {
    var result: Result<Void, Error>?
}

// MARK: - 拡張機能のページ

final class ExtensionPageViewController: UIViewController {
    private let url: URL
    private let configuration: WKWebViewConfiguration

    init(url: URL, configuration: WKWebViewConfiguration) {
        self.url = url
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let web = WKWebView(frame: view.bounds, configuration: configuration)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isInspectable = true
        view.addSubview(web)
        web.load(URLRequest(url: url))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
    }
}
