import AppKit
import Observation
import Sparkle

/// Sparkle 자동 업데이트. 피드는 GitHub 최신 릴리스의 appcast.xml (Info.plist 의 SUFeedURL),
/// 업데이트 파일은 EdDSA 서명(SUPublicEDKey)으로 검증한다. 릴리스는 scripts/make-dmg.sh 가 만든다.
@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        // 메뉴바 전용 앱이라 먼저 앞으로 가져와야 업데이트 창이 다른 창 뒤에 숨지 않는다
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
