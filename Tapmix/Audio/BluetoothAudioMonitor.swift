import Foundation
import IOBluetooth
import Observation

/// 페어링된 블루투스 오디오 기기 (연결 여부와 무관)
struct BluetoothAudioDevice: Identifiable, Hashable {
    /// IOBluetooth 형식: "aa-bb-cc-dd-ee-ff"
    let address: String
    let name: String
    let isConnected: Bool

    var id: String { address }

    /// 비교용: 소문자 hex 12자리
    var normalizedAddress: String { Self.normalize(address) }

    var symbolName: String {
        let lowered = name.lowercased()
        guard lowered.contains("airpods") else { return "headphones" }
        if lowered.contains("max") { return "airpodsmax" }
        if lowered.contains("pro") { return "airpodspro" }
        return "airpods"
    }

    /// HAL 장치 UID ("AA-BB-CC-DD-EE-FF:output") 나 이름으로 같은 기기인지 판단
    func matches(halUID: String, halName: String) -> Bool {
        Self.normalize(halUID).contains(normalizedAddress) || halName == name
    }

    static func normalize(_ string: String) -> String {
        string.lowercased().filter(\.isHexDigit)
    }
}

/// IOBluetooth 의 페어링 목록에서 오디오 기기만 골라 보여주고, 연결을 연다.
///
/// 페어링 목록은 bluetoothd 가 들고 있는 캐시라 읽는 비용이 거의 없다 (배터리 조회 같은 외부 프로세스 없음). 폴링하지 않고
/// 팝오버가 열릴 때와 오디오 장치 목록이 바뀔 때만 다시 읽는다.
@MainActor
@Observable
final class BluetoothAudioMonitor {
    private(set) var devices: [BluetoothAudioDevice] = []
    /// 연결 시도 중인 기기 주소
    private(set) var connectingAddress: String?
    private(set) var connectError: String?

    private var connectTimeout: DispatchWorkItem?
    private let connectionTarget = ConnectionTarget()

    private var isRefreshing = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // 첫 호출은 블루투스 권한 응답을 기다리며 블록되므로 메인 스레드에서 부르지 않는다
        Task.detached(priority: .utility) {
            let result = Self.readPairedAudioDevices()
            await MainActor.run {
                self.isRefreshing = false
                self.devices = result
            }
        }
    }

    nonisolated private static func readPairedAudioDevices() -> [BluetoothAudioDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired
            .filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) }
            .compactMap { device in
                guard let address = device.addressString, let name = device.name else { return nil }
                return BluetoothAudioDevice(address: address, name: name, isConnected: device.isConnected())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func device(forHALUID uid: String, name: String) -> BluetoothAudioDevice? {
        devices.first { $0.matches(halUID: uid, halName: name) }
    }

    /// 페어링만 되어 있고 연결 안 된 기기에 연결한다. 연결되면 HAL 에 오디오 장치가 생긴다.
    func connect(_ device: BluetoothAudioDevice, onTimeout: @escaping @MainActor () -> Void) {
        guard connectingAddress == nil,
              let bluetoothDevice = IOBluetoothDevice(addressString: device.address)
        else { return }

        connectError = nil
        connectingAddress = device.address
        connectionTarget.onComplete = { [weak self] status in
            guard let self, status != kIOReturnSuccess else { return }
            self.finishConnecting(error: "\(device.name) 에 연결하지 못했습니다.")
        }
        // 비동기 버전: 즉시 반환하고 connectionComplete(_:status:) 로 결과가 온다
        if bluetoothDevice.openConnection(connectionTarget) != kIOReturnSuccess {
            finishConnecting(error: "\(device.name) 에 연결하지 못했습니다.")
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connectingAddress == device.address else { return }
                self.finishConnecting(error: "\(device.name) 연결 시간이 초과되었습니다.")
                onTimeout()
            }
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    /// HAL 에 해당 기기의 오디오 장치가 나타났을 때 부른다
    func finishConnecting(error: String? = nil) {
        connectTimeout?.cancel()
        connectTimeout = nil
        connectingAddress = nil
        connectError = error
        refresh()
    }
}

/// IOBluetoothDevice.openConnection(_:) 의 콜백 대상
private final class ConnectionTarget: NSObject {
    var onComplete: (@MainActor (IOReturn) -> Void)?

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let handler = onComplete
        Task { @MainActor in handler?(status) }
    }
}
