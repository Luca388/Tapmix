import AppKit
import Observation
import SwiftUI

/// 앱이 어떻게 보이는지 (메뉴바만 / 창 / Dock 아이콘) 를 관리한다.
@MainActor
@Observable
final class AppPresentation {
    static let windowID = "main"

    /// Dock 에 항상 아이콘 표시 (꺼져 있어도 창이 열려 있는 동안엔 표시된다)
    var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyActivationPolicy()
        }
    }
    /// 창을 다른 앱 위에 항상 띄우기
    var keepWindowOnTop: Bool {
        didSet { UserDefaults.standard.set(keepWindowOnTop, forKey: "keepWindowOnTop") }
    }
    /// 앱 시작 시 창을 바로 열기
    var openWindowAtLaunch: Bool {
        didSet { UserDefaults.standard.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") }
    }

    private(set) var isWindowOpen = false

    init() {
        let defaults = UserDefaults.standard
        showInDock = defaults.bool(forKey: "showInDock")
        keepWindowOnTop = defaults.object(forKey: "keepWindowOnTop") as? Bool ?? true
        openWindowAtLaunch = defaults.bool(forKey: "openWindowAtLaunch")
        applyActivationPolicy()
    }

    func windowDidAppear() {
        isWindowOpen = true
        applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidDisappear() {
        isWindowOpen = false
        applyActivationPolicy()
    }

    /// LSUIElement 앱이라 기본은 .accessory (Dock 없음). 창이 열리거나 설정이 켜지면 .regular 로 올린다.
    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = (showInDock || isWindowOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
