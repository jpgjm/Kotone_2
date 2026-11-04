//
//  AddonsViewController.swift
//  Kotone — 拡張機能の管理画面
//
//  rev.56 で Gecko のアドオン画面（AMO から .xpi）を WKWebExtension 用に置き換えた。
//
//  やれること:
//    * Kotone Bridge の状態表示と疎通テスト
//    * PlayerManager を通しで試す / URL 指定で曲を再生
//    * 取り込んだ拡張機能の一覧・有効/無効・ポップアップ・設定ページ・削除
//    * 「ファイル」から拡張機能（フォルダか ZIP）を取り込む
//

import UIKit
import UniformTypeIdentifiers
import WebKit

final class AddonsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case bridge
        case player
        case installed
        case importing

        var title: String {
            switch self {
            case .bridge:    return "Kotone Bridge"
            case .player:    return "PlayerManager"
            case .installed: return "取り込んだ拡張機能"
            case .importing: return "追加"
            }
        }
    }

    private var addons: AddonController { .shared }
    private let log = MeasurementLog.shared

    // MARK: - Lifecycle

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "拡張機能"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(reload)
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .kotoneExtensionsDidChange, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .importing:
            return "展開済みのフォルダ（manifest.json があるもの）か ZIP を選びます。"
                + "取り込む前に、拡張機能が求める権限とサイトを表示します。"
        case .installed:
            return "拡張機能はこのアプリの 1 つの WKWebView（音楽の再生にも使っているページ）で動きます。"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .bridge:    return 2
        case .player:    return 2
        case .installed: return max(addons.records.count, 1)
        case .importing: return 1
        case .none:      return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        cell.detailTextLabel?.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .bridge:
            if indexPath.row == 0 {
                let engine = WebEngine.shared
                let bridge = KotoneBridge.shared
                cell.textLabel?.text = engine.bridgeContext == nil ? "❌ 読み込めていません" : "✅ 読み込み済み"
                var detail = bridge.isExtensionConnected
                    ? "接続中 v\(bridge.extensionVersion ?? "?")"
                    : "未接続（操作したときに background を起こして接続します）"
                if !engine.bridgeLoadErrors.isEmpty {
                    detail += "\n" + engine.bridgeLoadErrors.joined(separator: "\n")
                }
                cell.detailTextLabel?.text = detail
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = "ブリッジ疎通テスト"
                cell.detailTextLabel?.text = "ページ情報を取得して結果を表示します"
                cell.accessoryType = .disclosureIndicator
            }

        case .player:
            if indexPath.row == 0 {
                cell.textLabel?.text = "PlayerManager を通しで試す"
                cell.detailTextLabel?.text = "pause → play → seek → 状態確認"
            } else {
                cell.textLabel?.text = "URL 指定で曲を再生"
                cell.detailTextLabel?.text = "videoId か YouTube の URL を PlayerManager.play に渡す"
            }
            cell.accessoryType = .disclosureIndicator

        case .installed:
            guard !addons.records.isEmpty else {
                cell.textLabel?.text = "まだありません"
                cell.detailTextLabel?.text = "下の「ファイルから取り込む」で追加してください"
                cell.selectionStyle = .none
                return cell
            }
            let record = addons.records[indexPath.row]
            cell.textLabel?.text = record.displayName
            var detail: String
            if let context = addons.contexts[record.id] {
                let ext = context.webExtension
                detail = "v\(ext.version ?? "?") ・ MV\(ext.manifestVersion)"
                    + "\nネットワーク規則 \(ext.hasContentModificationRules ? "あり" : "なし")"
                    + " ・ 全サイト \(context.hasAccessToAllURLs ? "許可" : "未許可")"
                if let wake = addons.wakeResults[record.id] {
                    detail += "\nbackground: \(wake)"
                }
                if !context.errors.isEmpty {
                    detail += "\n⚠️ " + context.errors.map { $0.localizedDescription }.joined(separator: "\n⚠️ ")
                }
            } else if let error = addons.loadErrors[record.id] {
                detail = "❌ \(error)"
            } else {
                detail = "無効"
            }
            cell.detailTextLabel?.text = detail
            let toggle = UISwitch()
            toggle.isOn = record.enabled
            toggle.addAction(UIAction { [weak self] action in
                guard let sender = action.sender as? UISwitch else { return }
                Task { @MainActor in
                    await self?.addons.setEnabled(sender.isOn, for: record.id)
                    self?.reload()
                }
            }, for: .valueChanged)
            cell.accessoryView = toggle

        case .importing:
            cell.textLabel?.text = "「ファイル」から取り込む…"
            cell.textLabel?.textColor = .tintColor

        case .none:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .bridge:
            if indexPath.row == 1 { runBridgeProbe() }
        case .player:
            if indexPath.row == 0 { runPlayerManagerTest() } else { promptForVideoId() }
        case .installed:
            guard addons.records.indices.contains(indexPath.row) else { return }
            showActions(for: addons.records[indexPath.row], at: indexPath)
        case .importing:
            pickExtension()
        case .none:
            break
        }
    }

    // MARK: - 取り込んだ拡張機能の操作

    private func showActions(for record: ExtensionRecord, at indexPath: IndexPath) {
        let sheet = UIAlertController(title: record.displayName, message: nil, preferredStyle: .actionSheet)
        if let context = addons.contexts[record.id] {
            let ext = context.webExtension
            if context.action(for: WebEngine.shared.playerTab)?.presentsPopup == true {
                sheet.addAction(UIAlertAction(title: "ポップアップを開く", style: .default) { _ in
                    context.performAction(for: WebEngine.shared.playerTab)
                })
            }
            if ext.hasOptionsPage, let url = context.optionsPageURL {
                sheet.addAction(UIAlertAction(title: "設定ページ", style: .default) { _ in
                    WebEngine.shared.presentExtensionPage(url, context: context, title: "設定")
                })
            }
            sheet.addAction(UIAlertAction(title: "権限とサイト", style: .default) { [weak self] _ in
                self?.showInfo(title: record.displayName, message: Self.permissionSummary(ext))
            })
        }
        sheet.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            self?.confirmRemove(record)
        })
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func confirmRemove(_ record: ExtensionRecord) {
        let alert = UIAlertController(
            title: "\(record.displayName) を削除しますか？",
            message: "取り込んだファイルを消します。元に戻せません。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            do {
                try self?.addons.remove(id: record.id)
            } catch {
                self?.log.append(.error, "[addon] 削除失敗: \(WebEngine.describe(error))")
                self?.showInfo(title: "削除できません", message: error.localizedDescription)
            }
            self?.reload()
        })
        present(alert, animated: true)
    }

    // MARK: - 取り込み

    private func pickExtension() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func importExtension(from url: URL) {
        Task { @MainActor in
            let pending: PendingExtension
            do {
                pending = try await addons.prepareImport(from: url)
            } catch {
                log.append(.error, "[addon] 取り込み失敗: \(WebEngine.describe(error))")
                showInfo(title: "取り込めません", message: WebEngine.describe(error))
                return
            }
            confirmImport(pending)
        }
    }

    /// 権限とサイトを見せて承諾を取る。承諾されたら全部許可して読み込む。
    private func confirmImport(_ pending: PendingExtension) {
        let ext = pending.webExtension
        var message = Self.permissionSummary(ext)
        if !ext.errors.isEmpty {
            message += "\n\n⚠️ manifest の問題:\n" + ext.errors.map { $0.localizedDescription }.joined(separator: "\n")
        }
        let alert = UIAlertController(
            title: "\(pending.record.displayName) v\(ext.version ?? "?") を追加しますか？",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
            self?.addons.discard(pending)
        })
        alert.addAction(UIAlertAction(title: "許可して追加", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try self.addons.commit(pending)
            } catch {
                self.log.append(.error, "[addon] 読み込み失敗: \(WebEngine.describe(error))")
                self.addons.discard(pending)
                self.showInfo(title: "読み込めません", message: WebEngine.describe(error))
            }
            self.reload()
        })
        present(alert, animated: true)
    }

    private static func permissionSummary(_ ext: WKWebExtension) -> String {
        let permissions = ext.requestedPermissions.map(\.rawValue).sorted()
        let sites = ext.allRequestedMatchPatterns.map(\.string).sorted()
        return """
            権限: \(permissions.isEmpty ? "なし" : permissions.joined(separator: ", "))
            サイト: \(sites.isEmpty ? "なし" : sites.joined(separator: ", "))
            """
    }

    private func showInfo(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - 疎通テスト

    /// SwiftUI(UIKit) → KotoneBridge → background.js → content.js（→ page.js）→ ページ
    /// の往復が通るかを 1 タップで確かめる。
    private func runBridgeProbe() {
        let alert = UIAlertController(title: "疎通テスト", message: "実行中…", preferredStyle: .alert)
        present(alert, animated: true)

        Task { @MainActor in
            let bridge = KotoneBridge.shared
            var body: String
            do {
                // 1. 単純な往復（background まで）
                let pong = try await bridge.request("ping")
                // 2. content script までの往復。pageWorld は page.js（MAIN world）の応答
                let probe = try await bridge.probe()
                // 3. ページ自身が持っている再生情報（page.js 経由）
                let pageInfo: String
                do { pageInfo = format(try await bridge.playerResponseInfo()) } catch { pageInfo = "❌ \(error.localizedDescription)" }
                // 4. ループ / シャッフルの状態（page.js 経由）
                let repeatInfo: String
                do { repeatInfo = format(try await bridge.request("repeatState")) } catch { repeatInfo = "❌ \(error.localizedDescription)" }
                // 5. 実際にページを操作できるか。曲を開く前は再生できないので省く。
                let control: String
                let videoInfo = (probe as? [String: Any])?["video"] as? [String: Any]
                let hasSource = !((videoInfo?["src"] as? String) ?? "").isEmpty
                if hasSource {
                    let toggled = try await bridge.togglePlayPause()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let restored = try await bridge.togglePlayPause()
                    control = "\(format(toggled)) → \(format(restored))"
                } else {
                    control = "省略（曲が読み込まれていません。曲を再生してから試してください）"
                }

                body = """
                    ✅ 往復成功

                    ping: \(format(pong))

                    probe:
                    \(format(probe))

                    再生制御: \(control)

                    ページの再生情報:
                    \(pageInfo)

                    ループ / シャッフル:
                    \(repeatInfo)
                    """
            } catch {
                body = "❌ \(error.localizedDescription)"
            }
            alert.message = body
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
            self.reload()
        }
    }

    /// PlayerManager を実際に動かして、Views から使える状態かを確かめる。
    private func runPlayerManagerTest() {
        let alert = UIAlertController(title: "PlayerManager", message: "実行中…", preferredStyle: .alert)
        present(alert, animated: true)

        Task { @MainActor in
            let player = PlayerManager.shared

            @MainActor
            func snapshot(_ label: String) -> String {
                let song = player.currentSong
                return """
                    [\(label)]
                      currentSong = \(song?.title ?? "-") / \(song?.artist ?? "-")
                      album       = \(song?.album ?? "-")
                      isPlaying   = \(player.isPlaying)
                      time        = \(String(format: "%.1f", player.currentTime)) \
                    / \(String(format: "%.1f", player.duration))
                      error       = \(player.lastErrorMessage ?? "なし")
                    """
            }

            var lines = [snapshot("開始時")]

            player.pause()
            try? await Task.sleep(nanoseconds: 700_000_000)
            lines.append(snapshot("pause 後"))

            player.resume()
            try? await Task.sleep(nanoseconds: 700_000_000)
            lines.append(snapshot("play 後"))

            let target = max(0, player.currentTime + 10)
            player.seek(to: target)
            try? await Task.sleep(nanoseconds: 900_000_000)
            lines.append(snapshot("seek(+10) 後"))

            alert.message = lines.joined(separator: "\n\n")
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        }
    }

    /// videoId を指定して PlayerManager.play を呼ぶ。
    private func promptForVideoId() {
        let alert = UIAlertController(
            title: "URL 指定で再生",
            message: "videoId または YouTube の URL を入力してください。\n"
                + "youtu.be / watch?v= / shorts のいずれも受け付けます。",
            preferredStyle: .alert
        )
        alert.addTextField {
            $0.placeholder = "nIQko_MvspU または https://youtu.be/…"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "再生", style: .default) { _ in
            guard let text = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            Task { @MainActor in
                let song = Song(
                    id: text,
                    title: text,
                    artist: "",
                    album: nil,
                    albumID: nil,
                    durationSeconds: nil,
                    thumbnailURL: nil,
                    artistID: nil
                )
                await PlayerManager.shared.play(song: song)
                self.navigationController?.popViewController(animated: true)
            }
        })
        present(alert, animated: true)
    }

    private func format(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return String(describing: value) }
        return dict.keys.sorted().map { "  \($0) = \(dict[$0] ?? "nil")" }.joined(separator: "\n")
    }
}

// MARK: - UIDocumentPickerDelegate

extension AddonsViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importExtension(from: url)
    }
}
