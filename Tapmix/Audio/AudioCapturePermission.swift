import AppKit
import CoreAudio
import Observation
import os

let log = Logger(subsystem: "com.yu.Tapmix", category: "audio")

/// "시스템 오디오 녹음" (kTCCServiceAudioCapture) 권한 상태.
///
/// 공개 API 가 없어서 TCC.framework 의 preflight/request 를 dlsym 으로 부른다 (AudioCap 과 같은 방식).
/// 권한이 없는 상태에서 `.muted` 탭을 걸면 그 앱이 그냥 무음이 되어버리므로,
/// 반드시 `.granted` 일 때만 탭을 만들어야 한다.
@MainActor
@Observable
final class AudioCapturePermission {
    enum Status { case unknown, denied, granted }

    private(set) var status: Status = .unknown

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (
        CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFn? = handle
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let request: RequestFn? = handle
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFn.self) }

    init() {
        refresh()
    }

    func refresh() {
        guard let preflight = Self.preflight else {
            // 심볼을 못 찾으면 (OS 가 바뀌었다면) 일단 시도라도 해본다
            status = .granted
            return
        }
        let raw = preflight(Self.service, nil)
        switch raw {
        case 0: status = .granted
        case 1: status = .denied
        default: status = .unknown
        }
        log.notice("TCC preflight raw=\(raw, privacy: .public) status=\(String(describing: self.status), privacy: .public)")
    }

    /// 시스템 권한 프롬프트를 띄운다. 이미 결정된 상태면 프롬프트 없이 completion 만 부른다.
    func request(completion: @escaping @MainActor () -> Void) {
        guard let request = Self.request else {
            completion()
            return
        }
        request(Self.service, nil) { granted in
            log.notice("TCCAccessRequest callback granted=\(granted, privacy: .public)")
            Task { @MainActor in
                self.refresh()
                if self.status == .unknown {
                    // TCCAccessRequest 가 프롬프트를 안 띄우는 경우가 있어, 실제 탭 생성으로 시스템 프롬프트를 유도
                    Self.probeTapToTriggerPrompt()
                    self.refresh()
                }
                completion()
            }
        }
    }

    /// 아무 프로세스도 포함하지 않는 unmuted 전역 탭을 만들었다 바로 지운다. 소리에는 영향 없음.
    private static func probeTapToTriggerPrompt() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        do {
            if let tap = try AudioHardwareSystem.shared.makeProcessTap(description: description) {
                try? AudioHardwareSystem.shared.destroyProcessTap(tap)
                log.notice("probe tap created and destroyed")
            }
        } catch {
            log.error("probe tap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
