import CoreAudio
import SwiftUI

/// macOS 제어 센터의 "사운드" 메뉴와 같은 모양의 출력 섹션:
/// 볼륨 슬라이더 / 출력 장치 목록 / 사운드 설정…
struct OutputSectionView<Accessory: View>: View {
    let output: OutputDeviceController
    let bluetooth: BluetoothAudioMonitor
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("사운드")
                    .font(.headline)
                Spacer()
                AirPlayButton()
                    .frame(width: 20, height: 20)
                    .help("AirPlay")
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            volumeRow
                .padding(.horizontal, 14)

            Divider()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Text("출력")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            VStack(spacing: 2) {
                ForEach(output.devices) { device in
                    let pairedInfo = bluetooth.device(forHALUID: device.uid, name: device.name)
                    OutputDeviceRow(
                        symbolName: pairedInfo?.symbolName ?? device.symbolName,
                        title: device.name,
                        isSelected: device.id == output.selectedID,
                        isConnecting: false
                    ) {
                        output.select(deviceID: device.id)
                    }
                }

                ForEach(disconnectedBluetooth) { device in
                    OutputDeviceRow(
                        symbolName: device.symbolName,
                        title: device.name,
                        isSelected: false,
                        isConnecting: bluetooth.connectingAddress == device.address
                    ) {
                        connect(device)
                    }
                }
            }
            .padding(.horizontal, 6)

            if let message = bluetooth.connectError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }

            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            MenuRowButton(title: "사운드 설정…") {
                AppPresentation.openSoundSettings()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .onAppear { bluetooth.refresh() }
        .onChange(of: output.devices) { bluetooth.refresh() }
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button {
                output.toggleMute()
            } label: {
                Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(output.isMuted ? .red : .secondary)
            .disabled(!output.hasMuteControl)
            .help(output.isMuted ? "음소거 해제" : "음소거")

            SystemVolumeSlider(
                value: Binding(get: { output.volume }, set: { output.setVolume($0) })
            )
            .disabled(!output.hasVolumeControl)
            .opacity(output.hasVolumeControl ? 1 : 0.4)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
    }

    /// 페어링은 됐지만 지금 오디오 장치로 연결되어 있지 않은 헤드폰/AirPods
    private var disconnectedBluetooth: [BluetoothAudioDevice] {
        bluetooth.devices.filter { paired in
            !output.devices.contains { paired.matches(halUID: $0.uid, halName: $0.name) }
        }
    }

    private func connect(_ device: BluetoothAudioDevice) {
        output.selectWhenConnected(device) {
            bluetooth.finishConnecting()
        }
        bluetooth.connect(device) {
            output.cancelPendingBluetooth()
        }
    }
}

// MARK: - Rows

/// 원형 아이콘 + 이름. 선택된 장치는 아이콘 원이 강조색으로 채워진다.
struct OutputDeviceRow: View {
    let symbolName: String
    let title: String
    let isSelected: Bool
    let isConnecting: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.1))
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .frame(width: 28, height: 28)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
    }
}

/// "사운드 설정…" 처럼 메뉴 항목 모양의 버튼
struct MenuRowButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { isHovering = $0 }
    }
}

// MARK: - Shared controls

/// 제어 센터 스타일의 굵은 캡슐 슬라이더 (value 0...1)
struct SystemVolumeSlider: View {
    @Binding var value: Float

    private let height: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - height, 1)
            let x = CGFloat(min(max(value, 0), 1)) * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: x + height)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: height, height: height)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = (drag.location.x - height / 2) / travel
                        value = Float(min(max(fraction, 0), 1))
                    }
            )
        }
        .frame(height: height)
    }
}

struct MuteButton: View {
    let isMuted: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                .frame(width: 18, height: 18)
                .foregroundStyle(isMuted ? .red : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isMuted ? "음소거 해제" : "음소거")
    }
}

struct PercentLabel: View {
    let value: Float

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
    }
}
