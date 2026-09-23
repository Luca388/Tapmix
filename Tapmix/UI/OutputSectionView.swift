import CoreAudio
import SwiftUI

/// 상단 출력 섹션: 장치 선택 + 시스템 볼륨 슬라이더 + 음소거
struct OutputSectionView: View {
    let output: OutputDeviceController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: output.selectedDevice?.symbolName ?? "hifispeaker")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Picker("출력 장치", selection: deviceBinding) {
                    ForEach(output.devices) { device in
                        Label(device.name, systemImage: device.symbolName)
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                AirPlayButton()
                    .frame(width: 22, height: 22)
                    .help("AirPlay")
            }

            HStack(spacing: 8) {
                MuteButton(isMuted: output.isMuted, isEnabled: output.hasMuteControl) {
                    output.toggleMute()
                }
                Slider(value: volumeBinding, in: 0...1)
                    .disabled(!output.hasVolumeControl)
                PercentLabel(value: output.volume)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var deviceBinding: Binding<AudioObjectID?> {
        Binding(
            get: { output.selectedID },
            set: { if let id = $0 { output.select(deviceID: id) } }
        )
    }

    private var volumeBinding: Binding<Float> {
        Binding(get: { output.volume }, set: { output.setVolume($0) })
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
