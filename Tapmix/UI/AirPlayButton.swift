import AVKit
import SwiftUI

/// 시스템이 그려주는 AirPlay 경로 선택 버튼 (AVRoutePickerView).
///
/// AirPlay 수신기 목록은 공개 Core Audio API 로 얻을 수 없다 (제어 센터는 비공개 프레임워크를 쓴다).
/// 대신 이 뷰가 시스템 AirPlay 메뉴를 띄워주고, 사용자가 수신기를 고르면 HAL 에 AirPlay 장치가 생겨
/// 기본 출력이 바뀐다 → OutputDeviceController / AudioProcessMonitor 의 리스너가 알아서 따라간다.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        view.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        view.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
