import Accelerate
import CoreAudio
import Synchronization

/// 실시간 오디오 스레드와 메인 스레드가 공유하는 상태.
/// IOProc 블록은 self 대신 이 객체만 캡처하므로 ProcessTap 의 deinit 이 정상 동작한다.
final class TapControl: @unchecked Sendable {
    /// 메인 스레드가 쓰고 실시간 스레드가 읽는 목표 게인 (0 = 음소거, 1 = 원음)
    let gain: Atomic<Float>
    /// 마지막 IO 사이클의 출력 피크 (게인 적용 후)
    let peak = Atomic<Float>(0)
    /// 직전 사이클이 끝난 시점의 게인. 실시간 스레드만 만진다 (램프 시작점).
    var lastGain: Float

    init(gain: Float) {
        self.gain = Atomic(gain)
        self.lastGain = gain
    }
}

/// 프로세스 그룹(보통 앱 하나)의 출력을 Core Audio Process Tap 으로 가로채,
/// 원래 경로는 `.muted` 로 끊고 게인을 곱해서 기본 출력 장치로 다시 내보낸다.
///
/// 즉 앱 → (tap, muted) → 우리 IOProc (× gain) → 스피커. 볼륨/음소거는 gain 하나로 처리한다.
final class ProcessTap {
    /// 우리가 만드는 aggregate device 의 UID 접두사. 장치 목록에서 자기 자신을 걸러낼 때 쓴다.
    static let aggregateUIDPrefix = "com.yu.Tapmix.tap."

    let processIDs: [AudioObjectID]
    let control: TapControl

    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "Tapmix.tap.io", qos: .userInteractive)

    init(processIDs: [AudioObjectID], gain: Float) throws {
        self.processIDs = processIDs
        self.control = TapControl(gain: gain)
        do {
            try activate()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
    }

    private func activate() throws {
        // 1. 탭 생성 — 프로세스들의 출력을 스테레오로 믹스다운하고, 원래 출력은 차단
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.uuid = UUID()
        description.name = "Tapmix \(processIDs.map(String.init).joined(separator: ","))"
        description.muteBehavior = .muted
        description.isPrivate = true

        guard let tap = try system.makeProcessTap(description: description) else {
            throw TapError.tapCreationFailed
        }
        self.tap = tap
        if let format = try? tap.format {
            log.notice("tap format: \(format.mSampleRate, privacy: .public)Hz ch=\(format.mChannelsPerFrame, privacy: .public) flags=\(format.mFormatFlags, privacy: .public) bytesPerFrame=\(format.mBytesPerFrame, privacy: .public)")
        }

        // 2. 탭을 입력, 기본 출력 장치를 출력으로 갖는 private aggregate device
        guard let output = try system.defaultOutputDevice else {
            throw TapError.noOutputDevice
        }
        let outputUID = try output.uid
        // 기본 출력이 우리 aggregate 면 (사용자가 실수로 골랐다면) 피드백 루프가 되므로 거부
        guard !outputUID.hasPrefix(Self.aggregateUIDPrefix) else {
            throw TapError.noOutputDevice
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tapmix Tap",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + description.uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw TapError.aggregateCreationFailed
        }
        self.aggregate = aggregate

        // 지연을 줄이기 위해 버퍼를 작게. 실패해도 치명적이지 않으니 무시.
        try? aggregate.setBufferFrameSize(256)

        // 3. IOProc 등록. 실시간 스레드: 할당/락/ObjC/로깅 금지, self 캡처 금지.
        let control = self.control
        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, ioQueue) { _, inInputData, _, outOutputData, _ in
            Self.render(input: inInputData, output: outOutputData, control: control)
        }
        guard err == noErr, let procID else { throw AudioHardwareError(err) }
        self.ioProcID = procID

        try aggregate.start(IOProcID: procID)
        log.notice("aggregate \(aggregate.id, privacy: .public) started, output=\(outputUID, privacy: .public)")
    }

    /// 입력(탭) 채널 n → 출력 채널 n 으로 게인을 곱해 복사한다. 남는 출력 채널은 무음.
    /// 게인은 버퍼 안에서 lastGain → gain 으로 선형 램프를 걸어 클릭음을 막는다.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        control: TapControl
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let targetGain = control.gain.load(ordering: .relaxed)
        let startGain = control.lastGain
        control.lastGain = targetGain
        var peak: Float = 0

        var outputFlatChannel = 0
        for outputBuffer in outputBuffers {
            let outputChannels = Int(outputBuffer.mNumberChannels)
            guard outputChannels > 0, let outputData = outputBuffer.mData else { continue }
            let outputFrames = Int(outputBuffer.mDataByteSize) / (outputChannels * MemoryLayout<Float>.size)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)

            for channel in 0..<outputChannels {
                let flat = outputFlatChannel + channel
                let destination = outputSamples + channel
                var copied = false

                var inputFlatChannel = 0
                for inputBuffer in inputBuffers {
                    let inputChannels = Int(inputBuffer.mNumberChannels)
                    defer { inputFlatChannel += inputChannels }
                    guard inputChannels > 0, flat < inputFlatChannel + inputChannels,
                          let inputData = inputBuffer.mData else { continue }

                    let inputFrames = Int(inputBuffer.mDataByteSize) / (inputChannels * MemoryLayout<Float>.size)
                    let frames = vDSP_Length(min(inputFrames, outputFrames))
                    guard frames > 0 else { break }
                    let source = inputData.assumingMemoryBound(to: Float.self) + (flat - inputFlatChannel)

                    var gain = startGain
                    var step = (targetGain - startGain) / Float(frames)
                    vDSP_vrampmul(source, inputChannels, &gain, &step, destination, outputChannels, frames)

                    var channelPeak: Float = 0
                    vDSP_maxmgv(destination, outputChannels, &channelPeak, frames)
                    peak = max(peak, channelPeak)
                    copied = true
                    break
                }

                if !copied {
                    vDSP_vclr(destination, outputChannels, vDSP_Length(outputFrames))
                }
            }
            outputFlatChannel += outputChannels
        }

        control.peak.store(peak, ordering: .relaxed)
    }

    /// 탭/aggregate/IOProc 를 역순으로 정리한다. 여러 번 불러도 안전.
    func invalidate() {
        if let aggregate {
            if let ioProcID {
                try? aggregate.stop(IOProcID: ioProcID)
                AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
            }
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap {
            try? system.destroyProcessTap(tap)
        }
        ioProcID = nil
        aggregate = nil
        tap = nil
    }

    enum TapError: LocalizedError {
        case tapCreationFailed
        case noOutputDevice
        case aggregateCreationFailed

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed: "프로세스 탭을 만들지 못했습니다."
            case .noOutputDevice: "기본 출력 장치를 찾을 수 없습니다."
            case .aggregateCreationFailed: "Aggregate device 를 만들지 못했습니다."
            }
        }
    }
}
