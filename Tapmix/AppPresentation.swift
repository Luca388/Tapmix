import AppKit
import Observation
import ServiceManagement
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

    /// 로그인 시 자동 실행. 시스템 사운드 메뉴를 대체하려면 켜 두는 게 좋다.
    /// 상태는 시스템(SMAppService)이 들고 있으므로 UserDefaults 에 저장하지 않는다.
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "로그인 항목 설정 실패: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

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
