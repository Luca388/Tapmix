import AppKit
import CoreAudio
import Observation

/// UI 의 앱 한 줄. 헬퍼 프로세스(Safari 의 WebKit.GPU 등)는 부모 앱으로 묶는다.
struct AudioApp: Identifiable {
    /// 책임 프로세스(부모 앱)의 pid — 그룹 키
    let id: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    /// 이 앱에 속한 HAL process object 들
    var processIDs: [AudioObjectID]
    var isPlaying: Bool
    /// 0...1 표시용 레벨 (감쇠 적용)
    var level: Float = 0
    var volume: Float = 1
    var isMuted = false

    var settingsKey: String { bundleID ?? name }
    var effectiveGain: Float { isMuted ? 0 : volume }
    /// 원음 그대로(100%, 음소거 아님)면 탭이 필요 없다. 탭이 없으면 macOS 녹음 표시도 안 뜬다.
    var needsTap: Bool { isMuted || volume < 1 }
}

private struct AppAudioSettings: Codable {
    var volume: Float
    var isMuted: Bool
}

/// Core Audio 에 등록된 프로세스를 앱 단위로 묶어 추적하고,
/// 볼륨을 바꾸거나 음소거한 앱에만 탭을 걸어 볼륨/음소거/레벨을 처리한다.
///
/// 모든 앱에 탭을 상시로 걸면 macOS 의 "시스템 오디오 녹음" 표시가 항상 켜지고
/// 오디오 하드웨어가 잠들지 못해 배터리도 먹는다. 그래서 필요한 앱에만 건다.
/// 볼륨을 바꾼 앱은 재생 중이 아니어도 탭을 유지한다 — 재생 시작 순간 원래 볼륨으로 튀는 걸 막기 위해.
@MainActor
@Observable
final class AudioProcessMonitor {
    private(set) var apps: [AudioApp] = []
    private(set) var errorMessage: String?
    let permission = AudioCapturePermission()

    private let system = AudioHardwareSystem.shared
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var taps: [pid_t: ProcessTap] = [:]
    private var systemListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var meterTimer: Timer?
    private var settings: [String: AppAudioSettings] = [:]
    private var isRequestingPermission = false
    private var pendingTapCleanup: DispatchWorkItem?

    private static let settingsKey = "appAudioSettings"

