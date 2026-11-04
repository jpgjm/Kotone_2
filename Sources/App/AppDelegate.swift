//
//  AppDelegate.swift
//  Kotone
//
//  @main は付けないこと。エントリポイントは main.swift の UIApplicationMain。
//  （rev.55 までは GeckoRuntime.main() 経由だった）
//

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MeasurementLog.shared.append(.info, "app launched — \(MeasurementLog.memoryFootprint())")
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}

    // 測定項目 5・6 用。バックグラウンド遷移の前後でメモリを記録する。
    func applicationDidEnterBackground(_ application: UIApplication) {
        MeasurementLog.shared.append(.info, "background — \(MeasurementLog.memoryFootprint())")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        MeasurementLog.shared.append(.info, "foreground — \(MeasurementLog.memoryFootprint())")
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        MeasurementLog.shared.append(.error, "*** メモリ警告 *** \(MeasurementLog.memoryFootprint())")
    }
}
