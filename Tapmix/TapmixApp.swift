import SwiftUI

@main
struct TapmixApp: App {
    @State private var monitor = AudioProcessMonitor()
    @State private var output = OutputDeviceController()
    @State private var bluetooth = BluetoothAudioMonitor()
    @State private var presentation = AppPresentation()

    var body: some Scene {
        // 1) 메뉴바 팝오버
        MenuBarExtra {
            MainPopoverView(monitor: monitor, output: output, bluetooth: bluetooth, presentation: presentation, mode: .popover)
        } label: {
            // 믹서 페이더 모양 — 스피커 모양인 시스템 사운드 아이콘과 구분된다
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)

        // 2) SoundSource 처럼 떼어낼 수 있는 독립 창 (기본은 항상 위에 떠 있음)
        Window("Tapmix", id: AppPresentation.windowID) {
            MainPopoverView(monitor: monitor, output: output, bluetooth: bluetooth, presentation: presentation, mode: .window)
                .onAppear { presentation.windowDidAppear() }
                .onDisappear { presentation.windowDidDisappear() }
        }
        .windowResizability(.contentSize)
        .windowLevel(presentation.keepWindowOnTop ? .floating : .normal)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(presentation.openWindowAtLaunch ? .presented : .suppressed)
    }
}
