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
}

private struct AppAudioSettings: Codable {
    var volume: Float
    var isMuted: Bool
}

/// Core Audio 에 등록된 프로세스를 앱 단위로 묶어 추적하고,
/// 권한이 있으면 각 앱에 탭을 걸어 볼륨/음소거/레벨을 처리한다.
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

        if permission.status == .unknown {
            permission.request { [weak self] in self?.refresh() }
        }
        refresh()
    }

    // MARK: - Public controls

    func setVolume(_ value: Float, for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].volume = min(max(value, 0), 1)
        applyGain(apps[index])
    }

    func toggleMute(for pid: pid_t) {
        guard let index = apps.firstIndex(where: { $0.id == pid }) else { return }
        apps[index].isMuted.toggle()
        applyGain(apps[index])
    }

    private func applyGain(_ app: AudioApp) {
        taps[app.id]?.control.gain.store(app.effectiveGain, ordering: .relaxed)
        settings[app.settingsKey] = AppAudioSettings(volume: app.volume, isMuted: app.isMuted)
        saveSettings()
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

    /// 목록에 있는 모든 앱에 탭을 유지한다 (재생 시작 순간부터 바로 설정된 볼륨이 적용되도록).
    /// 프로세스 구성이 바뀐 앱은 탭을 다시 만든다.
    private func syncTaps() {
        guard permission.status == .granted else {
            removeAllTaps()
            return
        }

        let livePIDs = Set(apps.map(\.id))
        for pid in taps.keys where !livePIDs.contains(pid) {
            taps[pid]?.invalidate()
            taps[pid] = nil
        }

        var failure: String?
        for app in apps {
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

    private func removeAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps = [:]
    }

    private var debugTick = 0

    private func updateLevels() {
        guard !taps.isEmpty else { return }
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
            apps[index].level = min(1, max(peak, decayed))
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
