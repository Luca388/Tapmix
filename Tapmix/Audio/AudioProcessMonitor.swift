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
    /// 사용자가 이 앱의 볼륨/음소거를 바꿨는지. 원음 그대로(100%, 음소거 아님)면 탭이 필요 없다.
    var hasCustomVolume: Bool { isMuted || volume != 1 }
}

private struct AppAudioSettings: Codable {
    var volume: Float
    var isMuted: Bool
}

/// 출력 장치 하나에 대한 설정. 장치(UID)마다 따로 저장되어, 장치를 바꾸면 그 장치의 설정으로 전환된다.
private struct DeviceProfile: Codable {
    var apps: [String: AppAudioSettings] = [:]
    var masterVolume: Float = 1
    var isMasterMuted = false
    var recentlyAdjusted: [String] = []
}

/// Core Audio 에 등록된 프로세스를 앱 단위로 묶어 추적하고,
/// 볼륨을 바꾸거나 음소거한 앱에만 탭을 걸어 볼륨/음소거/레벨을 처리한다.
///
/// 모든 앱에 탭을 상시로 걸면 macOS 의 "시스템 오디오 녹음" 표시가 항상 켜지고
/// 오디오 하드웨어가 잠들지 못해 배터리도 먹는다. 그래서 필요한 앱에만 건다.
/// 볼륨을 바꾼 앱은 재생 중이 아니어도 탭을 유지한다 — 재생 시작 순간 원래 볼륨으로 튀는 걸 막기 위해.
///
/// 앱 볼륨/음소거, 마스터, 최근 조절 순서는 출력 장치마다 따로 기억한다 (예: 스피커에선 Spotify 40%,
/// AirPods 에선 100%). 처음 쓰는 장치는 전부 100% 에서 시작한다.
@MainActor
@Observable
final class AudioProcessMonitor {
    private(set) var apps: [AudioApp] = []
    private(set) var errorMessage: String?
    let permission = AudioCapturePermission()

    /// 모든 앱 볼륨에 곱해지는 마스터 볼륨 (0...1). 앱 사이의 비율은 그대로 유지된다.
    private(set) var masterVolume: Float
    private(set) var isMasterMuted: Bool
    /// 앱 슬라이더 최대치. 1 보다 크면 부스트 (클리핑은 ProcessTap 에서 막는다).
    private(set) var maxAppVolume: Float

    static let maxAppVolumeChoices: [Float] = [1, 1.5, 2]

    /// 지금 설정이 적용되는 출력 장치 이름 (UI 표시용)
    private(set) var deviceName: String?

    private let system = AudioHardwareSystem.shared
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var taps: [pid_t: ProcessTap] = [:]
    private var systemListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var meterTimer: Timer?
    // 아래 settings / recentlyAdjusted / masterVolume / isMasterMuted 는 현재 장치(deviceUID)의 값이다.
    // 저장할 때 profiles[deviceUID] 에 되돌려 쓰고, 장치가 바뀌면 새 장치의 프로필을 불러온다.
    private var profiles: [String: DeviceProfile] = [:]
    private var deviceUID: String
    private var settings: [String: AppAudioSettings]
    /// 볼륨/음소거를 조절한 앱의 settingsKey, 최근 것부터. 목록 맨 위에 이 순서로 쌓인다.
    private var recentlyAdjusted: [String]
    private static let recentlyAdjustedLimit = 50
    private var isRequestingPermission = false
    private var pendingTapCleanup: DispatchWorkItem?

    private static let profilesKey = "deviceProfiles"

