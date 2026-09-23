import SwiftUI

/// 가로 막대형 레벨 미터. level 은 선형 피크(0...1)지만 표시는 dB 스케일(-60...0 dB)로 한다.
/// 선형으로 그리면 보통 음량(-30 dB 근처)이 바의 3% 밖에 안 차서 미터가 죽어 보인다.
struct LevelMeterView: View {
    let level: Float
    let isActive: Bool

    private static let floorDB: Float = -60

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(gradient)
                    .frame(width: geo.size.width * CGFloat(displayFraction))
            }
        }
        .frame(height: 5)
        .animation(.linear(duration: 1.0 / 30.0), value: level)
    }

    private var displayFraction: Float {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return min(max((db - Self.floorDB) / -Self.floorDB, 0), 1)
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: isActive ? [.green, .green, .yellow, .red] : [.gray],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
