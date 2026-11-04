//
//  DiagnosticsViewController.swift
//  Kotone — バンドルと拡張機能の状態を実機上で確かめる画面
//
//  rev.56 で Gecko の確認項目（XUL・リソース・Reynard Helper.appex）を外し、
//  WKWebExtension の確認に置き換えた。
//
//    * 独自 Bundle ID でインストールできたか
//    * Extension/（Kotone Bridge）が同梱されているか
//    * Kotone Bridge を読み込めたか、manifest のエラー
//    * 読み込み済みの拡張機能と、それぞれの実行時エラー
//    * 拡張機能（appex）が同梱されていないこと（LiveContainer で動かす条件）
//

import UIKit

// MARK: - 判定結果

private enum CheckState {
    case pass
    case fail
    case info

    var symbol: String {
        switch self {
        case .pass: return "✅"
        case .fail: return "❌"
        case .info: return "•"
        }
    }
}

private struct Check {
    let state: CheckState
    let title: String
    let detail: String
}

// MARK: - 検査

private enum BundleInspector {

    static func run() -> [Check] {
        var checks: [Check] = []
        let bundle = Bundle.main
        let root = bundle.bundleURL
        let fm = FileManager.default

        // --- 基本情報 -------------------------------------------------------
        checks.append(Check(
            state: .info,
            title: "Bundle Identifier",
            detail: bundle.bundleIdentifier ?? "(unknown)"
        ))
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        checks.append(Check(state: .info, title: "Version", detail: "\(short) (\(build))"))
        checks.append(Check(
            state: .info,
            title: "System",
            detail: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        ))

        // --- 同梱の拡張機能 ---------------------------------------------------
        let manifest = root.appendingPathComponent("Extension/manifest.json")
        checks.append(Check(
            state: fm.fileExists(atPath: manifest.path) ? .pass : .fail,
            title: "Extension/manifest.json",
            detail: fm.fileExists(atPath: manifest.path) ? "同梱済み" : "見つかりません（project.yml の resources を確認）"
        ))

        let engine = WebEngine.shared
        if let context = engine.bridgeContext {
            let ext = context.webExtension
            var detail = "v\(ext.version ?? "?") MV\(ext.manifestVersion) "
                + "background=\(ext.hasBackgroundContent) content=\(ext.hasInjectedContent)"
            if !context.errors.isEmpty {
                detail += "\n    実行時エラー: " + context.errors.map { $0.localizedDescription }.joined(separator: " / ")
            }
            checks.append(Check(state: .pass, title: "Kotone Bridge 読み込み", detail: detail))
        } else {
            checks.append(Check(
                state: .fail,
                title: "Kotone Bridge 読み込み",
                detail: engine.bridgeLoadErrors.isEmpty ? "未読み込み" : engine.bridgeLoadErrors.joined(separator: " / ")
            ))
        }
        if !engine.bridgeLoadErrors.isEmpty, engine.bridgeContext != nil {
            checks.append(Check(
                state: .fail,
                title: "Kotone Bridge manifest",
                detail: engine.bridgeLoadErrors.joined(separator: " / ")
            ))
        }
        let bridge = KotoneBridge.shared
        checks.append(Check(
            state: .info,
            title: "Kotone Bridge 接続",
            detail: bridge.isExtensionConnected
                ? "接続中 v\(bridge.extensionVersion ?? "?")"
                : "未接続（操作時に background を起こします）"
        ))

        // --- 取り込んだ拡張機能 ----------------------------------------------
        let contexts = engine.controller.extensionContexts
        checks.append(Check(
            state: .info,
            title: "読み込み済みの拡張機能",
            detail: "\(contexts.count) 個: "
                + contexts.map { $0.webExtension.displayName ?? $0.uniqueIdentifier }.sorted().joined(separator: ", ")
        ))
        // 取り込んだ拡張機能ごとの状態（rev.59）。広告が消えないときに見る。
        for record in AddonController.shared.records {
            guard let context = AddonController.shared.contexts[record.id] else { continue }
            let ext = context.webExtension
            var detail = "base=\(context.baseURL.absoluteString)"
                + "\n    background=\(ext.hasBackgroundContent) content=\(ext.hasInjectedContent)"
                + " dnr=\(ext.hasContentModificationRules) allURLs=\(context.hasAccessToAllURLs)"
                + "\n    background 起動: \(AddonController.shared.wakeResults[record.id] ?? "未実行")"
            if !context.errors.isEmpty {
                detail += "\n    実行時エラー: " + context.errors.map { $0.localizedDescription }.joined(separator: " / ")
            }
            checks.append(Check(
                state: context.errors.isEmpty ? .pass : .fail,
                title: record.displayName,
                detail: detail
            ))
        }
        for (id, error) in AddonController.shared.loadErrors.sorted(by: { $0.key < $1.key }) {
            checks.append(Check(state: .fail, title: "読み込み失敗 \(id)", detail: error))
        }

        // --- appex が無いこと（LiveContainer は App Extension を起動できない） --
        let plugIns = root.appendingPathComponent("PlugIns")
        let appexNames = (try? fm.contentsOfDirectory(atPath: plugIns.path))?
            .filter { $0.hasSuffix(".appex") }
            .sorted() ?? []
        checks.append(Check(
            state: appexNames.isEmpty ? .pass : .info,
            title: "PlugIns/*.appex",
            detail: appexNames.isEmpty
                ? "なし（単一プロセスのアプリとして LiveContainer で動かせる構成）"
                : appexNames.joined(separator: ", ")
        ))

        // --- バンドル総サイズ --------------------------------------------------
        if let total = directorySize(at: root) {
            checks.append(Check(state: .info, title: "Bundle size", detail: byteString(total)))
        }

        return checks
    }

    // MARK: ヘルパ

    private static func directorySize(at url: URL) -> Int64? {
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let item as URL in e {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - 画面

final class DiagnosticsViewController: UIViewController {

    private let textView = UITextView()
    private var report: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "バンドル診断"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .action,
                target: self,
                action: #selector(share)
            ),
            UIBarButtonItem(
                barButtonSystemItem: .refresh,
                target: self,
                action: #selector(reload)
            ),
        ]

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        reload()
    }

    @objc private func reload() {
        var lines: [String] = []
        var failures = 0

        for check in BundleInspector.run() {
            if check.state == .fail { failures += 1 }
            lines.append("\(check.state.symbol) \(check.title)")
            lines.append("    \(check.detail)")
            lines.append("")
        }

        let header: String
        if failures == 0 {
            header = "Checks: すべて通過\n"
                   + String(repeating: "─", count: 40) + "\n"
        } else {
            header = "Checks: \(failures) 件の失敗\n"
                   + String(repeating: "─", count: 40) + "\n"
        }

        report = header + "\n" + lines.joined(separator: "\n")
        textView.text = report
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        let vc = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = sender
        present(vc, animated: true)
    }
}
