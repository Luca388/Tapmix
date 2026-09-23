import AudioToolbox
import CoreAudio
import Observation

/// 상단 "출력" 섹션: 출력 장치 목록/선택, 시스템 볼륨, 시스템 음소거.
@MainActor
@Observable
final class OutputDeviceController {
    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let name: String
        let transportType: UInt32

        var isAirPlay: Bool { transportType == kAudioDeviceTransportTypeAirPlay }
        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
        }

        var symbolName: String {
            if isAirPlay { return "airplayaudio" }
            if isBluetooth { return "headphones" }
            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
            case kAudioDeviceTransportTypeUSB: return "cable.connector"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
            default: return "hifispeaker"
            }
        }
    }

    var selectedDevice: Device? { devices.first { $0.id == selectedID } }

    /// 메뉴바 아이콘. 시스템 사운드 메뉴처럼 볼륨에 따라 파동 개수가 바뀐다.
    var menuBarSymbolName: String {
        if isMuted || (hasVolumeControl && volume <= 0.001) { return "speaker.slash.fill" }
        guard hasVolumeControl else { return "speaker.wave.2.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private(set) var devices: [Device] = []
    private(set) var selectedID: AudioObjectID?
    /// 0...1. 장치가 볼륨 컨트롤을 지원하지 않으면 hasVolumeControl == false
    private(set) var volume: Float = 0
    private(set) var isMuted = false
    private(set) var hasVolumeControl = false
    private(set) var hasMuteControl = false

    private let system = AudioHardwareSystem.shared
    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []

    // 'vmvc' — 채널별 볼륨만 있는 장치도 HAL 이 하나의 메인 볼륨처럼 보여준다
    private let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    init() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        systemListeners = selectors.compactMap { selector in
            try? PropertyListener(objectID: system.id, selector: selector) { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
        refreshDevices()
    }

    // MARK: - Devices

    func refreshDevices() {
        let all = (try? system.devices) ?? []
        devices = all.compactMap { device in
            guard let config = try? device.outputStreamConfiguration,
                  config.contains(where: { $0.mNumberChannels > 0 }),
                  (try? device.isHidden) != true,
                  // 우리가 만든 private aggregate ("Tapmix Tap") 는 만든 프로세스에겐 보인다 — 숨긴다
                  !Self.isOwnAggregate(device)
            else { return nil }
            return Device(
                id: device.id,
                name: (try? device.name) ?? "알 수 없는 장치",
                transportType: Self.read(UInt32.self, device.id, PropertyAddress(kAudioDevicePropertyTransportType)) ?? 0
            )
        }

        if let current = try? system.defaultOutputDevice, Self.isOwnAggregate(current) {
            // 어쩌다 우리 aggregate 가 기본 출력이 됐다면 첫 번째 실제 장치로 되돌린다
            if let fallback = devices.first {
                try? system.setDefaultOutputDevice(AudioHardwareDevice(id: fallback.id))
            }
        }
        selectedID = try? system.defaultOutputDevice?.id
        watchSelectedDevice()
        refreshVolume()
    }

    func select(deviceID: AudioObjectID) {
        guard deviceID != selectedID else { return }
        try? system.setDefaultOutputDevice(AudioHardwareDevice(id: deviceID))
        // 리스너가 refreshDevices 를 다시 부르지만, UI 가 바로 반응하도록 먼저 반영
        selectedID = deviceID
    }

    private static func isOwnAggregate(_ device: AudioHardwareDevice) -> Bool {
        ((try? device.uid) ?? "").hasPrefix(ProcessTap.aggregateUIDPrefix)
    }

    private func watchSelectedDevice() {
        deviceListeners = []
        guard let id = selectedID else { return }
        let selectors = [volumeSelector, kAudioDevicePropertyMute]
        deviceListeners = selectors.compactMap { selector in
            try? PropertyListener(objectID: id, selector: selector, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                MainActor.assumeIsolated { self?.refreshVolume() }
            }
        }
    }

    // MARK: - Volume / mute

    func refreshVolume() {
        guard let id = selectedID else {
            hasVolumeControl = false
            hasMuteControl = false
            return
        }
        let volumeAddress = PropertyAddress(volumeSelector, scope: kAudioObjectPropertyScopeOutput)
        hasVolumeControl = AudioObjectHasProperty(id, [volumeAddress])
        volume = hasVolumeControl ? (Self.read(Float.self, id, volumeAddress) ?? 0) : 0

        if let muteAddress = Self.muteAddress(for: id) {
            hasMuteControl = true
            isMuted = (Self.read(UInt32.self, id, muteAddress) ?? 0) != 0
        } else {
            hasMuteControl = false
            isMuted = false
        }
    }

    func setVolume(_ value: Float) {
        guard let id = selectedID, hasVolumeControl else { return }
        let clamped = min(max(value, 0), 1)
        Self.write(clamped, id, PropertyAddress(volumeSelector, scope: kAudioObjectPropertyScopeOutput))
        volume = clamped
    }

    func toggleMute() {
        guard let id = selectedID, let address = Self.muteAddress(for: id) else { return }
        let next: UInt32 = isMuted ? 0 : 1
        Self.write(next, id, address)
        isMuted = next != 0
    }

    /// 메인 엘리먼트에 mute 가 있으면 그걸, 없으면 1번 채널 것을 쓴다 (많은 USB DAC 이 그렇다)
    private static func muteAddress(for id: AudioObjectID) -> AudioObjectPropertyAddress? {
        let candidates = [
            PropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput),
            PropertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: 1),
        ]
        return candidates.first { AudioObjectHasProperty(id, [$0]) }
    }

    // MARK: - HAL property helpers

    private static func read<T>(_: T.Type, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let err = AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        return err == noErr ? pointer.pointee : nil
    }

    private static func write<T>(_ value: T, _ id: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        var value = value
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}
