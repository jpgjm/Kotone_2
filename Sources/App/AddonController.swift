//
//  AddonController.swift
//  Kotone — 取り込んだ拡張機能（WKWebExtension）の管理
//
//  rev.56 で Gecko の AddonRuntime（AMO から .xpi を入れる）から置き換えた。
//
//  取り込み方: 「ファイル」から拡張機能のフォルダか ZIP を選ぶ。
//    * フォルダ … manifest.json がある展開済みのもの（unpacked）
//    * ZIP      … manifest.json を含むもの（Chrome Web Store の .crx は不可）
//  WKWebExtension(resourceBaseURL:) はフォルダと ZIP の両方を受け付ける
//  （WKWebExtension.h の extensionWithResourceBaseURL:）。
//
//  保存先: Application Support/Extensions/<id>/ または <id>.zip
//  一覧:   UserDefaults "kotone.extensions"（id・ファイル名・有効/無効・表示名）
//  権限:   取り込み時に利用者が一覧を見て承諾したものとして、
//          manifest の要求をすべて許可する（WebEngine.grantRequestedPermissions）。
//  base URL: safari-web-extension://<id>/（rev.59。WebEngine.importedExtensionScheme）
//  準備:   読み込んだら background を起こしてから再生用ページを開く・読み直す（rev.59）
//

import Foundation
import WebKit

struct ExtensionRecord: Codable, Equatable {
    /// context の uniqueIdentifier にも使う（保存領域が起動ごとに変わらないように）
    let id: String
    /// Extensions/ の中のファイル名またはフォルダ名
    let fileName: String
    var displayName: String
    var enabled: Bool
}

/// 取り込み途中の拡張機能。承諾されたら commit する。
struct PendingExtension {
    let record: ExtensionRecord
    let webExtension: WKWebExtension
    let storedURL: URL
}

@MainActor
final class AddonController {

    static let shared = AddonController()

    private(set) var records: [ExtensionRecord] = []
    /// 読み込み済みの context（id → context）
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    /// 読み込みに失敗した理由（id → 文言）
    private(set) var loadErrors: [String: String] = [:]
    /// 最後に background を起こした結果（id → 文言）。診断画面で表示する。
    private(set) var wakeResults: [String: String] = [:]