    init() {
        maxAppVolume = UserDefaults.standard.object(forKey: "maxAppVolume") as? Float ?? 1
        let (uid, name) = Self.currentOutputDevice()
        deviceUID = uid
        deviceName = name
        let loaded = Self.loadProfiles(currentUID: uid)
        profiles = loaded
        let profile = loaded[uid] ?? DeviceProfile()
        settings = profile.apps
        masterVolume = profile.masterVolume
        isMasterMuted = profile.isMasterMuted
        recentlyAdjusted = profile.recentlyAdjusted

        let processListSelector = kAudioHardwarePropertyProcessObjectList
        let outputDeviceSelector = kAudioHardwarePropertyDefaultOutputDevice
        systemListeners = [
            try? PropertyListener(objectID: system.id, selector: processListSelector) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            },
            try? PropertyListener(objectID: system.id, selector: outputDeviceSelector) { [weak self] in
                MainActor.assumeIsolated { self?.outputDeviceChanged() }
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
        apps[index].volume = Self.snapToUnity(min(max(value, 0), maxAppVolume), range: maxAppVolume)
        applyGain(apps[index])
    }

    func setMasterVolume(_ value: Float) {
        masterVolume = Self.snapToUnity(min(max(value, 0), 1), range: 1)
        saveSettings()
        applyMaster()
    }

    func toggleMasterMute() {
        isMasterMuted.toggle()
        saveSettings()
        applyMaster()
    }

    /// 최대치를 줄이면 그보다 큰 앱 볼륨은 새 최대치로 내린다
    func setMaxAppVolume(_ value: Float) {
        maxAppVolume = value
        UserDefaults.standard.set(value, forKey: "maxAppVolume")
        for index in apps.indices where apps[index].volume > value {
            apps[index].volume = value
            applyGain(apps[index])
        }
        for (key, saved) in settings where saved.volume > value {
            settings[key]?.volume = value
        }
        // 다른 장치의 프로필도 새 최대치에 맞춘다
        for (uid, profile) in profiles where uid != deviceUID {
            for (key, saved) in profile.apps where saved.volume > value {
                profiles[uid]?.apps[key]?.volume = value
            }
        }
        saveSettings()
    }

    /// 마스터가 원음이 아니면(100% 미만 또는 음소거) 소리를 내는 모든 앱에 탭이 필요하다
    var isMasterActive: Bool { isMasterMuted || masterVolume < 1 }

    func gain(for app: AudioApp) -> Float {
        (app.isMuted || isMasterMuted) ? 0 : app.volume * masterVolume
    }

    /// 탭이 필요한 앱: 볼륨을 직접 바꾼 앱, 또는 마스터가 켜져 있을 때 재생 중인 앱.
    /// 마스터 때문에 한 번 건 탭은 재생이 멈춰도 유지한다 — 재생/정지마다 탭을 다시 만들지 않도록.
    private func wantsTap(_ app: AudioApp) -> Bool {
        app.hasCustomVolume || (isMasterActive && (app.isPlaying || taps[app.id] != nil))
    }

    /// 100% 근처는 정확히 1 로 붙인다. 슬라이더로 정확히 1.0 을 맞추기 어려운데, 1 이어야 탭이 해제된다.
    private static func snapToUnity(_ value: Float, range: Float) -> Float {
        abs(value - 1) < range * 0.01 ? 1 : value
    }

    private func applyMaster() {
        if isMasterActive {
            pendingTapCleanup?.cancel()
            pendingTapCleanup = nil
        }
        for app in apps {
            taps[app.id]?.control.gain.store(gain(for: app), ordering: .relaxed)
        }
        if isMasterActive {
            syncTaps()
        } else {
            scheduleTapCleanup()
        }
    }

    func isTapped(_ pid: pid_t) -> Bool {
        taps[pid] != nil
    }

    func toggleMute(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].isMuted.toggle()
        applyGain(apps[index])
        markAdjusted(pid)
    }

