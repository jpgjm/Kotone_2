//
//  main.swift
//  Kotone
//
//  rev.55 までは GeckoRuntime.main() から起動していた（XPCOM の初期化を
//  経てから UIKit のイベントループに入る必要があったため）。
//  rev.56 で WKWebView に置き換えたので、普通の UIApplicationMain に戻した。
//  AppDelegate に @main を付けない構成はそのまま残す（ファイル数を変えないため）。
//

import UIKit

_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