    private let defaultsKey = "kotone.extensions"
    private let log = MeasurementLog.shared

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            do {
                records = try JSONDecoder().decode([ExtensionRecord].self, from: data)
            } catch {
                // 壊れた一覧は空で上書きしない。退避してから空で始める。
                log.append(.error, "[addon] 一覧を読めません。\(defaultsKey).corrupt に退避: \(error)")
                UserDefaults.standard.set(data, forKey: defaultsKey + ".corrupt")
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    private var storageDirectory: URL {
        get throws {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let dir = base.appendingPathComponent("Extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            log.append(.error, "[addon] 一覧を保存できません: \(error)")
        }
        NotificationCenter.default.post(name: .kotoneExtensionsDidChange, object: nil)
    }

    // MARK: - 起動時

    /// 有効なものを読み込む。WebEngine.start() から呼ばれる。
    func loadInstalled(into controller: WKWebExtensionController) async {
        for record in records where record.enabled {
            await load(record, into: controller)
        }
    }

    private func load(_ record: ExtensionRecord, into controller: WKWebExtensionController) async {
        do {
            let url = try storageDirectory.appendingPathComponent(record.fileName)
            let ext = try await WKWebExtension(resourceBaseURL: url)
            try load(ext, record: record, into: controller)
        } catch {
            loadErrors[record.id] = WebEngine.describe(error)
            log.append(.error, "[addon] \(record.displayName) を読み込めません: \(loadErrors[record.id]!)")
        }
    }

    private func load(_ ext: WKWebExtension, record: ExtensionRecord, into controller: WKWebExtensionController) throws {
        for e in ext.errors {
            log.append(.error, "[addon] \(record.displayName) manifest: \(e.localizedDescription)")
        }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = record.id
        // Safari 向けの拡張機能が Safari 用の処理を選べるようにする（WebEngine.importedExtensionScheme）。
        // 読み込む前にしか変えられない（WKWebExtensionContext.h の baseURL）。
        if let baseURL = URL(string: "\(WebEngine.importedExtensionScheme)://\(record.id)/") {
            context.baseURL = baseURL
        } else {
            log.append(.error, "[addon] base URL を作れません（既定のまま）: \(record.id)")
        }
        context.isInspectable = true
        WebEngine.grantRequestedPermissions(context)
        try controller.load(context)
        contexts[record.id] = context
        loadErrors[record.id] = nil
        log.append(
            .addon,
            "読み込み: \(record.displayName) v\(ext.version ?? "?") MV\(ext.manifestVersion) "
                + "base=\(context.baseURL.absoluteString) "
                + "background=\(ext.hasBackgroundContent) content=\(ext.hasInjectedContent) "
                + "dnr=\(ext.hasContentModificationRules) allURLs=\(context.hasAccessToAllURLs)"
        )
    }

    // MARK: - 準備（rev.59）

    /// 有効な拡張機能の background を起こし、読み込み完了を待つ。WebEngine.start() から呼ばれる。
    ///
    /// WebKit は context の読み込み後に、登録済みスクリプトと declarativeNetRequest のルールを
    /// 非同期に読む。background の読み込みはその後に積まれるので、完了を待てば
    /// 最初のページを開く時点でそれらが入っている（順序からの判断。完了を知らせる API は無い）。
    /// uBlock Origin Lite は background の起動時に、登録済みスクリプトが無ければ登録し直す。
    func wakeEnabled() async {
        // 1 つずつ待つ（ふつうは uBlock Origin Lite の 1 つだけ）。
        for record in records {
            guard let context = contexts[record.id] else { continue }
            await wake(record, context: context)
        }
    }

    private func wake(_ record: ExtensionRecord, context: WKWebExtensionContext) async {
        guard context.webExtension.hasBackgroundContent else {
            wakeResults[record.id] = "background なし"
            return
        }
        let started = Date()
        let error = await WebEngine.loadBackground(context, timeout: 10)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let error {
            let text = WebEngine.describe(error)
            wakeResults[record.id] = "❌ \(text)（\(ms)ms）"
            log.append(.error, "[addon] \(record.displayName) の background を起こせません: \(text)（\(ms)ms）")
        } else {
            wakeResults[record.id] = "✅ \(ms)ms"
            log.append(.addon, "background 起動: \(record.displayName)（\(ms)ms）")
        }
    }

    /// 取り込み・有効化した拡張機能の準備を待って、再生用ページを読み直させる。
    ///
    /// 読み直すのは BrowserViewController（再生中なら読み直さない）。
    /// uBlock Origin Lite は取り込み直後の初回、ルールの変換と
    /// スクリプトの登録に時間がかかるので、この読み直しでは効かないことがある。
    private func applyToPlayerPage(_ id: String) async {
        guard let index = records.firstIndex(where: { $0.id == id }),
              let context = contexts[id] else { return }
        await wake(records[index], context: context)
        NotificationCenter.default.post(name: .kotoneReloadPlayerPage, object: nil)
    }

    // MARK: - 取り込み

    /// 選ばれたフォルダか ZIP をアプリ内へ複製し、拡張機能として読めるか確かめる。
    /// まだ読み込まない（利用者が権限を承諾してから commit する）。
    func prepareImport(from source: URL) async throws -> PendingExtension {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let id = UUID().uuidString.lowercased()
        let fileName = isDirectory ? id : "\(id).zip"
        let destination = try storageDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        log.append(.addon, "取り込み: \(source.lastPathComponent) → \(fileName)")

        do {
            let ext = try await WKWebExtension(resourceBaseURL: destination)
            let name = ext.displayName ?? source.deletingPathExtension().lastPathComponent
            let record = ExtensionRecord(id: id, fileName: fileName, displayName: name, enabled: true)
            return PendingExtension(record: record, webExtension: ext, storedURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// 承諾された拡張機能を一覧に加えて読み込む。
    func commit(_ pending: PendingExtension) throws {
        try load(pending.webExtension, record: pending.record, into: WebEngine.shared.controller)
        records.append(pending.record)
        save()
        Task { await applyToPlayerPage(pending.record.id) }
    }

    /// 承諾されなかった拡張機能の複製を消す。
    func discard(_ pending: PendingExtension) {
        do {
            try FileManager.default.removeItem(at: pending.storedURL)
        } catch {
            log.append(.error, "[addon] 取り込みの取り消しで削除できません: \(error)")
        }
    }

    // MARK: - 有効 / 無効 / 削除

    func setEnabled(_ enabled: Bool, for id: String) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].enabled = enabled
        let controller = WebEngine.shared.controller
        if enabled {
            await load(records[index], into: controller)
            Task { await applyToPlayerPage(id) }
        } else if let context = contexts.removeValue(forKey: id) {
            do {
                try controller.unload(context)
                log.append(.addon, "無効化: \(records[index].displayName)")
            } catch {
                log.append(.error, "[addon] unload 失敗: \(WebEngine.describe(error))")
            }
        }
        save()
    }

    /// 一覧と保存したファイルを消す。拡張機能の保存データ（storage 等）は残る。
    func remove(id: String) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        if let context = contexts.removeValue(forKey: id) {
            try WebEngine.shared.controller.unload(context)
        }
        try FileManager.default.removeItem(at: try storageDirectory.appendingPathComponent(record.fileName))
        records.remove(at: index)
        loadErrors[id] = nil
        save()
        log.append(.addon, "削除: \(record.displayName)")
    }
}
