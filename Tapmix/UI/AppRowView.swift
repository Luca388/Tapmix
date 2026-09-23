import SwiftUI

/// 앱 한 줄: 아이콘, 이름, 레벨미터, 음소거 버튼, 볼륨 슬라이더
struct AppRowView: View {
    /// 팝오버 높이 계산에 쓰이므로 고정값으로 둔다
    static let height: CGFloat = 58

    let app: AudioApp
    let monitor: AudioProcessMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon
                .frame(width: 28, height: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    LevelMeterView(level: app.level, isActive: app.isPlaying && !app.isMuted)
                        .frame(width: 60)
                }

                HStack(spacing: 8) {
                    MuteButton(isMuted: app.isMuted) {
                        monitor.toggleMute(for: app.id)
                    }
                    Slider(value: volumeBinding, in: 0...1)
                    PercentLabel(value: app.volume)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .opacity(app.isMuted ? 0.6 : 1)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeBinding: Binding<Float> {
        Binding(get: { app.volume }, set: { monitor.setVolume($0, for: app.id) })
    }
}