    /// 앱 하나를 기본값(100%, 음소거 해제)으로 되돌린다. 원음이 되므로 탭은 잠시 뒤 해제되고,
    /// 최근 조절 목록에서도 빠져 원래 정렬 위치로 돌아간다.
    func resetVolume(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].volume = 1
        apps[index].isMuted = false
        recentlyAdjusted.removeAll { $0 == apps[index].settingsKey }
        applyGain(apps[index])
        apps = sorted(apps)
    }

    /// 마스터만 기본값(100%, 음소거 해제)으로 되돌린다. 앱별 볼륨은 그대로.
    func resetMaster() {
        masterVolume = 1
        isMasterMuted = false
        saveSettings()
        applyMaster()
    }

    /// 현재 출력 장치의 마스터와 모든 앱 볼륨을 기본값으로 되돌린다.
    /// 지금 목록에 없는 앱의 저장값도 지운다. 다른 장치의 프로필은 건드리지 않는다.
    func resetAllVolumes() {
        for index in apps.indices {
            apps[index].volume = 1
            apps[index].isMuted = false
        }
        settings = [:]
        recentlyAdjusted = []
        apps = sorted(apps)
        resetMaster()
    }

    /// 마스터나 앱 중 하나라도 기본값이 아닌지 (전체 초기화 메뉴 활성화용)
    var hasAnyCustomVolume: Bool {
        isMasterActive || !settings.isEmpty
    }

    /// 조절한 앱을 목록 맨 위로 올린다. 슬라이더는 드래그가 끝났을 때 부른다 —
    /// 드래그 중에 행이 움직이면 포인터 아래에서 슬라이더가 빠져나가 버린다.
    func markAdjusted(_ pid: pid_t) {
        guard let app = apps.first(where: { $0.id == pid }) else { return }
        recentlyAdjusted.removeAll { $0 == app.settingsKey }
        recentlyAdjusted.insert(app.settingsKey, at: 0)
        if recentlyAdjusted.count > Self.recentlyAdjustedLimit {
            recentlyAdjusted.removeLast(recentlyAdjusted.count - Self.recentlyAdjustedLimit)
        }
        saveSettings()
        apps = sorted(apps)
    }

    private func applyGain(_ app: AudioApp) {
        if let tap = taps[app.id] {
            tap.control.gain.store(gain(for: app), ordering: .relaxed)
        }

        if wantsTap(app) {
            pendingTapCleanup?.cancel()
            pendingTapCleanup = nil
            if taps[app.id] == nil { syncTaps() }
        } else if taps[app.id] != nil {
            // 100% 로 돌아왔으면 탭을 뗀다. 슬라이더를 100% 근처에서 흔들 때 탭을 반복 생성/해제하지
            // 않도록 잠깐 기다린다. 그동안은 게인 1.0 으로 통과시키므로 소리는 원음 그대로다.
            scheduleTapCleanup()
        }

        if app.hasCustomVolume {
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
                volume: min(previous?.volume ?? saved?.volume ?? 1, maxAppVolume),
                isMuted: previous?.isMuted ?? saved?.isMuted ?? false
            ))
        }
        apps = sorted(next)
        log.notice("refresh: \(next.count, privacy: .public) apps, playing=\(next.filter(\.isPlaying).map(\.name).joined(separator: ","), privacy: .public) permission=\(String(describing: self.permission.status), privacy: .public)")

        for id in processListeners.keys where !seenProcessIDs.contains(id) {
            processListeners[id] = nil
        }
        syncTaps()
    }

    /// 최근에 조절한 앱이 맨 위 (최근 순), 나머지는 재생 중인 앱 먼저, 그다음 이름 순
    private func sorted(_ list: [AudioApp]) -> [AudioApp] {
        let rank = Dictionary(recentlyAdjusted.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return list.sorted { lhs, rhs in
            switch (rank[lhs.settingsKey], rank[rhs.settingsKey]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func registerProcessListener(for id: AudioObjectID) {
        guard processListeners[id] == nil else { return }
        processListeners[id] = try? PropertyListener(objectID: id, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Taps

    /// 볼륨/음소거를 바꾼 앱 (마스터가 켜져 있으면 재생 중인 앱도) 에만 탭을 유지하고 나머지는 뗀다.
    /// 프로세스 구성이 바뀐 앱은 탭을 다시 만든다.
    private func syncTaps() {
        let needed = apps.filter(wantsTap)
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
            taps[app.id]?.release()
            do {
                taps[app.id] = try ProcessTap(processIDs: app.processIDs, gain: gain(for: app))
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
        taps[pid]?.release()
        taps[pid] = nil
        log.notice("tap removed for pid \(pid, privacy: .public)")
    }

    private func removeAllTaps() {
        for tap in taps.values { tap.release() }
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

    /// 기본 출력 장치가 바뀌었을 때: 이전 장치 설정을 저장하고 새 장치의 설정으로 전환한 뒤 탭을 다시 만든다.
    /// (탭의 aggregate 는 옛 장치에 묶여 있으므로 장치가 같더라도 다시 만든다)
    private func outputDeviceChanged() {
        let (uid, name) = Self.currentOutputDevice()
        if uid != deviceUID, !uid.hasPrefix(ProcessTap.aggregateUIDPrefix) {
            saveSettings()
            deviceUID = uid
            deviceName = name
            let profile = profiles[uid] ?? DeviceProfile()
            settings = profile.apps
            masterVolume = profile.masterVolume
            isMasterMuted = profile.isMasterMuted
            recentlyAdjusted = profile.recentlyAdjusted
            for index in apps.indices {
                let saved = settings[apps[index].settingsKey]
                apps[index].volume = min(saved?.volume ?? 1, maxAppVolume)
                apps[index].isMuted = saved?.isMuted ?? false
            }
            apps = sorted(apps)
            pendingTapCleanup?.cancel()
            pendingTapCleanup = nil
            log.notice("output device → \(name ?? uid, privacy: .public), \(self.settings.count, privacy: .public) app settings")
        }
        rebuildAllTaps()
    }

    private static func currentOutputDevice() -> (uid: String, name: String?) {
        let device = try? AudioHardwareSystem.shared.defaultOutputDevice
        return ((try? device?.uid) ?? "", try? device?.name)
    }

    private func saveSettings() {
        profiles[deviceUID] = DeviceProfile(
            apps: settings,
            masterVolume: masterVolume,
            isMasterMuted: isMasterMuted,
            recentlyAdjusted: recentlyAdjusted
        )
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)
    }

    /// 장치별 프로필을 읽는다. 장치별 저장 이전(0.3 까지)의 설정이 있으면 현재 장치의 프로필로 옮긴다.
    private static func loadProfiles(currentUID: String) -> [String: DeviceProfile] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) {
            return decoded
        }

        var legacy = DeviceProfile()
        if let data = defaults.data(forKey: "appAudioSettings"),
           let apps = try? JSONDecoder().decode([String: AppAudioSettings].self, from: data) {
            legacy.apps = apps
        }
        legacy.masterVolume = defaults.object(forKey: "masterVolume") as? Float ?? 1
        legacy.isMasterMuted = defaults.bool(forKey: "masterMuted")
        legacy.recentlyAdjusted = defaults.stringArray(forKey: "recentlyAdjusted") ?? []
        for key in ["appAudioSettings", "masterVolume", "masterMuted", "recentlyAdjusted"] {
            defaults.removeObject(forKey: key)
        }

        let profiles = [currentUID: legacy]
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
        return profiles
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
