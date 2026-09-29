import SwiftUI

/// 앱 목록 맨 위의 "모든 앱" 마스터 슬라이더. 모든 앱 볼륨에 곱해진다 (앱 사이 비율 유지).
/// 시스템 볼륨과 달리 출력 장치 볼륨은 건드리지 않는다.
struct MasterRowView: View {
    let monitor: AudioProcessMonitor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                Text("모든 앱")
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    MuteButton(isMuted: monitor.isMasterMuted) {
                        monitor.toggleMasterMute()
                    }
                    Slider(
                        value: Binding(get: { monitor.masterVolume }, set: { monitor.setMasterVolume($0) }),
                        in: 0...1
                    )
                    PercentLabel(value: monitor.masterVolume)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .opacity(monitor.isMasterMuted ? 0.6 : 1)
        .help("재생 중인 모든 앱의 볼륨을 같은 비율로 조절합니다")
    }
}