    init() {
        loadSettings()

        let processListSelector = kAudioHardwarePropertyProcessObjectList
        let outputDeviceSelector = kAudioHardwarePropertyDefaultOutputDevice
        systemListeners = [
            try? PropertyListener(objectID: system.id, selector: processListSelector) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            },
            // 출력 장치가 바뀌면 aggregate 가 옛 장치에 묶여 있으므로 전부 다시 만든다
            try? PropertyListener(objectID: system.id, selector: outputDeviceSelector) { [weak self] in
                MainActor.assumeIsolated { self?.rebuildAllTaps() }
            },
        ].compactMap { $0 }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLevels() }
        }

        // 권한은 실행 시점이 아니라 처음으로 탭이 필요해질 때 (볼륨을 처음 바꿀 때) 요청한다
        refresh()
    }

    // MARK: - Public controls

    func setVolume(_ value: Float, for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        // 슬라이더를 끝까지 올렸을 때 정확히 1.0 이 안 나올 수 있어 스냅 — 그래야 탭이 해제된다
        apps[index].volume = value >= 0.995 ? 1 : max(value, 0)
        applyGain(apps[index])
    }

    func isTapped(_ pid: pid_t) -> Bool {
        taps[pid] != nil
    }

    func toggleMute(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].isMuted.toggle()
        applyGain(apps[index])
    }

    private func applyGain(_ app: AudioApp) {
        if let tap = taps[app.id] {
            tap.control.gain.store(app.effectiveGain, ordering: .relaxed)
        }

        if app.needsTap {
            pendingTapCleanup?.cancel()
            pendingTapCleanup = nil
            if taps[app.id] == nil { syncTaps() }
        } else if taps[app.id] != nil {
            // 100% 로 돌아왔으면 탭을 뗀다. 슬라이더를 100% 근처에서 흔들 때 탭을 반복 생성/해제하지
            // 않도록 잠깐 기다린다. 그동안은 게인 1.0 으로 통과시키므로 소리는 원음 그대로다.
            scheduleTapCleanup()
        }

        if app.needsTap {
            settings[app.settingsKey] = AppAudioSettings(volume: app.volume, isMuted: app.isMuted)
        } else {
            settings[app.settingsKey] = nil
        }
        saveSettings()
    }

    private func scheduleTapCleanup() {
        pendingTapCleanup?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingTapCleanup = nil
                self?.syncTaps()
            }
        }
        pendingTapCleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 사용자가 배너에서 직접 권한을 요청할 때
    func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        permission.request { [weak self] in
            self?.isRequestingPermission = false
            self?.syncTaps()
        }
    }

    // MARK: - Process list

    func refresh() {
        let processes: [AudioHardwareProcess]
        do {
            processes = try system.processes
        } catch {
            errorMessage = "프로세스 목록 조회 실패: \(error.localizedDescription)"
            return
        }

        // pid 별로 그룹핑
        struct Group {
            var processIDs: [AudioObjectID] = []
            var isPlaying = false
            var running: NSRunningApplication?
            var fallbackBundleID: String?
        }
        var groups: [pid_t: Group] = [:]
        var seenProcessIDs = Set<AudioObjectID>()

        for process in processes {
            guard let pid = try? process.pid, pid != ownPID else { continue }
            let owner = Self.responsiblePID(for: pid)
            guard owner != ownPID else { continue }

            let isPlaying = (try? process.isRunningOutput) ?? false
            let running = NSRunningApplication(processIdentifier: owner)
            // Dock 에 뜨는 일반 앱이거나 지금 소리를 내는 것만. 데몬/헬퍼 수십 개는 숨긴다.
            guard isPlaying || running?.activationPolicy == .regular else { continue }

            var group = groups[owner] ?? Group()
            group.processIDs.append(process.id)
            group.isPlaying = group.isPlaying || isPlaying
            group.running = group.running ?? running
            if group.fallbackBundleID == nil, let bundleID = try? process.bundleID, !bundleID.isEmpty {
                group.fallbackBundleID = bundleID
            }
            groups[owner] = group

            seenProcessIDs.insert(process.id)
            registerProcessListener(for: process.id)
        }

        var next: [AudioApp] = []
        for (pid, group) in groups {
            let bundleID = group.running?.bundleIdentifier ?? group.fallbackBundleID
            let (name, icon) = Self.displayInfo(pid: pid, bundleID: bundleID, running: group.running)
            let previous = apps.first { $0.id == pid }
            let saved = settings[bundleID ?? name]

            next.append(AudioApp(
                id: pid,
                bundleID: bundleID,
                name: name,
                icon: icon,
                processIDs: group.processIDs.sorted(),
                isPlaying: group.isPlaying,
                level: previous?.level ?? 0,
                volume: previous?.volume ?? saved?.volume ?? 1,
                isMuted: previous?.isMuted ?? saved?.isMuted ?? false
            ))
        }
        next.sort { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        apps = next
        log.notice("refresh: \(next.count, privacy: .public) apps, playing=\(next.filter(\.isPlaying).map(\.name).joined(separator: ","), privacy: .public) permission=\(String(describing: self.permission.status), privacy: .public)")

        for id in processListeners.keys where !seenProcessIDs.contains(id) {
            processListeners[id] = nil
        }
        syncTaps()
    }

    private func registerProcessListener(for id: AudioObjectID) {
        guard processListeners[id] == nil else { return }
        processListeners[id] = try? PropertyListener(objectID: id, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Taps

    /// 볼륨/음소거를 바꾼 앱에만 탭을 유지하고 나머지는 뗀다.
    /// 프로세스 구성이 바뀐 앱은 탭을 다시 만든다.
    private func syncTaps() {
        let needed = apps.filter(\.needsTap)
        let neededPIDs = Set(needed.map(\.id))

        for pid in taps.keys where !neededPIDs.contains(pid) {
            removeTap(for: pid)
        }
        guard !needed.isEmpty else {
            errorMessage = nil
            return
        }

        switch permission.status {
        case .granted:
            break
        case .unknown:
            requestPermission()
            return
        case .denied:
            removeAllTaps()
            return
        }

        var failure: String?
        for app in needed {
            if let existing = taps[app.id], existing.processIDs == app.processIDs { continue }
            taps[app.id]?.invalidate()
            do {
                taps[app.id] = try ProcessTap(processIDs: app.processIDs, gain: app.effectiveGain)
                log.notice("tap OK for \(app.name, privacy: .public) procs=\(app.processIDs, privacy: .public)")
            } catch {
                taps[app.id] = nil
                failure = "\(app.name): \(error.localizedDescription)"
                log.error("tap FAILED for \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        errorMessage = failure
    }

    private func rebuildAllTaps() {
        removeAllTaps()
        syncTaps()
    }

    private func removeTap(for pid: pid_t) {
        taps[pid]?.invalidate()
        taps[pid] = nil
        log.notice("tap removed for pid \(pid, privacy: .public)")
    }

    private func removeAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps = [:]
    }

    private var debugTick = 0

    private func updateLevels() {
        #if DEBUG
        debugTick += 1
        if debugTick % 60 == 0 {
            let playing = apps.filter(\.isPlaying).map { "\($0.name)=\(String(format: "%.2f", $0.level))" }
            log.notice("levels: \(playing.joined(separator: " "), privacy: .public)")
        }
        #endif
        for index in apps.indices {
            let peak = taps[apps[index].id]?.control.peak.load(ordering: .relaxed) ?? 0
            // 올라갈 땐 즉시, 내려올 땐 천천히 (VU 미터 느낌)
            let decayed = apps[index].level * 0.85
            var next = min(1, max(peak, decayed))
            if next < 0.0005 { next = 0 }
            // 값이 같으면 쓰지 않는다 — @Observable 이라 쓰기만 해도 매 프레임 다시 그려진다
            if next != apps[index].level {
                apps[index].level = next
            }
        }
    }

    // MARK: - Settings

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode([String: AppAudioSettings].self, from: data)
        else { return }
        settings = decoded
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - Helpers

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
        "responsibility_get_pid_responsible_for_pid"
    ).map { unsafeBitCast($0, to: ResponsibleFn.self) }

    /// 헬퍼 프로세스의 부모 앱 pid. 실패하면 자기 자신.
    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let owner = fn(pid)
        return owner > 0 ? owner : pid
    }

    private static func displayInfo(
        pid: pid_t,
        bundleID: String?,
        running: NSRunningApplication?
    ) -> (String, NSImage?) {
        if let running, let name = running.localizedName {
            return (name, running.icon)
        }
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        if let bundleID {
            return (bundleID.components(separatedBy: ".").last ?? bundleID, nil)
        }
        return ("PID \(pid)", nil)
    }
}
