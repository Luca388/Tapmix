import SwiftUI

@main
struct TapmixApp: App {
    @State private var monitor = AudioProcessMonitor()
    @State private var output = OutputDeviceController()
    @State private var presentation = AppPresentation()

    var body: some Scene {
        // 1) 메뉴바 팝오버
        MenuBarExtra("Tapmix", systemImage: "speaker.wave.2.fill") {
            MainPopoverView(monitor: monitor, output: output, presentation: presentation, mode: .popover)
        }
        .menuBarExtraStyle(.window)

        // 2) SoundSource 처럼 떼어낼 수 있는 독립 창 (기본은 항상 위에 떠 있음)
        Window("Tapmix", id: AppPresentation.windowID) {
            MainPopoverView(monitor: monitor, output: output, presentation: presentation, mode: .window)
                .onAppear { presentation.windowDidAppear() }
                .onDisappear { presentation.windowDidDisappear() }
        }
        .windowResizability(.contentSize)
        .windowLevel(presentation.keepWindowOnTop ? .floating : .normal)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(presentation.openWindowAtLaunch ? .presented : .suppressed)
    }
}
